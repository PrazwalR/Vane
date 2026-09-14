# VANE — design brief

Paste everything below the line into Claude. It is written to be self-contained: a
designer who has never seen this repository should be able to work from it alone.

Keep this file updated when the contract changes. A brief that describes a version of
the product that no longer exists is worse than no brief.

---

## THE PROMPT

You are designing the public site for **VANE**, a Uniswap v4 hook. Produce a design
canvas with the artboards listed under *Screens*. Read the whole brief before drawing
anything — the tone constraints matter more than the layout.

### What VANE actually is

Every automated market maker does two jobs with one mechanism. **Settlement** — who gets
what, at what ratio — which the curve does well. And **price discovery** — updating
beliefs when a trade carries information — which the curve does by accident, and always
by too little.

When a trader buys because they know something, a human market maker moves their quote
*past* where the trade landed, because the trade was evidence. An AMM moves exactly the
trade distance along its curve and stops. The difference is money left on the table, and
an arbitrageur collects it a block later.

VANE separates the two jobs. The curve keeps settlement. A small signed offset — the
"belief" — does discovery. When the belief is positive, a buyer pays slightly more **and
a seller receives slightly more**. Both sides trade at a shifted price. This is the
detail that matters: a fee is unsigned and takes from everyone, whereas this is a quote
that moves in a direction.

The belief is inferred from the pool's own order flow. No price oracle, no auction, no
operator, no off-chain machine-learning co-processor. The pool works out what it should
believe by watching how its own trades deflect it — hence the name.

> A weather vane cannot see the wind. It reveals the wind by turning.

### Who this is for

In priority order:

1. **DeFi researchers and protocol engineers.** They will read the math. They will notice
   if a claim is overstated. They are the reason the tone must be austere.
2. **Security auditors.** They want to know what broke, what was fixed, and what is still
   open — quickly, without marketing in the way.
3. **Uniswap Foundation and grant reviewers.** They see a lot of hooks. What distinguishes
   this one is the derivation and the honesty, not the visuals.
4. **Liquidity providers**, eventually. Not yet — the mechanism is not calibrated and the
   site says so.

Nobody in this audience wants to be sold to. Several of them will actively distrust a
site that tries.

### Tone — the hard part

Think a well-made research paper crossed with Stripe's documentation. Precise, quiet,
confident because the work is good rather than because the copy says so.

**Required:**
- Plain declarative sentences. Short. The subject matter is complicated; the writing
  should not add to it.
- Every number traceable to something real. If a figure appears, a reader should be able
  to find where it came from.
- Failures stated as plainly as successes. This project found two critical bugs in its
  own contract and a defect that made the whole mechanism a no-op. That history is the
  strongest credibility signal available and must not be buried.

**Forbidden:**
- No emoji anywhere. Not in headings, not as bullets, not as status icons.
- No exclamation marks.
- No gradient-on-dark "crypto" aesthetic. No neon. No glassmorphism. No 3D token renders.
- No words like *revolutionary*, *unlock*, *supercharge*, *next-generation*, *seamless*.
- No fabricated metrics, no fake charts, no placeholder pool data, no invented testimonials
  or partner logos. If a number is not real, it does not appear.
- No countdown timers, no "join the waitlist", no social proof theatre.

### Screens

**1. Landing (the main artboard).** A single long scroll. Sections in order:

- *Masthead.* Wordmark, one-sentence description, the weather-vane epigraph, and a short
  paragraph of what it does. No hero image, no call-to-action button.
- *The problem.* The under-reaction argument, ending with the optimal-depth relation
  `D* = 4U / σ`. This equation deserves visual weight — it is the thesis.
- *The mechanism.* The three equations, then three short subsections: oracle-free, signed
  rather than a fee, self-limiting.
- *Live state.* Real values read from the deployed contract. See *Data* below.
- *Estimating the inputs.* Four subsections: ticks as log prices, and Routes A, B and C.
- *Status.* Honest counts, and an explicit "not production ready" panel.
- *What the audit found.* A table of findings with severity and current state.
- *Prior art.* What VANE does not claim, before what it does.
- *Footer.* Repository link, licence, a line saying this is research code.

**2. Live state, expanded.** A second artboard treating the live readout as its own page:
belief and κ over time, the variance ratio against its target of 1, reserve health, and
the most recent `BeliefUpdated` events as a table.

**3. Mobile.** The landing at 390px. Equations and tables are the hard part — see
*Constraints*.

### Data that actually exists

The hook is deployed on Ethereum Sepolia at
`0xA0480516F7D6ee73f0eF147808259F952780b044`. Every figure below is readable on chain,
so the live sections are real, not mocked.

**Read functions:** `config()`, `poolState()`, `poolStateAux()`, `flowCovOf()`,
`kappaOf()`, `beliefOf()`, `reserveOf()`, `targetFor()`.

**Events that can be streamed into a table or chart:**
`BeliefUpdated(poolId, deltaX64, kappaX64, varianceRatioX32)`,
`EstimatorDivergence(poolId, noiseA, noiseB, divergenceX32)`,
`BeliefScaled(poolId, scaleNumerator, scaleDenominator)`,
`ReserveFunded`, `ReserveWithdrawn`, `PoolAllowed`, `PoolDisallowed`.

**Verified project figures, safe to display:** 189 tests, 78% branch coverage, 0 static
analysis findings, 17.2 KB runtime size, 4 hook permissions.

**Units — get this right or the display lies.** The belief and κ are Q64.64 fixed point:
divide by `2^64`. Variance and the EWMA decays are Q32.32: divide by `2^32`. The belief
is a log-price offset; show it in basis points, signed, to four decimals — it is a small
number and rounding it to whole bps renders it as zero.

**One semantic trap.** A variance ratio of zero means *no signal* — the per-block variance
has not accumulated yet. It does **not** mean mean-reversion. The controller deliberately
declines to act on it. Display it as "no signal", never as `0.000`, or the design will
assert something false about the mechanism.

### The findings table

This is the most important component on the page and the easiest to get wrong. It must
read as a changelog of honest engineering, not a trophy case.

Rows to include, each with severity and state:

| Finding | Severity | State |
|---|---|---|
| Entire reserve stealable in one transaction — the offset was sized from the requested amount, which a price limit decouples from what executes | Critical | Fixed |
| Large honest swaps bricked the swap path — reserve scaling cannot bound the payout, because the reserve level cancels algebraically | Critical | Fixed |
| The belief could never form — one extra division by the fixed-point scale truncated every update to zero | Critical | Fixed |
| κ inflatable 2.16× by liquidity added and removed within one block | High | Fixed |
| Reserves had no withdrawal path and were permanently stranded | High | Fixed |
| The Route B guard failed open under alternating flow — exactly the wash trader it exists to catch | Medium | Fixed |
| Worst-case gas is 74,369 against a 45,000 budget | — | Open |
| Parameters are uncalibrated placeholders pending the replay simulator | — | Open |

Severity should be a quiet text label or a thin outlined pill. Not a filled red badge,
not an icon. The open rows must be as visually present as the fixed ones.

### Visual direction

- **Typography carries the design.** One serif or a well-drawn grotesque for headings, a
  monospace for every number, equation, address and section label. The monospace doing
  double duty as section labels is what makes it read as an instrument rather than a
  landing page.
- **Restrained palette.** A warm off-white ground, near-black text, a single accent used
  sparingly — for equation rules, links and the wordmark. Amber or burnt orange suits the
  weather-vane idea. Avoid blue; every DeFi site is blue.
- **Generous measure control.** Body text capped around 68 characters. Long lines are what
  make technical writing unreadable.
- **Equations as artefacts.** Set them in monospace on their own ground with a rule down
  the accent-coloured left edge, with an optional explanatory line beneath in the body
  face. They should look deliberately placed.
- **Data in a hairline grid.** Live values as a row of cells separated by 1px rules, with
  a small uppercase monospace label above each large tabular-figure value. Use
  `font-variant-numeric: tabular-nums` so updating values do not jitter.
- **Almost no motion.** No scroll-triggered reveals, no parallax. A value that refreshes
  may cross-fade over roughly 150ms. Nothing else moves.

### Constraints

- **Both themes.** Define the light palette on `:root`, override under
  `prefers-color-scheme: dark` guarded so an explicit light choice still wins, and again
  under an explicit dark selector. Give `body` an explicit background — a transparent body
  borrows the host page's colour and breaks in one theme.
- **Responsive down to 390px.** Tables and equations scroll inside their own container.
  The page body must never scroll horizontally.
- **Accessible.** 4.5:1 contrast for body text in both themes. Do not encode severity in
  colour alone — the label must carry the meaning.
- **Long content is the normal case.** Address strings are 42 characters, pool ids are 66.
  Design truncation with a middle ellipsis, and make the full value available.
- **Empty and error states are first-class.** Design three states for every live value:
  loaded, not deployed, and RPC unreachable. The last two must say so plainly. Never
  render a zero or a dash where a real number failed to arrive — a reader cannot tell the
  difference between "zero" and "we could not fetch it", and on a page about honest
  measurement that distinction is the whole point.

### What success looks like

A researcher lands on this page, reads for ninety seconds, and comes away with three
things: they understand what problem this solves, they believe the author knows where the
design is weak, and they know exactly what is still unproven. Nothing on the page had to
persuade them of anything.
