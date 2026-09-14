import Image from "next/image";
import deployments from "../generated/deployments.json";

const REPO = "https://github.com/PrazwalR/Vane";
const SEPOLIA = deployments["11155111"];
const EXPLORER = `https://sepolia.etherscan.io/address/${SEPOLIA.vaneHook}`;

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
    what: "Worst-case gas is 74,369 against a 45,000 budget.",
    severity: null,
    state: "Open",
  },
  {
    what: "Parameters are documented placeholders pending the replay simulator.",
    severity: null,
    state: "Open",
  },
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
          direction.
        </p>

        <h3>Self-limiting</h3>
        <p>
          Flow against the belief is paid out, but that same flow drives the belief toward
          zero, so the exposure extinguishes itself. A round trip through the belief loses
          money for the trader.
        </p>
      </section>

      <section>
        <p className="eyebrow">Live state</p>
        <h2>Read from the deployed contract</h2>
        <p>
          The hook is deployed on Ethereum Sepolia. These are the addresses; the estimator
          values are deliberately not rendered here yet, because a figure on this page should
          come from a live read rather than a build-time snapshot.
        </p>
        <div className="grid">
          <div className="cell">
            <span className="k">Network</span>
            <span className="v">Sepolia</span>
          </div>
          <div className="cell">
            <span className="k">Hook flags</span>
            <span className="v">{SEPOLIA.hookFlags}</span>
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
          Hook <a href={EXPLORER}>{SEPOLIA.vaneHook}</a>
        </p>
      </section>

      <section>
        <p className="eyebrow">Estimation</p>
        <h2>Three routes, one of which is a control loop</h2>

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

        <h3>Route B — autocovariance cross-check</h3>
        <p>
          The serial correlation of informed flow is <em>identified</em> from the ratio of
          lag-two to lag-one autocovariance rather than supplied as a parameter. Route A is
          exact only at an informed share of one half; Route B holds more generally, so their
          divergence measures how far the pool sits from the model Route A relies on.
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
            <span className="v">189</span>
          </div>
          <div className="cell">
            <span className="k">Branch coverage</span>
            <span className="v">78%</span>
          </div>
          <div className="cell">
            <span className="k">Static analysis</span>
            <span className="v">0</span>
          </div>
          <div className="cell">
            <span className="k">Runtime size</span>
            <span className="v">17.2 KB</span>
          </div>
        </div>
        <p>
          The signed offset and its v4 accounting, both variance estimators, depth and
          open-loop gain, the leaky controller, the divergence check, the reserve and its
          graceful degradation, and a validated deploy path are implemented and tested —
          including seven stateful invariants over roughly fifty thousand randomised calls.
        </p>
        <div className="callout">
          <span className="label">Not production ready</span>
          <p>
            This is research code. The replay simulator does not exist yet, so the decay rate
            and horizon are documented placeholders rather than calibrated values, and the
            self-funding claim is unproven on real flow. The worst-case gas path is over its
            own budget. Nothing here has been audited by a third party.
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
