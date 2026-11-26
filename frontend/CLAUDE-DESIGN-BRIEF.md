# VANE — project brief for Claude Design

Everything a designer needs to design the VANE website without reading the code. Every number
here is real: it comes from the repository, the replay simulator, or the live contract on
Ethereum Sepolia. Nothing is a placeholder unless it says so.

- Live site today: https://vane.prazwal.xyz (a single long research page; it is being replaced)
- Source: https://github.com/PrazwalR/Vane
- Sister project, for reference: https://touchstone.prazwal.xyz (see section 14)
- Brand files to attach with this brief: `frontend/public/brand/vane-lockup.png`,
  `vane-mark.png`, `vane-wordmark.png`, `vane-icon-512.png`, `vane-icon-180.png`

---

## 1. VANE in one breath

VANE is a **Uniswap v4 hook** that gives a liquidity pool a **posterior**: a belief about where
the price is really going, inferred from the pool's own order flow. When trades lean one way,
the hook shifts the price the next trader gets, in that direction, before an arbitrageur can
take the difference out of the liquidity providers. No price oracle, no auction, no operator,
no off-chain machine-learning box. Everything is computed on chain, in integer arithmetic,
inside the swap.

Tagline: **A Uniswap v4 hook that gives a pool a posterior.**

Epigraph (the name's origin): **"A weather vane cannot see the wind. It reveals the wind by
turning."** A pool cannot see information either. VANE makes it reveal information by turning:
reading the informed signal from how its own flow deflects it, and correcting its quote.

---

## 2. The problem it attacks

Every automated market maker does two jobs with one mechanism:

1. **Settlement** — who gets what, at what ratio. The curve does this well.
2. **Price discovery** — updating the price when a trade carries information. The curve does
   this by accident, and always by too little.

A human market maker who sees an informed buy moves their quote **past** where the trade
landed, because the trade was evidence. An AMM moves exactly the trade distance along its curve
and stops. The gap between "where the price should be" and "where the curve left it" is free
money, and the next arbitrageur takes it. That loss is called **LVR — loss-versus-rebalancing**.
It is the main reason passive liquidity provision loses money.

It gets **worse as the pool gets deeper**. The price impact of a concentrated-liquidity pool is

    λ_amm = 2 / D,   where D = L·√P   (pool depth)

The informationally efficient impact, from Kyle (1985), is

    λ* = σ / (2U)    (σ = volatility of the true value, U = noise-trading volume)

Setting them equal gives an optimal depth

    D* = 4U / σ

which is fixed by the market, not by how much capital LPs deposited. Deep pairs sit far above
D*, so they under-react, and LVR scales with the liquidity in the pool. **The AMM's incentive
to attract capital runs directly against the quality of its price discovery.** That follows
from multiplying two published results that have coexisted for years.

---

## 3. The mechanism

The curve keeps settlement. A small, signed, hook-maintained offset — the **belief**, δ — does
discovery:

    P_effective = P_curve · e^δ
    dδ = κ·dq − θ·δ·dt
    κ  = λ* − λ_amm = σ/(2U) − 2/D

- **δ (delta), the belief**: a log-price offset. +1% means buyers pay ~1% more and sellers
  receive ~1% more than the bare curve would give them.
- **κ (kappa), the gain**: how far one unit of net order flow moves the belief.
- **θ (theta), the decay**: how fast the belief fades when flow stops supporting it.
- **dq**: net signed order flow (buys positive, sells negative).

κ grows with depth: the correction scales with the disease.

Four properties, each a headline-worthy idea:

1. **Oracle-free.** Every other LVR fix needs an outside price (an oracle, an auction, a
   validator set). VANE derives the correction from order flow, because that is what Kyle's
   model is: extracting the informed signal from aggregate flow when the true value is
   unobservable.
2. **Signed, not a fee.** When the belief is positive a buyer pays slightly more **and a seller
   receives slightly more**. Both sides trade at a shifted price. A fee is unsigned and takes
   from everyone; this is a quote that moves in a direction.
3. **Every trade pays for the belief it moves.** A swap is priced at the *average* belief
   across its own walk, not at the belief it happened to find. What the hook collects and pays
   is then the change in a potential, and it telescopes: any sequence of trades that returns
   the belief to where it started nets to zero, however it is split. The only way to be paid
   is to walk back a belief somebody else paid to build.

       take = G(x₁) − G(x₀),   G(x) = ∫₀ˣ clamp(t) dt

4. **One price a transaction cannot move.** Offsets paid in the non-quote token are converted
   at the price the block *opened* at (read before the block's first swap), bounded by a slow
   average of earlier blocks' openings — never at a rate the trader's own transaction produced.

The **reserve**: the hook holds a small reserve of both tokens (5,000 of each on Sepolia). It
collects when flow runs with the belief and pays when flow runs against it. Payouts are bounded
by the pool's own fee, scaled down when the reserve is below target, and never exceed what the
hook holds.

---

## 4. How the hook estimates its inputs on chain

Everything lives in pure libraries; the hook itself only orchestrates. That makes the maths
auditable and fuzzable.

- **Ticks are already log prices.** A Uniswap tick is defined by P = 1.0001^tick, so a
  difference of ticks *is* a log return. Every variance estimate is integer arithmetic on
  int24 values — no logarithm, no exponential, no precision loss.
- **Route A — Kyle's variance identity.** In Kyle equilibrium, informed and noise flow
  contribute exactly equally to order-flow variance, so U = √(E[y²]/2), from flow the pool
  already sees.
- **Volatility from the horizon, never per block.** A pool that under-reacts looks calm block
  to block; the truth shows only over several blocks. σ² = Var(r_k)/k over a k-block horizon.
  Measuring per block would understate σ and fail *silently in the direction of doing
  nothing* — the most likely way for this design to look like it works while doing nothing.
- **Route C — variance-ratio control loop.** Under efficient pricing, variance scales linearly
  with horizon, so VR(k) = Var(r_k)/(k·Var(r_1)) should be 1. The pool measures whether its own
  price is a martingale and tunes its own gain until it is. Model-free.
- **Route B — removed.** An autocovariance cross-check, meant to catch Route A misjudging the
  informed share. In every simulated regime it never once identified a noise scale, so all it
  ever did was cut the gain to a quarter, at 8,000 gas a block. That quarter is now a stated
  parameter (`gainScale` = 1/4), and the cross-check is gone. (A good "we removed our own
  feature because the data said so" story.)

Saturation guards: if any estimator overflows its storage, the gain is withheld until the
measurement is trustworthy again, and recovery is automatic.

---

## 5. The central research finding (the honest part)

The replay simulator runs the **compiled hook bytecode** inside an EVM (revm), against
Kyle-model order flow, next to a plain Uniswap pool on identical liquidity. It found:

1. **Under volatility the pool's own flow creates, the gain is identically zero.** The AMM's
   impact function ties σ and U together: σ = (2/D)·U ⇒ λ* = 1/D = λ_amm / 2 < λ_amm ⇒ κ = 0.
   Confirmed across 15 configurations spanning four orders of magnitude of depth.
2. **A correction exists only where the variance ratio exceeds 4** — i.e. the price genuinely
   trends. The algebra predicts it; the simulator confirms the gain switches on where predicted.
3. **Where it switches on, it now works** (after the settlement rework and calibration):
   arbitrage profit against the pool (= LVR) falls and the hook's reserve grows.

So the claim is narrow and proven: VANE does nothing in a near-martingale market (correct —
there is nothing to correct) and reduces LVR in a trending one.

---

## 6. Calibration results (real simulator numbers)

Swept the decay rate θ and horizon K across **306 replays** of 400 blocks: three trend
strengths, six random seeds, 17 parameter combinations. The horizon is the lever, with an
interior optimum: **5 blocks** beats 3 and 10; 2 is nearly inert. Slower decay helps with
diminishing returns; **θ = 1/200 per block** ships. Against the previous placeholder values,
the mean LVR reduction across trending runs rose from **0.54% to 3.44%**.

At the shipped parameters (six seeds per row; 1,000,000 ether of liquidity, 0.30% fee tier):

| Trend strength (momentum) | Variance ratio VR(5) | Gain live | Arbitrage profit vs plain pool | Reserve |
|---:|---:|---:|---:|---:|
| 0.00 | 1.28 | 0 of 6 | unchanged | 0 |
| 0.80 | 3.22 | 5 of 6 | −0.22% (to −0.77%) | +0.04 ETH |
| 0.90 | 3.86 | 6 of 6 | −1.59% (−0.18% to −3.86%) | +0.75 ETH |
| 0.95 | 4.25 | 5 of 5 | −5.66% (−0.71% to −10.2%) | +5.28 ETH |

Across all 306 replays: a martingale price switched the gain on **0** times; **no** trending
run left LVR worse than the plain pool; **no** run lost reserve. One 0.95 seed ran the price out
of the pool's liquidity band and is reported separately — it is the run that found the
"empty ticks" bug in section 7.

Chart ideas this data supports: LVR reduction vs trend strength (with seed spread as a range),
gain-live fraction vs variance ratio with the VR = 4 threshold marked, reserve change vs trend,
a θ × K heatmap of mean LVR reduction (17 cells; 5-block row is the hot row).

---

## 7. The incident register — what broke, what was fixed

This project's credibility comes from stating failures as plainly as successes. Every row was
reproduced with a failing test first, fixed, and kept as a regression test (most fixes were
also checked by reverting them and watching the test catch the bug again). Severity is
Critical / High / Medium; state is Fixed / Open.

**Critical**
- Entire reserve stealable in one transaction: the offset was sized from the *requested*
  amount, which a price limit decouples from what actually executes. — Fixed
- Large honest swaps bricked the swap path: scaling the belief by reserve over target cannot
  bound the payout, because the reserve level cancels algebraically. — Fixed
- The belief could never form: one extra division by the fixed-point scale truncated every
  update to zero. Two audit passes blamed the parameters; it was one line. — Fixed
- One transaction could build a belief for free and trade back against it: a block's first
  swap was priced before the belief it created, and liquidity supplied in the same transaction
  returned the fee. **141 ether** out of the reserve, from a gain formed by real flow, no manual
  state. After the fix the same attack **loses the attacker 175 ether**. — Fixed
- Currency0 offsets were converted at a price the trader's own transaction set: push the pool
  with your own liquidity, collect at the inflated rate, put the price back. Up to **35 ether
  per transaction**. — Fixed

**High**
- Gain inflatable 2.16× by liquidity added and removed inside one block. — Fixed
- Reserves had no withdrawal path and were permanently stranded. — Fixed
- Estimator saturation failed open: a clamped noise estimate inflated the gain for no reason
  the market supplied. — Fixed
- A belief outlived a withdrawn gain and could be sold into for as long as the reserve lasted
  (0.75 ether on 250 of one-way flow). — Fixed
- A price held off the market for tens of blocks, re-pushed every block against an arbitrageur
  restoring it, drained **18.3 ether** from a shallow pool. Fixed by pricing only measurable
  flow, a fee-free fallback rate, and a 1/64-per-block opening-price average. — Fixed
- A pool whose price ran past its liquidity opened the next block near the minimum tick; a
  conversion overflowed a guard that returned zero, so a buy through the empty ticks built
  belief for free and the sell back was paid **235 ether, three times**. — Fixed

**Medium**
- The second-estimator guard failed open under alternating flow. — Fixed
- The gas regression gate could never fail. — Fixed
- No deploy script could set a per-pool flow unit. — Fixed
- Measurement windows straddled blocks, which let flipping flow inflate the gain on demand —
  and the test suite's own "organic" gain turned out to depend on it. — Fixed
- Swaps smaller than one flow unit were paid on their notional while moving the belief by
  nothing, so the same payout could be taken repeatedly. — Fixed
- On a dynamic-fee pool the payout bound read the fee field's flag as an 838% fee. — Fixed
- Whoever controlled one block boundary could choose the opening price: 0.138 ether. — Fixed
- Gas was measured inside one long test transaction; the first swap of a block really cost
  45,194, not the 24,246 reported. — Fixed

**Open**
- The gain is zero unless the variance ratio exceeds 4 (by the algebra, not a bug).
- A checkpoint forced onto a paid swap costs 58,369 gas against a 45,000 budget; reachable only
  by opening every block on the paying side for an extra horizon.
- Calibration is against one simulated market; a real pool would want its own sweep.

Design note: open rows must be as visually present as fixed ones. Severity is a quiet text
label or outlined pill, never a filled red badge, never colour alone.

---

## 8. Engineering facts (for a "status" or "proof" module)

| Measure | Value |
|---|---|
| Solidity tests | 265 in 28 suites, all passing |
| Replay-engine (Rust) tests | 15 |
| Stateful invariants | 7, deep-run at 512 runs × 128 calls (65,536 calls each) |
| Line / branch coverage | 95.5% / 89.63% |
| Static analysis (slither) | 0 findings |
| Contract runtime size | 21,242 bytes |
| Simulator replays (calibration) | 306 |
| CI | build, tests, deep fuzz, invariants, coverage gate, gas gate, simulator, slither, secret scan |

Gas the hook adds to a swap (budget 45,000):

| Swap path | Gas |
|---|---:|
| Swap, no belief | 20,741 |
| First swap of an ordinary block | 26,314 |
| Swap paid or charged by an active belief | 38,829 |
| Horizon checkpoint | 40,079 |
| Paid first swap of a block, checkpoint due | 44,743 |
| Checkpoint forced onto a paid swap (rare, attacker-paid) | 58,369 |

---

## 9. The live deployment (what a dashboard can actually show)

Network: **Ethereum Sepolia** (chain id 11155111). Source verified on Etherscan.

| Thing | Address / value |
|---|---|
| VANE hook | `0xb6aEb564dD04b89D2e6B5861d745cE951e2530c4` |
| Uniswap v4 PoolManager | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| Pool id | `0xa545406676c36c1d53b768e522d4003f541fa0eea25ec54be189f5093ce3b587` |
| Token0 (VANE-A test token) | `0x6010599B60CcF158066067653BC673b2980C05B6` |
| Token1 (VANE-B test token) | `0xAc42C79DcBfd9e4DcFa800a4bf9cc75dA154BD2f` |
| Swap router | `0xec1357f460e8856e7fa5A62Df00D368bb608Fd12` |
| Liquidity router | `0x50796c73eF889794488b5B85bEFB86B1D93f0D88` |
| Fee tier / tick spacing | 0.30% / 60 |
| Liquidity | 50,000 (both tokens, 18 decimals) |
| Reserve | 5,000 of each token |
| Hook permission flags | 0x30C4 (beforeInitialize, afterInitialize, beforeSwap, afterSwap, afterSwapReturnDelta) |
| Built from commit | `9f9be6d` |

Shipped parameters (all on chain via `config()`): decay θ = 1/200 per block; horizon K = 5
blocks; variance EWMA 0.99; gain cap 0.1% per flow unit; belief cap ±1%; dust 0.0001%; flow
unit 10¹² wei of token1; default reserve target 100; gain scale 1/4.

### What can be read live (browser → public RPC, no backend today)

View functions on the hook:
- `beliefOf(poolId)` → int256, Q64.64. Divide by 2⁶⁴ for a log-price offset; × 10⁴ for basis points.
- `kappaOf(poolId)` → uint256, Q64.64 per flow unit. Human form: basis points of belief per
  1 ether of net flow = κ/2⁶⁴ × (10¹⁸ / flowUnit) × 10⁴.
- `reserveOf(token)` → the hook's balance of each token (18 decimals).
- `poolState(poolId)` → lastTick, lastBlock, varOne (Q32.32, ticks²), flowVar (flow units²),
  belief, `saturated` flag, `flowUnmeasurable` flag.
- `poolStateAux(poolId)` → checkpointTick, checkpointBlock, varK (Q32.32), kappa, flow
  accumulated this block, opening-tick average (eighths of a tick).
- `openTickAverageOf(poolId)` → the slow opening-price reference, eighths of a tick.
- `config()`, `allowlisted(poolId)`, `flowUnitOf(poolId)`, `targetFor(pool, token)`, `owner()`.

Events, for history and charts:
- `BeliefUpdated(poolId, belief, kappa, varianceRatio)` — at every horizon checkpoint (every
  ≥5 blocks that see a swap). The time series of belief, gain and VR.
- PoolManager `Swap(id, sender, amount0, amount1, sqrtPriceX96, liquidity, tick, fee)` — every
  trade, the price path, the volume.
- PoolManager ERC-6909 `Transfer` events for the hook address — reserve in/out (collections
  and payouts).
- Diagnostics: `FlowEstimateSaturated`, `SaturationCleared`, `FlowUnmeasurable`,
  `PayoutTruncated`, `BeliefScaled`, `ReserveFunded`, `ReserveWithdrawn`, `PoolAllowed`,
  `PoolDisallowed`, `ReserveTargetSet`.

### The honest state of the live pool right now

Belief **0**, gain **0**, reserves **5,000 / 5,000**, a handful of test swaps total. That is
correct, not broken: nobody is trading it, so there is no trend, so (section 5) there is
nothing to correct. **The dashboard's empty and quiet states are its most common states and
must be designed as first-class screens**, explaining *why* a value is zero. Whether to add a
keeper that trades the pool so the dashboard has a story to show is an open decision.

Every live value needs three designed states: **loaded**, **not deployed / no data yet**, and
**RPC unreachable**. "Zero" and "could not fetch" must never look the same.

---

## 10. Pages

Decided:
- **`/` — Live dashboard** (read-only, no wallet). The hook's state on Sepolia, live.
- **`/docs` — the research write-up** (today's page: problem, mechanism, estimation, status,
  incident register, prior art), kept and linked.

Still to be discussed (the owner is bringing a design): whether to add an explainer/overview,
a simulation/results view, and later a swap page, following Touchstone's four-view pattern
(Overview · Swap · Simulation · Docs).

### Dashboard content inventory (modules to design)

1. **Status strip** — network (Sepolia), latest block, "read N s ago", pool allowlisted,
   estimator health (saturated / flow unmeasurable / healthy), link to the verified contract.
2. **Headline readouts** — belief (bp, signed), gain (bp per ETH), variance ratio vs the
   VR = 4 activation line, reserve token0, reserve token1.
3. **"Why is it zero?" explainer state** — when the gain is 0, say so in words: the price is
   not trending (VR below 4), so there is nothing to correct.
4. **Belief over time** — signed line around zero, with the ±1% cap shown, from
   `BeliefUpdated`.
5. **Gain over time** and **variance ratio over time** with the threshold at 4.
6. **Reserve over time** — both tokens, collections up, payouts down.
7. **Price path** — tick per block, with the block-opening reference and the slow
   opening-price average overlaid (it lags by design).
8. **Recent swaps feed** — direction, size, price, and what the hook took or paid on each.
9. **Estimator panel** — σ (from horizon variance), U (noise scale), depth D vs optimal depth
   D*, per-block and horizon variance, current horizon progress (blocks since checkpoint / 5).
10. **Parameters** — the shipped config, each with a one-line meaning.
11. **Contracts** — the address table with explorer links and copy buttons.
12. **Simulator evidence** — the calibration table/chart (section 6), clearly labelled
    *simulation*, never mixed up with *measured* live data.

---

## 11. Number labelling (borrowed from Touchstone)

Every number on the site carries its kind, as a small chip:
- **measured** — read live from the chain, or from the test suite with a date;
- **simulation** — from the replay engine, with the run count;
- **illustrative** — a picture, not data;
- **worked example** — a computed example with stated inputs.

---

## 12. Audience and tone

Readers, in priority order: DeFi researchers and protocol engineers (they read the maths and
notice overstatement); security auditors (what broke, what's open, fast); grant reviewers and
hackathon judges (Uniswap Hook Incubator / Atrium); liquidity providers, eventually.

- A well-made research instrument, not a landing page. Precise, quiet, confident because the
  work is good.
- Plain declarative sentences. Short.
- Every number traceable. Failures stated as plainly as successes; they are the strongest
  credibility signal the project has.
- No emoji. No exclamation marks. No hype words (revolutionary, unlock, supercharge,
  next-generation, seamless). No fake charts, fabricated metrics, placeholder pool data,
  testimonials, waitlists or countdowns.
- No neon-on-black "crypto" gradients, glassmorphism or 3D token renders.

---

## 13. The current VANE identity (starting point, not a constraint)

Logo: a weather-vane mark, wordmark "VANE", and a lockup. **Pure black on transparent**; in dark
mode the files are inverted to pure white.

Type today: **Newsreader** (serif, light weights, headings and epigraph), **Instrument Sans**
(body), **IBM Plex Mono** (every number, equation, address and section label). The mono doing
double duty as labels is what makes it read as an instrument.

Palette today (light / dark):

| Role | Light | Dark |
|---|---|---|
| Ground | #faf8f3 | #12110d |
| Panel | #fffdf8 | #191713 |
| Sunk | #f3f0e8 | #201d18 |
| Ink | #16150f | #f0ece2 |
| Ink 2 (secondary) | #5c574b | #a8a293 |
| Ink 3 (labels) | #8a8475 | #7b7567 |
| Rule / Rule 2 | #e4ded1 / #d3cbba | #2b2821 / #3a362d |
| Accent (amber) | #b0530c | #d98836 |
| OK / Warn / Critical | #44603f / #7f5c13 / #8b3726 | #7fa877 / #c9a34e / #cf7a63 |

Known issue: Ink 3 is 3.5:1 on the light ground (4.1:1 dark) — below 4.5:1, so it only works
for small uppercase labels; a redesign should fix it.

Signature components today: equations set in mono on their own panel with an amber rule;
live values in a hairline grid of cells; outlined severity pills; a sunk callout panel.

---

## 14. Reference: Touchstone (touchstone.prazwal.xyz)

The owner's sister project (a Uniswap v4 hook plus settlement system). Take its **structure**:
- Multi-view site with a sticky nav: **Overview · Swap · Simulation · Docs**, and a **testnet
  badge** in the nav ("all transactions use this testnet").
- A cinematic Overview told in numbered **acts I–IX** (hero with an interactive WebGL object,
  scroll theatre of one worked example, markets, a laboratory, an architecture pipeline with
  real code excerpts, the testnet section, status).
- Every number labelled measured / simulation / illustrative / worked example.
- "Read N s ago" freshness on live data.

Its look, for comparison: dark "instrument" system — near-black ink #0A0A0B, gold #E8B44A,
cyan #5EF2E1 accent, warm off-white text #F3EFE7; Bodoni Moda (display, uppercase, optical
size 96) + Geist (body) + JetBrains Mono (labels); square buttons with 1px lines; eyebrows with
a short gold rule; chips with distinct dot shapes per kind (solid, dashed diamond, dotted
circle).

Whether VANE should sit visually next to Touchstone as a family, or keep its own warm paper
identity, is the owner's call.

---

## 15. Constraints for the build

- Built as a Next.js static site in `frontend/`, deployed on Vercel (`vane.prazwal.xyz`).
- Live data is read in the browser from public Sepolia RPCs (publicnode, 1rpc); there is no
  backend yet. Charts over long history may need a small indexer — design for sparse history.
- Both light and dark themes. Responsive down to 390px; tables, equations and long hashes
  scroll inside their own container, never the page.
- WCAG AA: 4.5:1 body text in both themes; status never by colour alone.
- Long content is normal: addresses are 42 characters, pool ids 66.
- Almost no motion; a value that refreshes may change quietly. Respect reduced motion.

---

## 16. Glossary

- **Hook** — a contract Uniswap v4 calls before/after swaps to customise a pool.
- **Belief (δ)** — the hook's signed price offset, in basis points. Positive means "informed
  buyers are arriving".
- **Gain (κ)** — how much net flow moves the belief.
- **Flow unit** — the hook's unit for measuring order flow (10¹² wei of token1).
- **Horizon (K)** — blocks between checkpoints, where the gain is re-estimated (5).
- **Variance ratio (VR)** — horizon variance over per-block variance; 1 for a random walk,
  above 4 for the trends VANE corrects.
- **LVR** — loss-versus-rebalancing: what arbitrageurs take from LPs.
- **D, D\*** — pool depth, and the depth at which the pool's price impact would be efficient.
- **Reserve** — the hook's own token balance, which pays and collects the offsets.
- **Tick** — Uniswap's log-price unit: price = 1.0001^tick.
- **Q64.64 / Q32.32** — fixed-point formats: divide by 2⁶⁴ / 2³² for the real number.

---

## 17. Prior art (what VANE does not claim)

ZeroSwap (arXiv:2310.09413) and Adaptive Curves (arXiv:2406.13794) share the oracle-free goal,
and Adaptive Curves has a v4 hook, so VANE claims neither "first oracle-free adaptive AMM" nor
"first adaptive v4 hook". Both are Glosten-Milgrom; neither derives an optimal depth or matches
price impact; Adaptive Curves reshapes the curve and depends on an off-chain ML co-processor.

VANE claims something narrower: matching Kyle's impact coefficient by closing the gap between
pool depth and D* = 4U/σ; settling through a signed offset rather than reshaping the curve;
computed entirely on chain, with no oracle and no co-processor.

References: Kyle 1985 (Econometrica); Glosten & Milgrom 1985 (JFE); Roll 1984 (JF); Lo &
MacKinlay 1988 (RFS); Milionis, Moallemi, Roughgarden, Zhang, LVR (arXiv:2208.06046).

---

## 18. Copy bank (ready to use)

- "A Uniswap v4 hook that gives a pool a posterior."
- "A weather vane cannot see the wind. It reveals the wind by turning."
- "The pool under-reacts, and gets worse as it deepens."
- "Settlement stays on the curve. Discovery moves to a belief."
- "Signed, not a fee."
- "Every trade pays for the belief it moves."
- "One price a transaction cannot move."
- "No oracle, no auction, no operator, no co-processor."
- "Where the price is a random walk, VANE does nothing. That is correct: there is nothing to correct."
- "In trending markets it cut arbitrage losses by up to 10% in simulation, paid for by the flow that trends the price, not by the reserve."
- "Research code on a testnet. Not audited by a third party."
