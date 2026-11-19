"use client";

import { useEffect, useState } from "react";

// Read straight from a public Sepolia endpoint in the browser, so every figure here is a
// live read rather than a build-time snapshot. No client library: six eth_calls in one
// JSON-RPC batch, decoded by hand, with selectors taken from the contract's ABI.
// Both answer a six-call batch with permissive CORS. Checked against the alternatives:
// rpc.sepolia.org no longer serves JSON, and drpc, Tatum and Tenderly either cap free
// batches below six calls or send no CORS headers, so a browser cannot use them here.
const RPCS = ["https://ethereum-sepolia-rpc.publicnode.com", "https://1rpc.io/sepolia"];

const SEL = {
  beliefOf: "0xdafe987f", // beliefOf(bytes32) -> int256, Q64.64
  kappaOf: "0x5852e44e", // kappaOf(bytes32) -> uint256, Q64.64 per flow unit
  reserveOf: "0x9fa77b20", // reserveOf(address) -> uint256
  poolState: "0xe0b01bac", // poolState(bytes32) -> (int24,uint32,uint64,uint64,int64,bool,bool)
};

const REFRESH_MS = 15_000;
const TWO_64 = 2 ** 64;

type Props = {
  hook: string;
  poolId: string;
  token0: string;
  token1: string;
  flowUnit: string;
};

type Live = {
  head: number;
  belief: bigint;
  kappa: bigint;
  reserve0: bigint;
  reserve1: bigint;
  lastBlock: number;
  saturated: boolean;
  flowUnmeasurable: boolean;
};

const word = (hex: string) => hex.replace(/^0x/, "").toLowerCase().padStart(64, "0");

function words(result: string): string[] {
  const body = result.replace(/^0x/, "");
  const out: string[] = [];
  for (let i = 0; i < body.length; i += 64) out.push(body.slice(i, i + 64));
  return out;
}

const uint = (w: string) => BigInt("0x" + w);
const int = (w: string) => BigInt.asIntN(256, BigInt("0x" + w));

async function readOnce(rpc: string, p: Props): Promise<Live> {
  const call = (id: number, data: string) => ({
    jsonrpc: "2.0",
    id,
    method: "eth_call",
    params: [{ to: p.hook, data }, "latest"],
  });
  const id = word(p.poolId);
  const batch = [
    { jsonrpc: "2.0", id: 0, method: "eth_blockNumber", params: [] },
    call(1, SEL.beliefOf + id),
    call(2, SEL.kappaOf + id),
    call(3, SEL.reserveOf + word(p.token0)),
    call(4, SEL.reserveOf + word(p.token1)),
    call(5, SEL.poolState + id),
  ];

  const res = await fetch(rpc, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(batch),
    cache: "no-store",
  });
  if (!res.ok) throw new Error(`${rpc}: HTTP ${res.status}`);
  const body = (await res.json()) as { id: number; result?: string; error?: unknown }[];
  if (!Array.isArray(body)) throw new Error(`${rpc}: batch not supported`);

  const byId = new Map(body.map((r) => [r.id, r]));
  const get = (i: number) => {
    const r = byId.get(i);
    if (!r || r.error || typeof r.result !== "string" || r.result === "0x") {
      throw new Error(`${rpc}: call ${i} failed`);
    }
    return r.result;
  };

  const state = words(get(5));
  return {
    head: Number(BigInt(get(0))),
    belief: int(words(get(1))[0]),
    kappa: uint(words(get(2))[0]),
    reserve0: uint(words(get(3))[0]),
    reserve1: uint(words(get(4))[0]),
    lastBlock: Number(uint(state[1])),
    saturated: uint(state[5]) !== BigInt(0),
    flowUnmeasurable: uint(state[6]) !== BigInt(0),
  };
}

async function read(p: Props): Promise<Live> {
  let last: unknown;
  for (const rpc of RPCS) {
    try {
      return await readOnce(rpc, p);
    } catch (e) {
      last = e;
    }
  }
  throw last;
}

/** The belief is a log-price offset in Q64.64; one basis point is 1e-4. */
function beliefBp(b: bigint): string {
  const bp = (Number(b) / TWO_64) * 1e4;
  if (bp === 0) return "0";
  const s = Math.abs(bp) < 0.01 ? bp.toExponential(2) : bp.toFixed(4);
  return (bp > 0 ? "+" : "") + s;
}

/**
 * kappa is Q64.64 belief per flow unit. Shown as how far one ether of net flow moves the
 * belief, which is the only reading of it a person can use.
 */
function gainPerEther(k: bigint, flowUnit: string): string {
  if (k === BigInt(0)) return "0";
  const perUnit = Number(k) / TWO_64;
  const unitsPerEther = 1e18 / Number(flowUnit);
  const bp = perUnit * unitsPerEther * 1e4;
  return `${bp < 0.01 ? bp.toExponential(2) : bp.toFixed(3)} bp / ETH`;
}

function tokens(x: bigint): string {
  const whole = Number(x / BigInt(1e12)) / 1e6;
  return whole.toLocaleString(undefined, { maximumFractionDigits: 2 });
}

export default function LiveState(props: Props) {
  const { hook, poolId, token0, token1, flowUnit } = props;
  const [live, setLive] = useState<Live | null>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let stop = false;
    const tick = async () => {
      try {
        const l = await read({ hook, poolId, token0, token1, flowUnit });
        if (!stop) {
          setLive(l);
          setFailed(false);
        }
      } catch {
        if (!stop) setFailed(true);
      }
    };
    tick();
    const t = setInterval(tick, REFRESH_MS);
    return () => {
      stop = true;
      clearInterval(t);
    };
  }, [hook, poolId, token0, token1, flowUnit]);

  const v = (s: string | null) =>
    s === null ? <span className="v muted">—</span> : <span className="v">{s}</span>;

  return (
    <>
      <div className="grid">
        <div className="cell">
          <span className="k">Belief δ</span>
          {v(live ? `${beliefBp(live.belief)} bp` : null)}
        </div>
        <div className="cell">
          <span className="k">Gain κ</span>
          {v(live ? gainPerEther(live.kappa, flowUnit) : null)}
        </div>
        <div className="cell">
          <span className="k">Reserve, token0</span>
          {v(live ? tokens(live.reserve0) : null)}
        </div>
        <div className="cell">
          <span className="k">Reserve, token1</span>
          {v(live ? tokens(live.reserve1) : null)}
        </div>
      </div>
      <p className="addr" aria-live="polite">
        {failed && !live
          ? "Could not reach a public Sepolia endpoint from this browser. The addresses below are still correct."
          : live
            ? `Read at block ${live.head.toLocaleString()} · pool last rolled at ${live.lastBlock.toLocaleString()}${
                live.saturated ? " · estimator saturated, gain withheld" : ""
              }${live.flowUnmeasurable ? " · flow unit too large to measure flow" : ""}${
                live.kappa === BigInt(0)
                  ? " · gain is zero: the price is not trending, so there is nothing to correct"
                  : ""
              }`
            : "Reading the deployed contract…"}
      </p>
    </>
  );
}
