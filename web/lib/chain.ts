import { createPublicClient, http, type Address, type Chain } from "viem";
import { mainnet, sepolia, base, baseSepolia, unichain, unichainSepolia } from "viem/chains";

import abi from "./vaneHookAbi.json";

export const vaneHookAbi = abi;

const CHAINS: Record<number, Chain> = {
  [mainnet.id]: mainnet,
  [sepolia.id]: sepolia,
  [base.id]: base,
  [baseSepolia.id]: baseSepolia,
  [unichain.id]: unichain,
  [unichainSepolia.id]: unichainSepolia,
};

export type Deployment = {
  chain: Chain;
  hook: Address;
  poolId: `0x${string}`;
  rpcUrl?: string;
};

/**
 * Reads the deployment from the environment. Returns null when the hook has not been
 * deployed yet, which the UI reports as such rather than inventing state to display.
 *
 * Every value is an environment variable. Nothing about a deployment is hardcoded, for
 * the same reason the contract takes its parameters from a validated config struct.
 */
export function getDeployment(): Deployment | null {
  const chainId = Number(process.env.NEXT_PUBLIC_CHAIN_ID);
  const hook = process.env.NEXT_PUBLIC_VANE_HOOK as Address | undefined;
  const poolId = process.env.NEXT_PUBLIC_POOL_ID as `0x${string}` | undefined;

  if (!chainId || !hook || !poolId) return null;

  const chain = CHAINS[chainId];
  if (!chain) return null;

  if (!/^0x[0-9a-fA-F]{40}$/.test(hook)) return null;
  if (!/^0x[0-9a-fA-F]{64}$/.test(poolId)) return null;

  return { chain, hook, poolId, rpcUrl: process.env.NEXT_PUBLIC_RPC_URL };
}

export function publicClientFor(deployment: Deployment) {
  return createPublicClient({
    chain: deployment.chain,
    transport: http(deployment.rpcUrl),
  });
}

const ONE_X64 = 2n ** 64n;
const ONE_X32 = 2n ** 32n;

/** Q64.64 fixed point to a JS number. Only for display. */
export function fromX64(v: bigint): number {
  return Number((v * 1_000_000_000n) / ONE_X64) / 1_000_000_000;
}

/** Q32.32 fixed point to a JS number. Only for display. */
export function fromX32(v: bigint): number {
  return Number((v * 1_000_000n) / ONE_X32) / 1_000_000;
}

/** A Q64.64 log-price offset rendered in basis points. */
export function x64ToBps(v: bigint): number {
  const negative = v < 0n;
  const magnitude = negative ? -v : v;
  const bps = Number((magnitude * 10_000_000n) / ONE_X64) / 1000;
  return negative ? -bps : bps;
}

export type PoolSnapshot = {
  belief: bigint;
  kappa: bigint;
  varOne: bigint;
  varK: bigint;
  flowVar: bigint;
  lastBlock: number;
  checkpointBlock: number;
  varianceRatio: number | null;
};

/**
 * Reads the live estimator state for one pool. Every value comes from the chain; there
 * is no fallback or default, so a failed read surfaces as an error rather than as
 * plausible-looking numbers.
 */
export async function readPool(deployment: Deployment): Promise<PoolSnapshot> {
  const client = publicClientFor(deployment);
  const base = { address: deployment.hook, abi: vaneHookAbi } as const;

  // Parallel individual reads rather than multicall: a freshly deployed testnet does
  // not always have multicall3 at the canonical address, and four calls is cheap.
  const [belief, kappa, state, aux] = await Promise.all([
    client.readContract({ ...base, functionName: "beliefOf", args: [deployment.poolId] }),
    client.readContract({ ...base, functionName: "kappaOf", args: [deployment.poolId] }),
    client.readContract({ ...base, functionName: "poolState", args: [deployment.poolId] }),
    client.readContract({ ...base, functionName: "poolStateAux", args: [deployment.poolId] }),
  ]);

  const s = state as {
    lastBlock: number;
    varOneX32: bigint;
    flowVarX32: bigint;
    deltaX64: bigint;
  };
  const a = aux as { checkpointBlock: number; varKX32: bigint; kappaX64: bigint };

  // VR = Var(r_k) / (k * Var(r_1)). Reported as null rather than zero when there is no
  // per-block variance yet, because zero there means "no signal", not "mean reverting".
  const varianceRatio =
    s.varOneX32 > 0n ? Number(a.varKX32) / (20 * Number(s.varOneX32)) : null;

  return {
    belief: belief as bigint,
    kappa: kappa as bigint,
    varOne: s.varOneX32,
    varK: a.varKX32,
    flowVar: s.flowVarX32,
    lastBlock: Number(s.lastBlock),
    checkpointBlock: Number(a.checkpointBlock),
    varianceRatio,
  };
}
