# VANE replay simulator

Executes the compiled hook inside `revm` and drives it with Kyle-model order flow. Nothing
about the mechanism is reimplemented here — every number reported comes out of the same
bytecode that would be deployed. Two implementations of the same arithmetic is the one
thing a simulator must not introduce, because the divergence is silent.

## Layout

Pool setup happens in Solidity (`test/sim/SimStateDump.t.sol`) and is dumped to disk with
`vm.dumpState`. Deploying the v4 stack, mining a hook address, initialising pools and
seeding liquidity is delicate, and that path is already covered by the rest of the suite.
Rust loads the dump and runs only the replay loop.

Both a VANE pool and a plain control pool are built on identical liquidity. Noise flow is
exogenous, so both see the same sequence; arbitrage is endogenous, so each pool gets the
arbitrage its own quote invites.

## Running

```
forge test --match-path test/sim/SimStateDump.t.sol    # writes sim/state/
cd sim && cargo build --release
./target/release/vane-sim --blocks 400 --trace 80
```

Pool shape comes from the environment (`SIM_LIQUIDITY`, `SIM_FEE`, `SIM_SPACING`,
`SIM_FLOW_UNIT`, `SIM_RANGE`), because changing it means re-dumping. Flow comes from
command-line arguments (`--sigma`, `--noise-rate`, `--noise-size`, `--momentum`), because
it does not. `--json` emits one line per run for sweeps; `./sweep.sh` and `./scan_depth.sh`
are the two sweeps whose results are written up in `SIMULATOR-FINDINGS.md`.

## What it measures

Arbitrageur profit marked at the fundamental, which is exactly LVR; the variance ratio of
each pool's tick series; and the hook's reserve trajectory, which is the self-funding
question.
