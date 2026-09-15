//! Generates the order flow the pools are driven with.
//!
//! The model is Kyle's: a fundamental value nobody observes, noise traders who trade for
//! reasons unrelated to it, and an informed trader who trades on the gap between the
//! fundamental and the quoted price. Noise flow is exogenous, so both pools see exactly the
//! same sequence. Informed flow is endogenous — it responds to the price each pool is
//! actually quoting — which is the entire point: a pool that corrects its quote faster
//! should give the informed trader less to take.

use rand::Rng;
use rand_chacha::rand_core::SeedableRng;
use rand_chacha::ChaCha8Rng;

pub const LN_1_0001: f64 = 0.00009999500033330835;

#[derive(Clone, Copy, Debug)]
pub struct NoiseTrade {
    pub zero_for_one: bool,
    pub amount: i128,
}

#[derive(Clone, Debug)]
pub struct Block {
    pub fundamental_ln: f64,
    pub noise: Vec<NoiseTrade>,
}

#[derive(Clone, Copy, Debug)]
pub struct FlowParams {
    pub blocks: usize,
    /// Per-block volatility of the fundamental, in log price.
    pub sigma: f64,
    /// Mean number of noise trades per block.
    pub noise_rate: f64,
    /// Median noise trade size, in wei of the input token.
    pub noise_size: f64,
    /// Lognormal dispersion of noise size.
    pub noise_spread: f64,
    /// Autocorrelation of the fundamental's increments. Zero is a random walk; positive
    /// values make the fundamental trend, which is what drives the variance ratio above
    /// one. The activation condition derived from the Kyle matching is VR > 4, so this is
    /// the knob that tests it.
    pub momentum: f64,
}

impl Default for FlowParams {
    fn default() -> Self {
        Self {
            blocks: 2000,
            sigma: 0.0015,
            noise_rate: 3.0,
            noise_size: 2e18,
            noise_spread: 0.9,
            momentum: 0.0,
        }
    }
}

pub fn generate(p: FlowParams, seed: u64) -> Vec<Block> {
    let mut rng = ChaCha8Rng::seed_from_u64(seed);
    let mut v = 0.0f64;
    let mut step = 0.0f64;
    let mut out = Vec::with_capacity(p.blocks);

    for _ in 0..p.blocks {
        step = p.momentum * step + p.sigma * normal(&mut rng);
        v += step;

        let n = poisson(&mut rng, p.noise_rate);
        let mut noise = Vec::with_capacity(n);
        for _ in 0..n {
            let size = p.noise_size * (p.noise_spread * normal(&mut rng)).exp();
            let size = size.clamp(1e15, 5e22);
            noise.push(NoiseTrade {
                zero_for_one: rng.gen_bool(0.5),
                amount: -(size as i128),
            });
        }
        out.push(Block { fundamental_ln: v, noise });
    }
    out
}

fn normal(rng: &mut ChaCha8Rng) -> f64 {
    // Box-Muller. u1 is pushed off zero so the logarithm stays finite.
    let u1: f64 = rng.gen_range(f64::EPSILON..1.0);
    let u2: f64 = rng.gen_range(0.0..1.0);
    (-2.0 * u1.ln()).sqrt() * (2.0 * std::f64::consts::PI * u2).cos()
}

fn poisson(rng: &mut ChaCha8Rng, lambda: f64) -> usize {
    let l = (-lambda).exp();
    let mut k = 0;
    let mut p = 1.0;
    loop {
        p *= rng.gen_range(0.0..1.0);
        if p <= l || k > 64 {
            return k;
        }
        k += 1;
    }
}

/// Variance ratio of a tick series at horizon k. Under an efficient price this is one;
/// below one means the series mean-reverts, above one means it trends.
pub fn variance_ratio(ticks: &[i32], k: usize) -> f64 {
    if ticks.len() < k * 4 {
        return f64::NAN;
    }
    let r1: Vec<f64> = ticks.windows(2).map(|w| (w[1] - w[0]) as f64).collect();
    let rk: Vec<f64> = ticks
        .windows(k + 1)
        .step_by(k)
        .map(|w| (w[k] - w[0]) as f64)
        .collect();
    let var = |xs: &[f64]| {
        let n = xs.len() as f64;
        if n < 2.0 {
            return f64::NAN;
        }
        let m = xs.iter().sum::<f64>() / n;
        xs.iter().map(|x| (x - m).powi(2)).sum::<f64>() / (n - 1.0)
    };
    let v1 = var(&r1);
    let vk = var(&rk);
    if v1 <= 0.0 {
        return f64::NAN;
    }
    vk / (k as f64 * v1)
}
