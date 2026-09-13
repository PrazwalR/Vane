const REPO = "https://github.com/PrazwalR/Vane";

export default function Home() {
  return (
    <main className="wrap">
      <header className="masthead">
        <p className="wordmark">Vane</p>
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
        <h2>The problem</h2>
        <p>
          Every constant-function AMM does two jobs with one mechanism.{" "}
          <strong>Settlement</strong> — who gets what, at what ratio — which the curve does
          well. And <strong>price discovery</strong> — updating beliefs when a trade carries
          information — which the curve does by accident, and always by too little.
        </p>
        <p>
          A Glosten-Milgrom market maker, after an informative buy, moves its quote{" "}
          <em>past</em> where the fill landed, because the buy was evidence. An AMM moves
          exactly the fill distance along the curve and stops. The gap is free money, and the
          next arbitrageur collects it.
        </p>
        <p>
          Worse, the gap grows with deposits. Price impact for a concentrated-liquidity
          position is <code>λ_amm = 2/D</code> where <code>D = L·√P</code>, while the
          informationally efficient impact from Kyle (1985) is <code>λ* = σ/(2U)</code>.
          Setting them equal gives an optimal depth:
        </p>
        <div className="eq">
          D* = 4U / σ
          <span className="note">
            Fixed by the market — the ratio of noise volume to volatility — not by how much
            capital LPs deposited. The two coincide only by accident.
          </span>
        </div>
        <p>
          For deep pairs <code>D ≫ D*</code>, so the pool under-reacts. And LVR scales with
          the liquidity sitting in the pool. So the AMM&rsquo;s capital-formation incentive is
          directly opposed to its price-discovery quality. That follows from multiplying two
          published results that have coexisted for years.
        </p>
      </section>

      <section>
        <h2>The mechanism</h2>
        <p>
          The curve keeps settlement. A hook-maintained belief offset does discovery.
        </p>
        <div className="eq">
          P_effective = P_curve · e^δ
          <br />
          dδ = κ·dq − θ·δ·dt
          <br />
          κ = λ* − λ_amm = σ/(2U) − 2/D
          <span className="note">
            Note ∂κ/∂D &gt; 0. The correction grows with depth — the remedy scales with the
            disease, which is the property you want and almost never get.
          </span>
        </div>

        <h3>Oracle-free</h3>
        <p>
          Every other LVR mitigation needs an exogenous price — Chainlink, Pyth, an auction, a
          validator set. VANE derives the correction endogenously from order flow, because
          that is what Kyle&rsquo;s model <em>is</em>: extracting the informed signal from
          aggregate flow when the true value is unobservable.
        </p>

        <h3>Signed, not a fee</h3>
        <p>
          When <code>δ &gt; 0</code> the buyer pays more <em>and the seller receives more</em>.
          Both sides trade at a shifted price. A fee is unsigned and cannot do this. Measured
          against an identical plain pool, a buyer forgoes 0.0100 per unit notional and a
          seller gains 0.0100. This is a quote, not a toll.
        </p>

        <h3>Self-limiting</h3>
        <p>
          Flow against the belief is paid out, but that same flow drives <code>δ</code> toward
          zero, so the exposure extinguishes itself. A round trip through the belief loses
          money for the trader.
        </p>
      </section>

      <section>
        <h2>Estimating the inputs on chain</h2>
        <p>
          Everything is computed inside the hook in integer arithmetic. No <code>ln</code>, no{" "}
          <code>exp</code>, no fixed-point logarithm.
        </p>

        <h3>Ticks are already log prices</h3>
        <p>
          A Uniswap tick is defined by <code>P = 1.0001^tick</code>, so a difference of ticks{" "}
          <em>is</em> a log return, scaled by <code>ln(1.0001)</code>. Every variance estimate
          is integer subtraction and multiplication on <code>int24</code> values; the constant
          enters exactly once, at the end.
        </p>

        <h3>Route A — Kyle&rsquo;s variance identity</h3>
        <p>
          In equilibrium, informed and noise flow contribute <em>exactly equally</em> to
          order-flow variance, so <code>U = √(E[y²]/2)</code> from flow the pool already sees.
        </p>

        <h3>σ from the horizon, never per block</h3>
        <p>
          A pool that under-reacts shows a small short-horizon volatility; arbitrage reveals
          the fundamental only over <code>k</code> blocks, so <code>σ² = Var(r_k)/k</code>.
          Deriving it from per-block variance understates σ, shrinks κ toward zero, and fails{" "}
          <em>silently in the direction of doing nothing</em> — the single most likely way for
          this design to look like it works while doing nothing.
        </p>

        <h3>Route B — autocovariance cross-check</h3>
        <p>
          <code>U² = Var(y) − Cov₁²/Cov₂</code>, where the serial correlation of informed flow
          is <em>identified</em> as <code>ρ = Cov₂/Cov₁</code> rather than supplied as a
          parameter. Route A is exact only at an informed share of one half, which is what
          Kyle equilibrium predicts; Route B holds more generally. Their divergence measures
          how far the pool sits from the model Route A relies on, and shrinks κ when it is
          large.
        </p>

        <h3>Route C — variance-ratio control</h3>
        <p>
          Under efficient pricing, variance scales linearly with horizon, so{" "}
          <code>VR(k) = Var(r_k)/(k·Var(r₁))</code> should be 1. The pool measures whether its
          own price is a martingale and tunes its own price-discovery gain until it is. This is
          model-free: it needs only the definition of an efficient price, not the truth of
          Kyle&rsquo;s model.
        </p>
      </section>

      <section>
        <h2>Status</h2>
        <div className="grid">
          <div className="cell">
            <span className="k">Tests</span>
            <span className="v">183</span>
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
          M0 through M5 are implemented and tested: the signed offset and its v4 accounting,
          both variance estimators, depth and open-loop κ, the leaky variance-ratio controller,
          the Route B divergence check, the reserve and its graceful degradation, and a
          validated deploy path.
        </p>

        <div className="callout">
          <span className="label">Not production ready</span>
          <p>
            This is research code. The M6 replay simulator does not exist yet, so θ, K, and the
            controller targets are documented placeholders rather than calibrated values, and
            the self-funding claim is unproven on real flow. The worst-case gas path is over
            its own budget. The contract has never been deployed to any network.
          </p>
        </div>
      </section>

      <section>
        <h2>What the audit found</h2>
        <p>
          Three independent audit passes ran over the contract. Every finding below was
          reproduced with a failing test first, then fixed, then kept as a regression.
        </p>
        <table className="tbl">
          <thead>
            <tr>
              <th>Finding</th>
              <th>Severity</th>
              <th>State</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td>
                Entire reserve stealable in one transaction — the offset was sized from the
                requested amount, which a price limit decouples from what executes
              </td>
              <td><span className="pill warn">Critical</span></td>
              <td><span className="pill ok">Fixed</span></td>
            </tr>
            <tr>
              <td>
                Large honest swaps bricked the swap path — reserve scaling cannot bound the
                payout, because the reserve level cancels algebraically
              </td>
              <td><span className="pill warn">Critical</span></td>
              <td><span className="pill ok">Fixed</span></td>
            </tr>
            <tr>
              <td>κ inflatable 2.16× by liquidity added and removed within the checkpoint block</td>
              <td><span className="pill warn">High</span></td>
              <td><span className="pill ok">Fixed</span></td>
            </tr>
            <tr>
              <td>Reserves had no withdrawal path and were permanently stranded</td>
              <td><span className="pill warn">High</span></td>
              <td><span className="pill ok">Fixed</span></td>
            </tr>
            <tr>
              <td>
                The Route B guard failed <em>open</em> under alternating flow — exactly the
                wash trader it exists to catch
              </td>
              <td><span className="pill">Medium</span></td>
              <td><span className="pill ok">Fixed</span></td>
            </tr>
            <tr>
              <td>
                The belief could never form: one extra division by the fixed-point scale
                truncated every update to zero
              </td>
              <td><span className="pill warn">Critical</span></td>
              <td><span className="pill ok">Fixed</span></td>
            </tr>
          </tbody>
        </table>
        <p>
          That last one is the instructive failure. Two audit passes measured the symptom — the
          belief never moved, the integration tests had to set κ by hand — and both concluded
          the parameters needed re-deriving. It was not the parameters. No parameter choice
          could have fixed it, because the division discards the result&rsquo;s entire scale
          regardless of magnitude. It took dimensional analysis of the Q64.64 chain to find.
        </p>
      </section>

      <section>
        <h2>Prior art</h2>
        <p>
          <a href="https://arxiv.org/abs/2310.09413">ZeroSwap</a> and{" "}
          <a href="https://arxiv.org/abs/2406.13794">Adaptive Curves</a> share the oracle-free
          goal and the motivation, and Adaptive Curves has a v4 hook — so VANE claims neither
          &ldquo;first oracle-free adaptive AMM&rdquo; nor &ldquo;first adaptive v4
          hook&rdquo;. Both are Glosten-Milgrom; Kyle appears in each only as a bibliography
          entry, and neither derives an optimal depth or matches price impact. Adaptive Curves
          reshapes the bonding curve and depends on an off-chain ML co-processor.
        </p>
        <p>What VANE claims is narrower and specific:</p>
        <ul>
          <li>
            Matching Kyle&rsquo;s λ by closing the gap between pool depth and{" "}
            <code>D* = 4U/σ</code>
          </li>
          <li>
            Settling through a signed offset that moves buyers and sellers in opposite
            directions, rather than reshaping the curve
          </li>
          <li>
            Computed entirely on chain — with no oracle <em>and no co-processor</em>
          </li>
        </ul>
      </section>

      <footer className="wrap">
        <p>
          <a href={REPO}>Source on GitHub</a> · MIT licensed · Research code, not audited for
          production use.
        </p>
      </footer>
    </main>
  );
}
