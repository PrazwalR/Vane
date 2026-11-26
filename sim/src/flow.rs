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
        out.push(Block {
            fundamental_ln: v,
            noise,
        });
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

#[cfg(test)]
mod tests {
    use super::*;

    /// Builds a pure random walk in tick space from the same generator the simulator uses.
    fn random_walk(n: usize, step: f64, seed: u64) -> Vec<i32> {
        let mut rng = ChaCha8Rng::seed_from_u64(seed);
        let mut t = 0.0f64;
        (0..n)
            .map(|_| {
                t += step * normal(&mut rng);
                t.round() as i32
            })
            .collect()
    }

    /// The claim the whole activation analysis rests on: under a martingale price the
    /// variance ratio is one. If this estimator were biased, `VR > 4` would be measuring
    /// the estimator rather than the market.
    #[test]
    fn variance_ratio_of_a_random_walk_is_about_one() {
        for k in [2usize, 5, 10] {
            let mut acc = 0.0;
            let trials = 40;
            for seed in 0..trials {
                acc += variance_ratio(&random_walk(4000, 30.0, seed), k);
            }
            let mean = acc / trials as f64;
            assert!(
                (mean - 1.0).abs() < 0.15,
                "VR({k}) on a random walk should be ~1, got {mean}"
            );
        }
    }

    /// A trending series must read above one, and a mean-reverting series below one.
    /// Getting these backwards would invert the activation condition.
    #[test]
    fn variance_ratio_separates_trending_from_mean_reverting() {
        // Positively autocorrelated increments, not a drift. The ratio is computed on
        // demeaned returns, so a constant drift moves the mean and leaves the variance
        // ratio at one — what lifts it above one is persistence in the increments, which
        // is exactly what the `momentum` parameter models.
        let mut rng = ChaCha8Rng::seed_from_u64(99);
        let (mut t, mut step) = (0.0f64, 0.0f64);
        let trending: Vec<i32> = (0..4000)
            .map(|_| {
                step = 0.85 * step + 12.0 * normal(&mut rng);
                t += step;
                t.round() as i32
            })
            .collect();
        let vr = variance_ratio(&trending, 5);
        assert!(
            vr > 2.0,
            "autocorrelated increments must read well above one, got {vr}"
        );

        let reverting: Vec<i32> = (0..2000).map(|i| if i % 2 == 0 { 0 } else { 40 }).collect();
        assert!(
            variance_ratio(&reverting, 5) < 0.5,
            "an alternating series must read well below one, got {}",
            variance_ratio(&reverting, 5)
        );
    }

    /// Momentum is the knob the activation experiment turns, so it must actually move the
    /// variance ratio monotonically.
    #[test]
    fn momentum_raises_the_variance_ratio() {
        let vr_at = |m: f64| {
            let p = FlowParams {
                blocks: 3000,
                sigma: 0.0004,
                momentum: m,
                ..Default::default()
            };
            let blocks = generate(p, 7);
            // Read the fundamental itself in tick space; this isolates the generator from
            // the pool so the test measures only what `momentum` does.
            let ticks: Vec<i32> = blocks
                .iter()
                .map(|b| (b.fundamental_ln / LN_1_0001).round() as i32)
                .collect();
            variance_ratio(&ticks, 5)
        };

        let (flat, trend) = (vr_at(0.0), vr_at(0.9));
        assert!(
            trend > flat * 1.5,
            "momentum 0.9 should raise VR well above momentum 0 ({flat} -> {trend})"
        );
    }

    #[test]
    fn variance_ratio_refuses_a_series_too_short_to_measure() {
        assert!(variance_ratio(&[1, 2, 3], 5).is_nan());
        assert!(variance_ratio(&[], 2).is_nan());
        // A constant series has zero one-step variance and no defined ratio.
        assert!(variance_ratio(&[7; 200], 5).is_nan());
    }

    #[test]
    fn normal_has_unit_moments() {
        let mut rng = ChaCha8Rng::seed_from_u64(11);
        let xs: Vec<f64> = (0..20_000).map(|_| normal(&mut rng)).collect();
        let n = xs.len() as f64;
        let mean = xs.iter().sum::<f64>() / n;
        let var = xs.iter().map(|x| (x - mean).powi(2)).sum::<f64>() / (n - 1.0);
        assert!(mean.abs() < 0.05, "mean should be ~0, got {mean}");
        assert!((var - 1.0).abs() < 0.08, "variance should be ~1, got {var}");
    }

    #[test]
    fn poisson_matches_its_rate() {
        let mut rng = ChaCha8Rng::seed_from_u64(3);
        for lambda in [1.0f64, 3.0, 20.0] {
            let n = 20_000;
            let total: usize = (0..n).map(|_| poisson(&mut rng, lambda)).sum();
            let mean = total as f64 / n as f64;
            assert!(
                (mean - lambda).abs() < lambda * 0.1,
                "poisson({lambda}) mean should be ~{lambda}, got {mean}"
            );
        }
    }

    /// Reproducibility is the whole basis for comparing two pools on "identical" flow.
    #[test]
    fn generation_is_deterministic_in_the_seed() {
        let p = FlowParams {
            blocks: 200,
            ..Default::default()
        };
        let a = generate(p, 42);
        let b = generate(p, 42);
        let c = generate(p, 43);

        assert_eq!(a.len(), b.len());
        for (x, y) in a.iter().zip(b.iter()) {
            assert_eq!(x.fundamental_ln.to_bits(), y.fundamental_ln.to_bits());
            assert_eq!(x.noise.len(), y.noise.len());
            for (m, n) in x.noise.iter().zip(y.noise.iter()) {
                assert_eq!(m.amount, n.amount);
                assert_eq!(m.zero_for_one, n.zero_for_one);
            }
        }
        assert!(
            a.iter()
                .zip(c.iter())
                .any(|(x, y)| x.fundamental_ln != y.fundamental_ln),
            "a different seed must produce different flow"
        );
    }

    /// Noise sizes are clamped; a clamp that always binds would silently replace the
    /// lognormal with a constant.
    #[test]
    fn noise_sizes_vary_and_stay_within_their_clamp() {
        let p = FlowParams {
            blocks: 500,
            noise_rate: 10.0,
            ..Default::default()
        };
        let sizes: Vec<i128> = generate(p, 5)
            .iter()
            .flat_map(|b| b.noise.iter().map(|t| -t.amount))
            .collect();

        assert!(
            sizes.len() > 1000,
            "expected a usable sample, got {}",
            sizes.len()
        );
        assert!(sizes
            .iter()
            .all(|&s| (1e15 as i128..=5e22 as i128).contains(&s)));
        let distinct = sizes.iter().collect::<std::collections::HashSet<_>>().len();
        assert!(
            distinct > sizes.len() / 2,
            "sizes should be dispersed, got {distinct} distinct"
        );
    }
}
