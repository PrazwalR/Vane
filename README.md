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
more*. Both sides trade at a shifted price. A fee is unsigned and cannot do this.
Measured against an identical plain pool: a buyer forgoes 0.0100 per unit notional, a
seller gains 0.0100. This is a quote, not a toll.

**Self-limiting.** Flow against the belief is paid out, but that same flow drives `delta`
toward zero, so the exposure extinguishes itself. A round trip through the belief loses
money for the trader.

## Estimating the inputs on chain

Everything is computed inside the hook in integer arithmetic, within a 45,000 gas budget.

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
deploy path. 118 tests, including fuzz and threat-model regressions.

**M6 is not done.** The Rust replay simulator does not exist yet, and until it does the
following are open rather than settled: the decay rate `theta` and horizon `K` (both must
be calibrated from a target pool's arbitrage latency and variance ratio), the controller's
noise and gain targets, and — most importantly — whether the mechanism's edge is large
enough on real flow to be worth the gas and reserve risk. Every parameter shipped in
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
