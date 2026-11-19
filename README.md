# VANE

**A Uniswap v4 hook that gives a pool a posterior.**

> A weather vane cannot see the wind. It reveals the wind by turning.

A pool cannot see information. VANE makes it reveal information by turning — inferring
the informed signal from the deflection of its own order flow, and correcting its quote
accordingly. No oracle, no auction, no operator, and no off-chain co-processor.

## The problem

Every constant-function AMM does two jobs with one mechanism. **Settlement** — who gets
what, at what ratio — which the curve does well. And **price discovery** — updating
beliefs when a trade carries information — which the curve does by accident, and always
by too little.

A Glosten-Milgrom market maker, after an informative buy, moves its quote *past* where
the fill landed, because the buy was evidence. An AMM moves exactly the fill distance
along the curve and stops. The gap is free money, and the next arbitrageur collects it.

Worse, the gap grows with deposits. Price impact for a concentrated-liquidity position is
`lambda_amm = 2/D` where `D = L*sqrt(P)`, while the informationally efficient impact from
Kyle (1985) is `lambda* = sigma/(2U)`. Setting them equal gives an optimal depth

```
D* = 4U / sigma
```

fixed by the market, not by how much capital LPs deposited. For deep pairs `D >> D*`, so
the pool under-reacts — and LVR scales with the liquidity in the pool. **The AMM's
capital-formation incentive is directly opposed to its price-discovery quality.**

## The mechanism

The curve keeps settlement. A hook-maintained belief offset does discovery:

```
P_effective = P_curve * e^delta
d(delta)    = kappa * dq - theta * delta * dt
kappa       = lambda* - lambda_amm = sigma/(2U) - 2/D
```

Three properties this buys:

**Oracle-free.** Every other LVR mitigation needs an exogenous price. VANE derives the
correction endogenously from order flow, because that is what Kyle's model *is*:
extracting the informed signal from aggregate flow when the true value is unobservable.

**Signed, not a fee.** When `delta > 0` the buyer pays more *and the seller receives
more*. Both sides trade at a shifted price, which a fee, being unsigned, cannot do. The side
the hook pays is bounded by the pool's own fee, so the favourable leg can at best break even
against the market; the side it collects on is bounded only by `deltaMax`.

**Every trade pays for the belief it moves.** The belief moves with flow, so a swap is
priced at the *average* belief across its own walk rather than at the belief it found. What
the hook collects and pays is then the change in a potential, `G(x1) - G(x0)` with `G` the
antiderivative of the clamped belief, and it telescopes: a sequence of trades that returns
the belief to where it started nets to zero, however it is split. The only way to be paid
is to walk back a belief somebody else paid to build. This holds against a trader who also
supplies the pool's liquidity in the same transaction and so gets the fee back, which is the
case that defeated every fee-based argument.

## Settlement, and the attacks that shaped it

The 2026-10-11 audit produced two reproductions that took value out of the reserve in one
transaction. Both are now regression tests (`test/AtomicHarvest.t.sol`) with their
assertions inverted.

- **The free first leg.** The belief used to move only at block boundaries, and a block's
  first swap was priced before it moved. So that swap created a belief at no cost, and the
  same actor traded back against it before the block ended, with JIT liquidity returning the
  fee. With no manual state at all, 400 blocks of real flow and one transaction paid the
  attacker 141 ether. Pricing each swap along its own walk closes it: the same transaction
  now loses the attacker 175.
- **The conversion leak.** Flow is measured in currency1, so a currency0 offset has to be
  converted. At the swap's own execution rate, that is a price the trader sets: push the
  pool up with your own liquidity, buy into the belief so the hook collects currency0 while
  it is expensive, sell back for currency1, and put the price back. A fuzz campaign driven
  at that shape found single transactions paying the attacker 35 ether. Currency0 offsets
  are now converted at the price the block *opened* at, bounded against the execution rate
  in the hook's favour. To read that price before anything in the block can move it, the
  block rollover runs in `beforeSwap`, which also aligns every measurement window with a
  block.

Three smaller holes went with them. A belief that outlives a falling gain is revised down
in proportion, because what walks it back is the gain: at a gain of zero it would never
shrink and could be sold into indefinitely. Swaps below one flow unit move the belief by
nothing, so they are now priced at nothing rather than at their notional. And the dust
threshold applies only to payouts, since a symmetric one was a free band worth
`dust^2 / (2 kappa)` a loop.

That left one residual: a party that controls the last transaction of one block and the
first of the next can choose the opening price itself. Push the pool up in block N with
exact-output buys, which settle exactly in currency1, hold the price across the boundary,
and harvest in block N+1 against an inflated reference. A fuzz campaign found it taking
0.138 ether out of the reserve. Conversions are now also bounded against a slow average of
opening prices, weighting each block by 1/16, and the average deliberately excludes the
current block's opening: folding it in let the attacker move the very reference they were
checked against, which still leaked 0.00014 ether. Lagged by a block, a false price has to
survive two boundaries to touch the reference and about a dozen to move it halfway, each
one open to arbitrage. Honest traders pay for this only while the price genuinely trends:
a currency0 offset is then sized at a stale price, so it is overcharged by the offset times
the price's drift from its recent average. The bias always favours the reserve.

## Estimating the inputs on chain

Everything is computed inside the hook in integer arithmetic. Ordinary swaps cost the hook
9,700 gas (no belief) to 24,200 (the first swap of a block), against a 45,000 budget. The
recorded exception is the once-per-horizon checkpoint with an active belief, at 56,000: four
storage slots written once a block plus a payout's reserve read and claim burn, which is a
floor above the budget for that one path. It was reported as 76,200 until the measurement
was moved off the pool's first checkpoint, which pays a one-time 20,000-gas storage write.

**Ticks are log prices.** `ln P = tick * ln(1.0001)`, so a tick difference *is* a log
return up to a constant. Every variance estimate is integer arithmetic — no `ln`, no
`exp`, no precision loss.

**Route A — Kyle's variance identity.** In equilibrium informed and noise flow contribute
exactly equally to order-flow variance, so `U = sqrt(E[y^2]/2)` from flow the pool
already sees.

**sigma from the horizon, never per block.** A pool that under-reacts shows a small
short-horizon volatility; arbitrage reveals the fundamental only over `k` blocks, so
`sigma^2 = Var(r_k)/k`. Deriving it from per-block variance understates `sigma`, shrinks
`kappa` toward zero, and fails *silently in the direction of doing nothing* — the single
most likely way for this design to look like it works while doing nothing. A regression
test builds a trending series and asserts the horizon estimate exceeds the per-block one
by `sqrt(k)`.

**Route B — autocovariance cross-check.** `U^2 = Var(y) - Cov1^2/Cov2`, where the serial
correlation of informed flow is identified as `rho = Cov2/Cov1` rather than supplied as a
parameter. Route A is exact only at an informed share of one half, which is what Kyle
equilibrium predicts; Route B holds more generally. Their divergence measures how far the
pool sits from the model Route A relies on, and shrinks `kappa` when it is large.

**Route C — variance-ratio control.** Under efficient pricing variance scales linearly
with horizon, so `VR(k) = Var(r_k)/(k*Var(r_1))` should be 1. The pool measures whether
its own price is a martingale and tunes its own price-discovery gain until it is. This is
model-free: it needs only the definition of an efficient price.

## Status

M0 through M5 are implemented and tested: the signed offset and its v4 accounting, both
variance estimators, depth and open-loop `kappa`, the leaky variance-ratio controller,
the Route B divergence check, the reserve and its graceful degradation, and a validated
deploy path. 262 Solidity tests plus 15 covering the replay engine, including fuzz,
stateful invariants, threat-model regressions and the audit's reproductions; slither
reports nothing.

**M6 exists, and its result is negative.** The Rust replay simulator in `sim/` executes
the compiled hook inside `revm` against Kyle-model order flow. It found that under
volatility generated by the pool's own flow, the open-loop gain is **identically zero**:

```
sigma = lambda_amm * U = (2/D) * U   =>   lambda* = 1/D = lambda_amm / 2 < lambda_amm
```

Sigma and U are not two readings of the market — the AMM's impact function ties them
together, at a ratio of exactly one half, independently of depth, volatility, fee tier and
noise volume. Confirmed across 15 configurations spanning four orders of magnitude of
depth, with measured `D/D*` in [0.50, 0.71].

The same algebra names the escape: over `k` blocks a trending price gives
`sigma_k = sigma_1 * sqrt(k * VR)` while `U_k = U_1 * sqrt(k)`, so a correction exists
only where **VR > 4**. Tested by making the fundamental trend, the gain turns on where the
algebra puts it: zero at VR(5) = 3.08, live at 3.79.

**And past activation it now acts.** Until the settlement rework the belief peaked at about
half of its own dust threshold, so no offset was ever applied and the reserve never moved.
With collections no longer gated by dust and every swap paying for its own walk, the
trending replays show the first effect, 400 blocks against an identical plain pool:

| momentum | VR(5) | gain | arbitrage profit vs plain | reserve |
|---:|---:|---|---:|---:|
| 0.0  | 1.06 | zero | unchanged | 0 |
| 0.8  | 3.08 | zero | unchanged | 0 |
| 0.9  | 3.79 | live | **-0.13%** | **+0.09 ETH** |
| 0.95 | 4.20 | live | **-0.51%** | **+0.81 ETH** |

Arbitrage profit marked at the fundamental is LVR, so this is LVR falling, paid for by the
flow that trends the price and not by the reserve. It is one seed and a small number, and it
is the mechanism doing what it says rather than a calibration of how much.

A note on the test suite, because it changed what "organic" means here. The tests used to
warm the estimators with flow that flips direction every block, and that produced a gain
only because a block's first swap was counted in the previous block's sample: each window
held one swap each way, the measured flow cancelled, and the estimator read near-zero noise
against real volatility. Aligning the windows with blocks removed that artifact, which was
also a way to inflate the gain on purpose, and the warm-ups now trend.

Open, therefore: whether to promote Route B from an attenuator to the primary noise
estimator, or to make `VR > 4` an explicit precondition and scope the claim to pools that
genuinely trend. The decay rate `theta` and horizon `K` are still uncalibrated, but there is
now a regime that produces a payout to calibrate them against. Every parameter shipped in
`script/VaneParameters.sol` is a documented placeholder, not a default.

## Layout

```
src/
  VaneHook.sol              orchestration only, no arithmetic
  config/VaneConfig.sol     every tunable, validated at construction
  libraries/
    Q64x64.sol              fixed point, the tick constants
    DepthLib.sol            D = L*sqrt(P) from live pool state
    FlowVariance.sol        E[y^2] and U                          Route A
    FlowAutocovariance.sol  lag-1 and lag-2 covariance, rho        Route B
    HorizonVariance.sol     Var(r_1), Var(r_k), sigma, VR
    VarianceRatio.sol       the leaky controller                  Route C
    KappaLib.sol            kappa = lambda* - lambda_amm
    BeliefState.sol         belief update, decay, reserve scaling
    OffsetDelta.sol         belief -> BeforeSwapDelta
    PoolStateLib.sol        packed state, documented bit budgets
script/                     address mining, deploy, pool init
test/                       unit, fuzz, integration, threat model, gas
```

`VaneHook.sol` contains no arithmetic. Every formula lives in a pure library that is
unit-testable and fuzzable without a `PoolManager`. That is what makes the math auditable.

## Build

```
forge install
forge build
forge test
```

Deployment mines an address carrying exactly five permission flags, because v4 reads a
hook's permissions from the low 14 bits of its own address:

```
cp .env.example .env      # fill in POOL_MANAGER, DEPLOYER_PRIVATE_KEY
forge script script/DeployVane.s.sol --rpc-url $RPC_URL --broadcast
forge script script/InitializePool.s.sol --rpc-url $RPC_URL --broadcast
```

Two things learned redeploying to Sepolia in November 2026:

- **Forge's gas estimates can be far too low.** Forge simulates with the Cancun schedule in
  `foundry.toml`, and Sepolia now charges about 1,540 gas per byte of deployed code against
  Cancun's 200, so creations ran out of gas at forge's estimate. The hook alone takes 33.1M.
  Pass `--gas-estimate-multiplier 1000` on such a chain, or send the creation with
  `cast send --gas-limit` set from the node's own `eth_estimateGas`.
- **Mine the salt off chain.** Mining inside a forked script costs an RPC round trip per
  candidate address, long enough for a public node to stop serving the forked block. Print
  the init code hash with `script/PrintCtorArgs.s.sol`, mine with
  `cast create2 --ends-with 30c4 --init-code-hash <hash>`, and pass the salt as `VANE_SALT`
  to `script/TestnetDeploy.s.sol`. That script is resumable: rerun with the same salt and
  `TOKEN0`/`TOKEN1`, and every step that already landed is skipped.

## Prior art

**ZeroSwap** (arXiv:2310.09413) and **Adaptive Curves** (arXiv:2406.13794) share the
oracle-free goal and the motivation, and Adaptive Curves has a v4 hook, so VANE claims
neither "first oracle-free adaptive AMM" nor "first adaptive v4 hook". Both are
Glosten-Milgrom; Kyle appears in each only as a bibliography entry, and neither derives an
optimal depth or matches price impact. Adaptive Curves reshapes the bonding curve to
`x^theta * y^(1-theta)` and depends on an off-chain ML co-processor.

What VANE claims is narrower and specific: matching Kyle's `lambda` by closing the gap
between pool depth and `D* = 4U/sigma`; settling through a signed offset that moves buyers
and sellers in opposite directions rather than reshaping the curve; computed entirely on
chain, with no oracle **and no co-processor**.

## References

- Kyle, *Continuous Auctions and Insider Trading*, Econometrica 53(6), 1985
- Glosten & Milgrom, *Bid, Ask and Transaction Prices*, JFE 14(1), 1985
- Roll, *A Simple Implicit Measure of the Effective Bid-Ask Spread*, JF 39(4), 1984
- Lo & MacKinlay, *Stock Market Prices Do Not Follow Random Walks*, RFS 1(1), 1988
- Milionis, Moallemi, Roughgarden, Zhang, *Automated Market Making and
  Loss-Versus-Rebalancing*, arXiv:2208.06046

## Licence

MIT.
