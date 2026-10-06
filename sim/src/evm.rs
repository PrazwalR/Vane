//! Loads a `forge`-dumped EVM state into revm and executes calls against it.
//!
//! The engine runs the compiled contracts themselves. Nothing about the mechanism is
//! reimplemented here: every number this simulator reports came out of the same bytecode
//! that would be deployed.

use alloy_primitives::{Address, Bytes, B256, U256};
use revm::db::{CacheDB, EmptyDB};
use revm::primitives::{AccountInfo, Bytecode, ExecutionResult, Output, SpecId, TxKind};
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
    #[serde(default)]
    pub flow_unit: String,
}

impl Manifest {
    pub fn liquidity_f64(&self) -> f64 {
        self.liquidity.parse::<f64>().unwrap_or(0.0)
    }

    /// Half-width of the seeded liquidity range, in ticks. Reported in the run header
    /// because concentration — not TVL — is what decides which side of D* the pool sits on.
    pub fn range_ticks(&self) -> i32 {
        self.range
    }

    /// The wei-per-flow-unit divisor the pool was allowlisted with. It decides where the
    /// flow-variance accumulator saturates, so a run is not interpretable without it.
    pub fn flow_unit(&self) -> f64 {
        self.flow_unit.parse::<f64>().unwrap_or(0.0)
    }
}

/// Strict on purpose. A malformed slot silently reading as zero would make the hook
/// behave as if uninitialised while the run still printed numbers, and the whole value of
/// this tool is that its numbers can be trusted.
fn parse_u256(label: &str, s: &str) -> U256 {
    U256::from_str_radix(s.trim_start_matches("0x"), 16)
        .unwrap_or_else(|e| panic!("malformed 256-bit value for {label}: {s:?} ({e})"))
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

impl std::fmt::Display for CallError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            // A revert carries either a standard Error(string) payload or a custom-error
            // selector. Printing whichever is present is the difference between "a swap
            // failed" and knowing why, and the whole value of this tool is the numbers it
            // reports, so a silent failure channel in it is not acceptable.
            Self::Reverted(b) if b.is_empty() => write!(f, "reverted (no data)"),
            Self::Reverted(b) => match decode_revert_string(b) {
                Some(msg) => write!(f, "reverted: {msg}"),
                None => write!(f, "reverted, selector 0x{}", hex_prefix(b, 4)),
            },
            Self::Halted(r) => write!(f, "halted: {r}"),
        }
    }
}

/// Decodes the standard `Error(string)` revert payload: selector 0x08c379a0, then an
/// ABI-encoded string.
fn decode_revert_string(b: &[u8]) -> Option<String> {
    if b.len() < 100 || b[..4] != [0x08, 0xc3, 0x79, 0xa0] {
        return None;
    }
    let len = U256::from_be_slice(&b[36..68]).to::<usize>();
    let end = 68usize.checked_add(len)?;
    if end > b.len() {
        return None;
    }
    String::from_utf8(b[68..end].to_vec()).ok()
}

fn hex_prefix(b: &[u8], n: usize) -> String {
    b.iter().take(n).map(|x| format!("{x:02x}")).collect()
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
            let code_bytes = hex_to_bytes(&format!("code of {addr_s}"), &acct.code);
            let bytecode = if code_bytes.is_empty() {
                Bytecode::default()
            } else {
                Bytecode::new_raw(code_bytes.into())
            };
            let info = AccountInfo {
                balance: parse_u256("balance", &acct.balance),
                nonce: u64::from_str_radix(acct.nonce.trim_start_matches("0x"), 16).unwrap_or(0),
                code_hash: bytecode.hash_slow(),
                code: Some(bytecode),
            };
            db.insert_account_info(addr, info);
            for (k, v) in acct.storage {
                db.insert_account_storage(
                    addr,
                    parse_u256("storage key", &k),
                    parse_u256("storage value", &v),
                )
                .expect("storage insert");
            }
        }

        // The replay trader transacts at zero gas price, but revm still runs the balance
        // check, so fund the account rather than reaching for the optional-check features.
        let t = manifest.trader;
        let mut info = db
            .load_account(t)
            .map(|a| a.info.clone())
            .unwrap_or_default();
        info.balance = U256::from(10u64).pow(U256::from(24));
        db.insert_account_info(t, info);

        Self {
            db,
            manifest,
            block: 1,
        }
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
            evm.transact_commit()
                .map_err(|e| CallError::Halted(format!("{e:?}")))
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

/// Strict on purpose, and the stricter of the two.
///
/// This previously used `filter_map(..).ok()`, which DROPPED an unparseable pair and
/// shifted every subsequent byte of the contract's bytecode. revm accepts the result
/// without validation, so the engine would then execute different code and report its
/// output as VANE's — the worst failure mode available to a measuring instrument, and the
/// one this crate's bindings module explicitly warns about one layer up. An odd-length
/// string also panicked on the slice rather than erroring, so the behaviour was not even
/// consistently wrong.
fn hex_to_bytes(label: &str, s: &str) -> Vec<u8> {
    let s = s.trim_start_matches("0x");
    assert!(
        s.len().is_multiple_of(2),
        "odd-length hex for {label}: {} characters",
        s.len()
    );
    (0..s.len())
        .step_by(2)
        .map(|i| {
            u8::from_str_radix(&s[i..i + 2], 16)
                .unwrap_or_else(|e| panic!("malformed hex byte for {label} at offset {i}: {e}"))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_decoding_is_exact() {
        assert_eq!(
            hex_to_bytes("t", "0x60806040"),
            vec![0x60, 0x80, 0x60, 0x40]
        );
        assert_eq!(hex_to_bytes("t", "60806040"), vec![0x60, 0x80, 0x60, 0x40]);
        assert_eq!(hex_to_bytes("t", "0x"), Vec::<u8>::new());
    }

    /// The failure that mattered: a dropped pair used to shift every subsequent byte of
    /// the contract's bytecode, so revm executed different code and the run reported its
    /// output as VANE's.
    #[test]
    #[should_panic(expected = "malformed hex byte")]
    fn hex_decoding_rejects_a_bad_pair_rather_than_dropping_it() {
        hex_to_bytes("t", "6080zz40");
    }

    #[test]
    #[should_panic(expected = "odd-length hex")]
    fn hex_decoding_rejects_an_odd_length() {
        hex_to_bytes("t", "608");
    }

    #[test]
    fn u256_parsing_accepts_both_forms() {
        assert_eq!(parse_u256("t", "0x10"), U256::from(16));
        assert_eq!(parse_u256("t", "10"), U256::from(16));
        assert_eq!(parse_u256("t", "0x0"), U256::ZERO);
    }

    /// A malformed slot reading as zero would make the hook behave as if uninitialised
    /// while the run still printed plausible numbers.
    #[test]
    #[should_panic(expected = "malformed 256-bit value")]
    fn u256_parsing_rejects_garbage_rather_than_reading_zero() {
        parse_u256("storage value", "0xnope");
    }

    /// Error text has to name the offending account, or a corrupt dump is undiagnosable.
    #[test]
    fn revert_decoding_reads_a_standard_error_string() {
        // selector 0x08c379a0, offset 0x20, length 5, "hello" padded to 32 bytes
        let mut b = vec![0x08, 0xc3, 0x79, 0xa0];
        b.extend_from_slice(&[0u8; 31]);
        b.push(0x20);
        b.extend_from_slice(&[0u8; 31]);
        b.push(0x05);
        b.extend_from_slice(b"hello");
        b.extend_from_slice(&[0u8; 27]);

        assert_eq!(decode_revert_string(&b).as_deref(), Some("hello"));
        assert_eq!(decode_revert_string(&[0x08, 0xc3, 0x79, 0xa0]), None);
        assert_eq!(decode_revert_string(&[0xde, 0xad, 0xbe, 0xef]), None);
    }

    #[test]
    fn call_error_displays_something_actionable() {
        assert_eq!(
            CallError::Reverted(Bytes::new()).to_string(),
            "reverted (no data)"
        );
        assert!(
            CallError::Reverted(Bytes::from_static(&[0xde, 0xad, 0xbe, 0xef]))
                .to_string()
                .contains("deadbeef")
        );
        assert!(CallError::Halted("OutOfGas".into())
            .to_string()
            .contains("OutOfGas"));
    }
}
