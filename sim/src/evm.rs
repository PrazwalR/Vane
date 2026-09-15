//! Loads a `forge`-dumped EVM state into revm and executes calls against it.
//!
//! The engine runs the compiled contracts themselves. Nothing about the mechanism is
//! reimplemented here: every number this simulator reports came out of the same bytecode
//! that would be deployed.

use alloy_primitives::{Address, Bytes, B256, U256};
use revm::db::{CacheDB, EmptyDB};
use revm::primitives::{
    AccountInfo, Bytecode, ExecutionResult, Output, SpecId, TxKind,
};
use revm::Evm;
use serde::Deserialize;
use std::collections::HashMap;

#[derive(Deserialize)]
struct DumpedAccount {
    nonce: String,
    balance: String,
    code: String,
    #[serde(default)]
    storage: HashMap<String, String>,
}

#[derive(Deserialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub pool_manager: Address,
    pub swap_router: Address,
    pub vane_hook: Address,
    pub currency0: Address,
    pub currency1: Address,
    pub trader: Address,
    pub vane_pool_id: B256,
    pub plain_pool_id: B256,
    pub fee: u32,
    pub tick_spacing: i32,
    pub liquidity: String,
    #[serde(default)]
    pub range: i32,
}

impl Manifest {
    pub fn liquidity_f64(&self) -> f64 {
        self.liquidity.parse::<f64>().unwrap_or(0.0)
    }
}

fn parse_u256(s: &str) -> U256 {
    U256::from_str_radix(s.trim_start_matches("0x"), 16).unwrap_or(U256::ZERO)
}

pub struct Harness {
    pub db: CacheDB<EmptyDB>,
    pub manifest: Manifest,
    pub block: u64,
}

#[derive(Debug)]
pub enum CallError {
    Reverted(Bytes),
    Halted(String),
}

impl Harness {
    pub fn load(state_path: &str, manifest_path: &str) -> Self {
        let manifest: Manifest =
            serde_json::from_str(&std::fs::read_to_string(manifest_path).expect("manifest"))
                .expect("manifest parse");

        let raw: HashMap<String, DumpedAccount> =
            serde_json::from_str(&std::fs::read_to_string(state_path).expect("state"))
                .expect("state parse");

        let mut db = CacheDB::new(EmptyDB::default());
        for (addr_s, acct) in raw {
            let addr: Address = addr_s.parse().expect("address");
            let code_bytes = hex_to_bytes(&acct.code);
            let bytecode = if code_bytes.is_empty() {
                Bytecode::default()
            } else {
                Bytecode::new_raw(code_bytes.into())
            };
            let info = AccountInfo {
                balance: parse_u256(&acct.balance),
                nonce: u64::from_str_radix(acct.nonce.trim_start_matches("0x"), 16).unwrap_or(0),
                code_hash: bytecode.hash_slow(),
                code: Some(bytecode),
            };
            db.insert_account_info(addr, info);
            for (k, v) in acct.storage {
                db.insert_account_storage(addr, parse_u256(&k), parse_u256(&v))
                    .expect("storage insert");
            }
        }

        // The replay trader transacts at zero gas price, but revm still runs the balance
        // check, so fund the account rather than reaching for the optional-check features.
        let t = manifest.trader;
        let mut info = db.load_account(t).map(|a| a.info.clone()).unwrap_or_default();
        info.balance = U256::from(10u64).pow(U256::from(24));
        db.insert_account_info(t, info);

        Self { db, manifest, block: 1 }
    }

    fn run(&mut self, to: Address, data: Vec<u8>, commit: bool) -> Result<Bytes, CallError> {
        let caller = self.manifest.trader;
        let block = self.block;
        let db = std::mem::replace(&mut self.db, CacheDB::new(EmptyDB::default()));

        let mut evm = Evm::builder()
            .with_db(db)
            .with_spec_id(SpecId::CANCUN)
            .modify_block_env(|b| {
                b.number = U256::from(block);
                b.timestamp = U256::from(1_700_000_000u64 + block * 12);
            })
            .modify_tx_env(|tx| {
                tx.caller = caller;
                tx.transact_to = TxKind::Call(to);
                tx.data = data.into();
                tx.value = U256::ZERO;
                tx.gas_limit = 60_000_000;
                tx.gas_price = U256::ZERO;
            })
            .build();

        let result = if commit {
            evm.transact_commit().map_err(|e| CallError::Halted(format!("{e:?}")))
        } else {
            evm.transact()
                .map(|r| r.result)
                .map_err(|e| CallError::Halted(format!("{e:?}")))
        };

        let (out, db_back) = {
            let db_back = evm.context.evm.inner.db;
            (result, db_back)
        };
        self.db = db_back;

        match out? {
            ExecutionResult::Success { output, .. } => Ok(match output {
                Output::Call(b) => b,
                Output::Create(b, _) => b,
            }),
            ExecutionResult::Revert { output, .. } => Err(CallError::Reverted(output)),
            ExecutionResult::Halt { reason, .. } => Err(CallError::Halted(format!("{reason:?}"))),
        }
    }

    pub fn call(&mut self, to: Address, data: Vec<u8>) -> Result<Bytes, CallError> {
        self.run(to, data, true)
    }

    pub fn view(&mut self, to: Address, data: Vec<u8>) -> Result<Bytes, CallError> {
        self.run(to, data, false)
    }

    pub fn roll(&mut self, n: u64) {
        self.block += n;
    }
}

fn hex_to_bytes(s: &str) -> Vec<u8> {
    let s = s.trim_start_matches("0x");
    (0..s.len())
        .step_by(2)
        .filter_map(|i| u8::from_str_radix(&s[i..i + 2], 16).ok())
        .collect()
}
