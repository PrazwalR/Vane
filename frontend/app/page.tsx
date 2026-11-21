import Image from "next/image";
import deployments from "../generated/deployments.json";
import status from "../generated/status.json";
import LiveState from "./LiveState";

const REPO = "https://github.com/PrazwalR/Vane";
const SEPOLIA = deployments["11155111"];
const EXPLORER = `https://sepolia.etherscan.io/address/${SEPOLIA.vaneHook}`;

// The settlement rework moved the block rollover into beforeSwap, so a hook carrying the
// fix must have the BEFORE_SWAP permission bit (1 << 7) in its address. Reading it from the
// deployment record means the page cannot claim a fix the deployed bytecode lacks.
const BEFORE_SWAP_FLAG = 1 << 7;
const HAS_SETTLEMENT_FIX = (SEPOLIA.hookFlags & BEFORE_SWAP_FLAG) !== 0;

type Finding = {
  what: string;
  severity: "Critical" | "High" | "Medium" | null;
  state: "Fixed" | "Open";
};

const FINDINGS: Finding[] = [
  {
    what:
      "Entire reserve stealable in one transaction. The offset was sized from the requested amount, which a price limit decouples from what actually executes.",
    severity: "Critical",
    state: "Fixed",
  },
  {
    what:
      "Large honest swaps bricked the swap path. Scaling the belief by reserve over target cannot bound the payout, because the reserve level cancels algebraically.",
    severity: "Critical",
    state: "Fixed",
  },
  {
    what:
      "The belief could never form. One extra division by the fixed-point scale truncated every update to zero, so the mechanism was inert at any parameter setting.",
    severity: "Critical",
    state: "Fixed",
  },
  {
    what: "Gain inflatable 2.16 times by liquidity added and removed inside one block.",
    severity: "High",
    state: "Fixed",
  },
  {
    what: "Reserves had no withdrawal path and were permanently stranded, including on discovering a bug.",
    severity: "High",
    state: "Fixed",
  },
  {
    what:
      "The second-estimator guard failed open under alternating flow, which is exactly the wash trader it exists to catch.",
    severity: "Medium",
    state: "Fixed",
  },
  {
    what:
      "Estimator saturation failed open. A clamped noise scale inflates the efficient impact coefficient, so the gain turned positive for no reason the market supplied \u2014 every activation in the first parameter sweep was this artefact rather than signal.",
    severity: "High",
    state: "Fixed",
  },
  {
    what:
      "The gas regression gate could never fail. The check was followed by an unconditional regenerate-and-pass, on the single metric tracked as the project's largest open finding.",
    severity: "Medium",
    state: "Fixed",
  },
  {
    what:
      "No deploy script could set a per-pool flow unit, so every pool silently inherited a global default \u2014 the parameter that, set too small, saturates the estimator and holds the gain at zero.",
    severity: "Medium",
    state: "Fixed",
  },
  {
    what:
      "One transaction could build a belief for free and trade back against it. A block's first swap was priced before the belief it created, and liquidity supplied in the same transaction returned the fee: 141 ether out of the reserve, from a gain formed by real flow with no manual state.",
    severity: "Critical",
    state: "Fixed",
  },
  {
    what:
      "Currency0 offsets were converted at a price the trader's own transaction set. Push the pool up with your own liquidity, collect at the inflated rate, put the price back: up to 35 ether out of the reserve per transaction.",
    severity: "Critical",
    state: "Fixed",
  },
  {
    what:
      "A belief outlived a withdrawn gain. At a gain of zero it no longer shrank as it was traded against, so it could be sold into for as long as the reserve lasted.",
    severity: "High",
    state: "Fixed",
  },
  {
    what:
      "Measurement windows straddled blocks. Flow that flipped direction every block cancelled inside a window while the price still moved, which inflated the gain on demand — and the test suite's own “organic” gain turned out to depend on it.",
    severity: "Medium",
    state: "Fixed",
  },
  {
    what:
      "Swaps smaller than one flow unit were paid on their notional while moving the belief by nothing, so the same payout could be taken again and again.",
    severity: "Medium",
    state: "Fixed",
  },
  {
    what: "On a dynamic-fee pool the payout bound read the fee field's flag as an 838% fee.",
    severity: "Medium",
    state: "Fixed",
  },
  {
    what:
      "The open-loop gain is identically zero under flow-induced volatility, by a factor of exactly two. A correction requires a variance ratio above four.",
    severity: null,
    state: "Open",
  },
  {
    what:
      "The effect is small. In trending replays, arbitrage profit against the pool falls by 0.13% to 0.51% and the reserve grows; one seed, uncalibrated parameters.",
    severity: null,
    state: "Open",
  },
  {
    what:
      "Whoever controlled the last transaction of one block and the first of the next could choose the opening price that currency0 offsets were converted at: 0.138 ether out of the reserve. Conversions are now also bounded by a slow average of opening prices that excludes the current block's.",
    severity: "Medium",
    state: "Fixed",
  },
  {
    what:
      "A price held off the market for tens of blocks dragged that average, and in a shallow pool cheaply: an attacker re-pushing the price at the end of every block against an arbitrageur restoring it took 18.3 ether, harvesting through the swap's own execution rate. Fixed by pricing only the flow the estimator can measure, a fee-free execution rate and a 1/64 average.",
    severity: "High",
    state: "Fixed",
  },
  {
    what:
      "A pool whose price ran past its liquidity opened the next block near the minimum tick. A currency0 collection converted there overflowed a guard that returned zero, so a buy through the empty ticks built belief for free and the sell back was paid 235 ether, three times. Collections are now computed at full width and capped at the swap's own leg, crediting only the belief that was paid for.",
    severity: "High",
    state: "Fixed",
  },
  {
    what:
      "Gas was measured in one long test transaction, where every slot the setup touched counts as warm. The first swap of a block really cost 45,194 against a 45,000 budget, not the 24,246 reported, and the worst case 79,738.",
    severity: "Medium",
    state: "Fixed",
  },
  {
    what:
      "Route B, the autocovariance cross-check, never identified a noise scale in any simulated regime, so it only ever applied a fixed quarter to the gain, at 8,000 gas a block. Removed; the quarter is now a stated parameter.",
    severity: null,
    state: "Fixed",
  },
  {
    what: `A checkpoint forced onto a paid swap costs ${status.worstCaseGasOverhead.toLocaleString()} against a ${status.gasBudget.toLocaleString()} budget. Every other path fits; this one is reachable only by opening every block for an extra horizon with a swap on the paying side.`,
    severity: null,
    state: "Open",
  },
  {
    what: "The decay rate and horizon are uncalibrated, though there is now a regime that produces a payout to calibrate them against.",
    severity: null,
    state: "Open",
  },
];

// From `sim/` at commit 2fd533f: 400 blocks, seed 1, 1e6 ether of liquidity at the 0.30%
// tier, against an identical plain pool. Reproduce with
// `./target/release/vane-sim --blocks 400 --momentum <m> --json`.
const SIM_RESULTS = [
  { momentum: "0.00", vr: "1.06", live: false, lvr: "unchanged", reserve: "0" },
  { momentum: "0.80", vr: "3.08", live: false, lvr: "unchanged", reserve: "0" },
  { momentum: "0.90", vr: "3.79", live: true, lvr: "−0.13%", reserve: "+0.09 ETH" },
  { momentum: "0.95", vr: "4.20", live: true, lvr: "−0.51%", reserve: "+0.81 ETH" },
];

function pillClass(f: Finding) {
  if (f.state === "Open") return "pill";
  if (f.severity === "Critical") return "pill crit";
  if (f.severity === "High") return "pill high";
  return "pill";
}

export default function Home() {
  return (
    <main className="wrap">
      <header className="masthead">
        <Image
          className="brand-mark"
          src="/brand/vane-lockup.png"
          alt="VANE"
          width={552}
          height={585}
          style={{ width: 96, marginBottom: 34 }}
          priority
        />
        <h1>A Uniswap v4 hook that gives a pool a posterior.</h1>
        <p className="epigraph">
          A weather vane cannot see the wind. It reveals the wind by turning.
        </p>
        <p className="lede">
          A pool cannot see information. VANE makes it reveal information by turning —
          inferring the informed signal from the deflection of its own order flow, and
          correcting its quote accordingly. No oracle, no auction, no operator, and no
          off-chain co-processor.
        </p>
      </header>

      <section>
        <p className="eyebrow">The problem</p>
        <h2>The pool under-reacts, and gets worse as it deepens</h2>
        <p>
          Every automated market maker does two jobs with one mechanism.{" "}
          <strong>Settlement</strong> — who gets what, at what ratio — which the curve does
          well. And <strong>price discovery</strong> — updating beliefs when a trade carries
          information — which the curve does by accident, and always by too little.
        </p>
        <p>
          When a trader buys because they know something, a human market maker moves their
          quote <em>past</em> where the trade landed, because the trade was evidence. An AMM
          moves exactly the trade distance along its curve and stops. The difference is money
          left on the table, and an arbitrageur collects it a block later.
        </p>
        <p>
          Price impact for a concentrated-liquidity position is <code>λ_amm = 2/D</code> where{" "}
          <code>D = L·√P</code>. The informationally efficient impact from Kyle (1985) is{" "}
          <code>λ* = σ/(2U)</code>. Setting them equal gives an optimal depth:
        </p>
        <div className="eq">
          D* = 4U / σ
          <span className="note">
            Fixed by the market — the ratio of noise volume to volatility — not by how much
            capital was deposited. The two coincide only by accident, and for deep pairs the
            pool sits far above D*.
          </span>
        </div>
        <p>
          Loss-versus-rebalancing scales with the liquidity sitting in the pool. So the
          incentive to attract capital runs directly against price-discovery quality. That
          follows from multiplying two published results that have coexisted for years.
        </p>
      </section>

      <section>
        <p className="eyebrow">The mechanism</p>
        <h2>Settlement stays on the curve. Discovery moves to a belief.</h2>
        <div className="eq">
          P_effective = P_curve · e^δ
          <br />
          dδ = κ·dq − θ·δ·dt
          <br />
          κ = λ* − λ_amm = σ/(2U) − 2/D
          <span className="note">
            Note that κ grows with depth. The correction scales with the disease, which is
            the property you want and almost never get.
          </span>
        </div>

        <h3>Oracle-free</h3>
        <p>
          Every other mitigation needs an exogenous price — a feed, an auction, a validator
          set. VANE derives the correction from order flow, because that is what Kyle&rsquo;s
          model is: extracting the informed signal from aggregate flow when the true value is
          unobservable.
        </p>

        <h3>Signed, not a fee</h3>
        <p>
          When the belief is positive a buyer pays slightly more{" "}
          <strong>and a seller receives slightly more</strong>. Both sides trade at a shifted
          price. A fee is unsigned and takes from everyone; this is a quote that moves in a
          direction. The side the hook pays is bounded by the pool&rsquo;s own fee, so the
          favourable leg can at best break even against the market.
        </p>

        <h3>Every trade pays for the belief it moves</h3>
        <p>
          The belief moves with flow, so a swap is priced at the <em>average</em> belief
          across its own walk, not at the belief it happened to find. What the hook collects
          and pays is then the change in a potential, and it telescopes: any sequence of
          trades that returns the belief to where it started nets to zero, however it is
          split. The only way to be paid is to walk back a belief someone else paid to build.
        </p>
        <div className="eq">
          take = G(x₁) − G(x₀),&nbsp;&nbsp; G(x) = ∫₀ˣ clamp(t) dt
          <span className="note">
            That holds against a trader who also supplies the pool&rsquo;s liquidity in the
            same transaction and so gets the fee back, which is the case that defeated every
            argument resting on the fee.
          </span>
        </div>

        <h3>One price a transaction cannot move</h3>
        <p>
          Flow is measured in the quote token, so an offset paid in the other token has to be
          converted. It is converted at the price the block <em>opened</em> at, which the
          hook reads before the block&rsquo;s first swap executes, and never at a rate the
          trader&rsquo;s own transaction produced. Because whoever controls a block boundary
          could still pick that opening price, the conversion is also bounded by a slow
          average of earlier blocks&rsquo; openings, which the current block cannot touch.
        </p>
      </section>

      <section>
        <p className="eyebrow">Live state</p>
        <h2>Read from the deployed contract</h2>
        <p>
          The hook is deployed on Ethereum Sepolia. The figures below are read from it by
          your browser every fifteen seconds, not baked into the page when it was built.
        </p>
        {!HAS_SETTLEMENT_FIX && (
          <div className="callout">
            <span className="label">Older deployment</span>
            <p>
              This Sepolia hook predates the settlement rework described above, so it still
              carries both one-transaction drains in the incident register. It holds test
              tokens only. A redeploy of the fixed contract is pending.
            </p>
          </div>
        )}
        <LiveState
          hook={SEPOLIA.vaneHook}
          poolId={SEPOLIA.poolId}
          token0={SEPOLIA.token0}
          token1={SEPOLIA.token1}
          flowUnit={SEPOLIA.flowUnit}
        />
        <div className="grid">
          <div className="cell">
            <span className="k">Network</span>
            <span className="v">Sepolia</span>
          </div>
          <div className="cell">
            <span className="k">Hook flags</span>
            <span className="v">0x{SEPOLIA.hookFlags.toString(16).toUpperCase()}</span>
          </div>
          <div className="cell">
            <span className="k">Fee tier</span>
            <span className="v">{(SEPOLIA.fee / 10000).toFixed(2)}%</span>
          </div>
          <div className="cell">
            <span className="k">Tick spacing</span>
            <span className="v">{SEPOLIA.tickSpacing}</span>
          </div>
        </div>
        <p className="addr">
          Built from commit <a href={`${REPO}/commit/${SEPOLIA.commit}`}>{SEPOLIA.commit}</a>.
          Fixes made after that commit are in the source but not in this deployment.
        </p>
        <p className="addr">
          Hook <a href={EXPLORER}>{SEPOLIA.vaneHook}</a>
        </p>
      </section>

      <section>
        <p className="eyebrow">Estimation</p>
        <h2>Two estimators and a control loop</h2>

        <h3>Ticks are already log prices</h3>
        <p>
          A tick is defined by <code>P = 1.0001^tick</code>, so a difference of ticks{" "}
          <em>is</em> a log return scaled by a constant. Every variance estimate is integer
          arithmetic on <code>int24</code> values — no logarithm, no exponential, no
          precision loss. The constant enters exactly once, at the end.
        </p>

        <h3>Route A — Kyle&rsquo;s variance identity</h3>
        <p>
          In equilibrium, informed and noise flow contribute <em>exactly equally</em> to
          order-flow variance, so the noise scale is the root of half the observed variance,
          taken from flow the pool already sees.
        </p>

        <h3>Volatility from the horizon, never per block</h3>
        <p>
          A pool that under-reacts shows a small short-horizon volatility; arbitrage reveals
          the fundamental only over several blocks. Deriving it per block understates the
          volatility, shrinks the gain toward zero, and fails{" "}
          <em>silently in the direction of doing nothing</em> — the most likely way for this
          design to look like it works while doing nothing.
        </p>

        <h3>Route B, removed</h3>
        <p>
          An autocovariance cross-check meant to catch Route A misjudging the informed share.
          In every simulated regime it never identified a noise scale, so all it ever did was
          cut the gain to a quarter, at 8,000 gas on the first swap of every block. That
          quarter is now a stated parameter, and the cross-check is gone.
        </p>

        <h3>Route C — variance-ratio control</h3>
        <p>
          Under efficient pricing, variance scales linearly with horizon. The pool measures
          whether its own price is a martingale and tunes its own gain until it is. This is
          model-free: it needs only the definition of an efficient price.
        </p>
      </section>

      <section>
        <p className="eyebrow">Status</p>
        <h2>Where the work stands</h2>
        <div className="grid">
          <div className="cell">
            <span className="k">Tests</span>
            <span className="v">{status.tests}</span>
          </div>
          <div className="cell">
            <span className="k">Branch coverage</span>
            <span className="v">{status.branchCoveragePct}%</span>
          </div>
          <div className="cell">
            <span className="k">Static analysis</span>
            <span className="v">{status.slitherFindings}</span>
          </div>
          <div className="cell">
            <span className="k">Runtime size</span>
            <span className="v">{(status.runtimeBytes / 1024).toFixed(1)} KB</span>
          </div>
        </div>
        <p>
          The signed offset and its v4 accounting, both variance estimators, depth and
          open-loop gain, the leaky controller, the divergence check, the reserve and its
          graceful degradation, and a validated deploy path are implemented and tested —
          including {status.statefulInvariants} stateful invariants over roughly fifty thousand randomised calls,
          and {status.rustTests} tests covering the replay engine that measures it.
        </p>

        <h3>What the replay simulator measured</h3>
        <p>
          The simulator executes the compiled hook inside an EVM against Kyle-model order
          flow, next to a plain pool on identical liquidity, for 400 blocks. Arbitrage profit
          marked at the fundamental is loss-versus-rebalancing, so a smaller number is LPs
          losing less.
        </p>
        <div className="scroll">
          <table>
            <thead>
              <tr>
                <th>Trend strength</th>
                <th>Variance ratio</th>
                <th>Gain</th>
                <th>Arbitrage profit vs plain pool</th>
                <th>Reserve</th>
              </tr>
            </thead>
            <tbody>
              {SIM_RESULTS.map((r) => (
                <tr key={r.momentum}>
                  <td>{r.momentum}</td>
                  <td>{r.vr}</td>
                  <td>{r.live ? <span className="pill ok">live</span> : "zero"}</td>
                  <td>{r.lvr}</td>
                  <td>{r.reserve}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <p>
          Where the price is a near-martingale the gain is zero, which is correct: there is
          nothing to correct. Once the price trends hard enough the gain switches on where the
          algebra puts it, arbitrage profit falls, and the reserve grows, paid for by the flow
          that trends the price. It is one seed and a small effect.
        </p>

        <div className="callout">
          <span className="label">Not production ready</span>
          <p>
            This is research code. Under volatility generated by the pool&rsquo;s own flow the
            open-loop gain is <strong>identically zero</strong>, because the AMM&rsquo;s
            impact function ties the two estimates it compares together at a ratio of one
            half, so a correction only arises where the variance ratio exceeds four. The
            decay rate and horizon are uncalibrated. Worst-case gas is{" "}
            {status.worstCaseGasOverhead.toLocaleString()} against a{" "}
            {status.gasBudget.toLocaleString()} budget, on the once-per-horizon checkpoint.
            Nothing here has been audited by a third party.
          </p>
        </div>
      </section>

      <section>
        <p className="eyebrow">Audit</p>
        <h2>Incident register</h2>
        <p>
          Every finding below was reproduced with a failing test first, then fixed, then kept
          as a regression. The open rows are listed with the same weight as the closed ones.
        </p>
        <div className="scroll">
          <table>
            <thead>
              <tr>
                <th>Finding</th>
                <th>Severity</th>
                <th>State</th>
              </tr>
            </thead>
            <tbody>
              {FINDINGS.map((f) => (
                <tr key={f.what}>
                  <td>{f.what}</td>
                  <td>
                    {f.severity ? <span className={pillClass(f)}>{f.severity}</span> : "—"}
                  </td>
                  <td>
                    <span className={f.state === "Fixed" ? "pill ok" : "pill"}>{f.state}</span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <p>
          The third row is the instructive one. Two audit passes measured the symptom — the
          belief never moved, and the tests had to set the gain by hand — and both concluded
          the parameters needed re-deriving. It was not the parameters. No parameter choice
          could have fixed it, because the extra division discards the result&rsquo;s entire
          scale regardless of magnitude.
        </p>
        <p>
          The two newest criticals share a lesson. Both were closed by the same argument
          rather than by another bound: make what the hook collects and pays the change in a
          potential, and denominate it in a price nobody inside the transaction can move.
          Each is kept as a regression with its assertion inverted, and the conversion fix is
          checked by reverting it and watching the fuzz campaign find the drain again.
        </p>
      </section>

      <section>
        <p className="eyebrow">Prior art</p>
        <h2>What this does not claim</h2>
        <p>
          <a href="https://arxiv.org/abs/2310.09413">ZeroSwap</a> and{" "}
          <a href="https://arxiv.org/abs/2406.13794">Adaptive Curves</a> share the oracle-free
          goal and the motivation, and Adaptive Curves has a v4 hook. So VANE claims neither
          &ldquo;first oracle-free adaptive AMM&rdquo; nor &ldquo;first adaptive v4
          hook&rdquo;. Both are built on Glosten-Milgrom; Kyle appears in each only as a
          bibliography entry, and neither derives an optimal depth or matches price impact.
          Adaptive Curves reshapes the bonding curve and depends on an off-chain
          machine-learning co-processor.
        </p>
        <p>What it does claim is narrower:</p>
        <ul>
          <li>
            Matching Kyle&rsquo;s impact coefficient by closing the gap between pool depth and{" "}
            <code>D* = 4U/σ</code>
          </li>
          <li>
            Settling through a signed offset that moves buyers and sellers in opposite
            directions, rather than reshaping the curve
          </li>
          <li>
            Computed entirely on chain, with no oracle <strong>and no co-processor</strong>
          </li>
        </ul>
      </section>

      <footer>
        <Image
          className="brand-mark"
          src="/brand/vane-mark.png"
          alt=""
          width={569}
          height={511}
          style={{ width: 28, marginBottom: 18, opacity: 0.5 }}
        />
        <p style={{ margin: 0 }}>
          <a href={REPO}>Source on GitHub</a> · MIT licensed · Research code, not audited for
          production use.
        </p>
      </footer>
    </main>
  );
}
