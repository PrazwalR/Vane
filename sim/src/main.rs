mod bindings;
mod evm;
mod flow;

use alloy_primitives::{
    aliases::{I24, U160, U24},
    keccak256, Address, B256, I256, U256,
};
use alloy_sol_types::SolCall;
use bindings::*;
use clap::Parser;
use evm::Harness;
use flow::{variance_ratio, FlowParams, LN_1_0001};

const MIN_SQRT: u128 = 4295128739;
const MAX_SQRT: &str = "1461446703485210103287273052203988822378723970342";

#[derive(Parser, Debug)]
#[command(about = "Replays Kyle-model order flow through the deployed VANE bytecode")]
struct Args {
    #[arg(long, default_value_t = 2000)]
    blocks: usize,
    #[arg(long, default_value_t = 1)]
    seed: u64,
    #[arg(long, default_value_t = 0.0004)]
    sigma: f64,
    #[arg(long, default_value_t = 20.0)]
    noise_rate: f64,
    #[arg(long, default_value_t = 5e18)]
    noise_size: f64,
    /// Autocorrelation of the fundamental's increments; raises the variance ratio.
    #[arg(long, default_value_t = 0.0)]
    momentum: f64,
    /// Emit one JSON line instead of the human-readable report.
    #[arg(long, default_value_t = false)]
    json: bool,
    /// Print the hook's internal state every N blocks.
    #[arg(long, default_value_t = 0)]
    trace: usize,
}

struct Pool {
    hooks: Address,
    id: B256,
    label: &'static str,
    arb_pnl: f64,
    arb_trades: usize,
    noise_done: usize,
    failures: usize,
    ticks: Vec<i32>,
}

impl Pool {
    fn new(hooks: Address, id: B256, label: &'static str) -> Self {
        Self { hooks, id, label, arb_pnl: 0.0, arb_trades: 0, noise_done: 0, failures: 0, ticks: vec![] }
    }
}

fn key_for(h: &Harness, hooks: Address) -> PoolKey {
    PoolKey {
        currency0: h.manifest.currency0,
        currency1: h.manifest.currency1,
        fee: U24::from(h.manifest.fee),
        tickSpacing: I24::try_from(h.manifest.tick_spacing).unwrap(),
        hooks,
    }
}

fn slot0_tick(h: &mut Harness, pool_id: B256) -> i32 {
    let mut buf = [0u8; 64];
    buf[..32].copy_from_slice(pool_id.as_slice());
    buf[32..].copy_from_slice(&U256::from(6).to_be_bytes::<32>());
    let slot = keccak256(buf);
    let manager = h.manifest.pool_manager;
    let out = match h.view(manager, extsloadCall { slot }.abi_encode()) {
        Ok(o) => o,
        Err(_) => return 0,
    };
    let word = U256::from_be_slice(&out);
    let raw: u32 = (word.wrapping_shr(160) & U256::from(0xFFFFFFu32)).to();
    if raw & 0x800000 != 0 { (raw as i32) - 0x1000000 } else { raw as i32 }
}

/// Returns the swapper's own balance delta: negative is paid out, positive is received.
fn do_swap(h: &mut Harness, hooks: Address, zero_for_one: bool, amount: i128) -> Option<(i128, i128)> {
    let limit = if zero_for_one {
        U160::from(MIN_SQRT + 1)
    } else {
        U160::from_str_radix(MAX_SQRT, 10).unwrap() - U160::from(1)
    };
    let call = swapCall {
        key: key_for(&*h, hooks),
        params: SwapParams {
            zeroForOne: zero_for_one,
            amountSpecified: I256::try_from(amount).ok()?,
            sqrtPriceLimitX96: limit,
        },
        testSettings: TestSettings { takeClaims: false, settleUsingBurn: false },
        hookData: Default::default(),
    };
    let router = h.manifest.swap_router;
    let out = h.call(router, call.abi_encode()).ok()?;
    if out.len() < 32 {
        return None;
    }
    let word = U256::from_be_slice(&out[..32]);
    let hi: u128 = (word.wrapping_shr(128) & U256::from(u128::MAX)).to();
    let lo: u128 = (word & U256::from(u128::MAX)).to();
    Some((hi as i128, lo as i128))
}

fn reserve(h: &mut Harness, hook: Address, currency: Address) -> f64 {
    h.view(hook, reserveOfCall { currency }.abi_encode())
        .map(|b| U256::from_be_slice(&b).to::<u128>() as f64)
        .unwrap_or(0.0)
}

fn main() {
    let args = Args::parse();
    let mut h = Harness::load("state/state.json", "state/manifest.json");

    let hook = h.manifest.vane_hook;
    let (c0, c1) = (h.manifest.currency0, h.manifest.currency1);
    let liquidity = h.manifest.liquidity_f64();

    let mut pools = vec![
        Pool::new(hook, h.manifest.vane_pool_id, "vane"),
        Pool::new(Address::ZERO, h.manifest.plain_pool_id, "plain"),
    ];

    let fp = FlowParams {
        blocks: args.blocks,
        sigma: args.sigma,
        noise_rate: args.noise_rate,
        noise_size: args.noise_size,
        momentum: args.momentum,
        ..Default::default()
    };
    let blocks = flow::generate(fp, args.seed);

    let mut kappa_max = U256::ZERO;
    let mut belief_absmax = I256::ZERO;
    let reserve0_start = reserve(&mut h, hook, c0);
    let reserve1_start = reserve(&mut h, hook, c1);

    // The fee is what the informed trader must clear before a gap is worth taking.
    let fee_ln = h.manifest.fee as f64 / 1e6;

    for (block_i, blk) in blocks.iter().enumerate() {
        for p in pools.iter_mut() {
            // Noise first: it is uninformed, so it should not be systematically advantaged
            // by arriving after the correction.
            for t in &blk.noise {
                match do_swap(&mut h, p.hooks, t.zero_for_one, t.amount) {
                    Some(_) => p.noise_done += 1,
                    None => p.failures += 1,
                }
            }

            let tick = slot0_tick(&mut h, p.id);
            let pool_ln = tick as f64 * LN_1_0001;
            let gap = blk.fundamental_ln - pool_ln;

            if gap.abs() > fee_ln {
                // Close the gap only down to the fee boundary. Trading the whole gap
                // walks the price past the fundamental and pays the fee for the
                // privilege, which is why an arbitrageur does not do it.
                let excess = gap.abs() - fee_ln;
                let size = (liquidity * excess / 2.0).clamp(1e15, 1e25) as i128;
                let zero_for_one = gap < 0.0;
                if let Some((d0, d1)) = do_swap(&mut h, p.hooks, zero_for_one, -size) {
                    // Mark the round trip to the fundamental. This is exactly the value the
                    // arbitrageur extracts from the pool, which is what LVR measures.
                    let pv = blk.fundamental_ln.exp();
                    p.arb_pnl += (d0 as f64) * pv + (d1 as f64);
                    p.arb_trades += 1;
                } else {
                    p.failures += 1;
                }
            }
            p.ticks.push(slot0_tick(&mut h, p.id));
        }

        {
            let id = h.manifest.vane_pool_id;
            if let Ok(b) = h.view(hook, kappaOfCall { id }.abi_encode()) {
                let k = U256::from_be_slice(&b);
                if k > kappa_max { kappa_max = k; }
            }
            if let Ok(b) = h.view(hook, beliefOfCall { id }.abi_encode()) {
                let d = I256::from_be_bytes::<32>(b[..32].try_into().unwrap());
                let a = if d < I256::ZERO { -d } else { d };
                if a > belief_absmax { belief_absmax = a; }
            }
        }

        if args.trace > 0 && block_i % args.trace == 0 {
            let id = h.manifest.vane_pool_id;
            let belief = h.view(hook, beliefOfCall { id }.abi_encode())
                .map(|b| I256::from_be_bytes::<32>(b[..32].try_into().unwrap()))
                .unwrap_or(I256::ZERO);
            let kappa = h.view(hook, kappaOfCall { id }.abi_encode())
                .map(|b| U256::from_be_slice(&b))
                .unwrap_or(U256::ZERO);
            let st = h.view(hook, poolStateCall { id }.abi_encode()).unwrap_or_default();
            let (var1, fvar) = if st.len() >= 160 {
                (U256::from_be_slice(&st[64..96]), U256::from_be_slice(&st[96..128]))
            } else { (U256::ZERO, U256::ZERO) };
            let cv = h.view(hook, flowCovOfCall { id }.abi_encode()).unwrap_or_default();
            let rd = |o: usize| -> i64 {
                if cv.len() >= o + 32 {
                    I256::from_be_bytes::<32>(cv[o..o + 32].try_into().unwrap()).as_i64()
                } else { 0 }
            };
            println!(
                "blk {:>5} kappa={:<12} belief={:<12} varOne={:<12} flowVar={:<18} cov1={:<14} cov2={:<14} tick={}",
                block_i, kappa, belief, var1, fvar, rd(64), rd(96),
                pools[0].ticks.last().unwrap()
            );
        }
        h.roll(1);
    }

    let reserve0_end = reserve(&mut h, hook, c0);
    let reserve1_end = reserve(&mut h, hook, c1);
    let reserve_change = (reserve0_end - reserve0_start) + (reserve1_end - reserve1_start);

    let vane = &pools[0];
    let plain = &pools[1];
    let lvr_reduction = if plain.arb_pnl.abs() > 0.0 {
        (plain.arb_pnl - vane.arb_pnl) / plain.arb_pnl.abs() * 100.0
    } else {
        f64::NAN
    };

    if args.json {
        println!(
            r#"{{"seed":{},"blocks":{},"sigma":{},"vane_arb_pnl":{:.6e},"plain_arb_pnl":{:.6e},"lvr_reduction_pct":{:.4},"reserve_change":{:.6e},"vane_vr5":{:.4},"plain_vr5":{:.4},"vane_failures":{},"plain_failures":{},"kappa_max":"{}","belief_absmax":"{}","liquidity":"{}","fee":{},"momentum":{}}}"#,
            args.seed, args.blocks, args.sigma,
            vane.arb_pnl, plain.arb_pnl, lvr_reduction, reserve_change,
            variance_ratio(&vane.ticks, 5), variance_ratio(&plain.ticks, 5),
            vane.failures, plain.failures, kappa_max, belief_absmax,
            h.manifest.liquidity, h.manifest.fee, args.momentum
        );
        return;
    }

    println!("\nVANE replay — {} blocks, seed {}, sigma {}\n", args.blocks, args.seed, args.sigma);
    println!("{:<8} {:>16} {:>10} {:>10} {:>9} {:>9}", "pool", "arb PnL (ETH)", "arb trades", "noise", "VR(5)", "fails");
    for p in &pools {
        println!(
            "{:<8} {:>16.4} {:>10} {:>10} {:>9.3} {:>9}",
            p.label, p.arb_pnl / 1e18, p.arb_trades, p.noise_done,
            variance_ratio(&p.ticks, 5), p.failures
        );
    }
    println!("\nmax kappa (Q64.64)          : {}", kappa_max);
    println!("max |belief| (Q64.64)       : {}", belief_absmax);
    println!("LVR reduction vs plain pool : {:>8.2} %", lvr_reduction);
    println!("Hook reserve change         : {:>8.4} ETH", reserve_change / 1e18);
    println!(
        "  currency0 {:>+10.4}   currency1 {:>+10.4}",
        (reserve0_end - reserve0_start) / 1e18,
        (reserve1_end - reserve1_start) / 1e18
    );
}
