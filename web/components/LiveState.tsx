import { getDeployment, readPool, x64ToBps } from "@/lib/chain";

function explorer(chainId: number, path: string) {
  const base: Record<number, string> = {
    1: "https://etherscan.io",
    11155111: "https://sepolia.etherscan.io",
    8453: "https://basescan.org",
    84532: "https://sepolia.basescan.org",
    130: "https://uniscan.xyz",
    1301: "https://sepolia.uniscan.xyz",
  };
  return `${base[chainId] ?? "https://etherscan.io"}${path}`;
}

export default async function LiveState() {
  const deployment = getDeployment();

  if (!deployment) {
    return (
      <section>
        <h2>Live state</h2>
        <div className="callout">
          <span className="label">Not deployed</span>
          <p>
            No deployment is configured, so there is nothing to read. This section shows
            live chain state when one exists rather than placeholder numbers.
          </p>
        </div>
      </section>
    );
  }

  let snapshot;
  try {
    snapshot = await readPool(deployment);
  } catch {
    return (
      <section>
        <h2>Live state</h2>
        <div className="callout">
          <span className="label">Unreachable</span>
          <p>
            The hook is deployed at{" "}
            <a href={explorer(deployment.chain.id, `/address/${deployment.hook}`)}>
              {deployment.hook.slice(0, 10)}…{deployment.hook.slice(-8)}
            </a>{" "}
            but the RPC did not respond. No values are shown rather than stale ones.
          </p>
        </div>
      </section>
    );
  }

  const beliefBps = x64ToBps(snapshot.belief);
  const vr = snapshot.varianceRatio;

  return (
    <section>
      <h2>Live state</h2>
      <p>
        Read directly from the hook on {deployment.chain.name}. Every figure is an{" "}
        <code>eth_call</code> against the deployed contract — there is no indexer, no cache
        and no backend between this page and the chain.
      </p>

      <div className="grid">
        <div className="cell">
          <span className="k">Belief δ</span>
          <span className="v">{beliefBps.toFixed(4)} bps</span>
        </div>
        <div className="cell">
          <span className="k">Gain κ</span>
          <span className="v">{snapshot.kappa.toString()}</span>
        </div>
        <div className="cell">
          <span className="k">Variance ratio</span>
          <span className="v">{vr === null ? "no signal" : vr.toFixed(3)}</span>
        </div>
        <div className="cell">
          <span className="k">Last sampled block</span>
          <span className="v">{snapshot.lastBlock.toLocaleString()}</span>
        </div>
      </div>

      <p style={{ fontSize: 14, color: "var(--text-muted)" }}>
        Hook{" "}
        <a href={explorer(deployment.chain.id, `/address/${deployment.hook}`)}>
          {deployment.hook}
        </a>
        . A variance ratio of &ldquo;no signal&rdquo; means the per-block variance is still
        zero, which is not the same as mean reversion — the controller correctly declines to
        act on it.
      </p>
    </section>
  );
}
