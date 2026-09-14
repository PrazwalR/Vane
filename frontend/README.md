# frontend

Placeholder. The site design is still being worked out, so this directory is
intentionally empty of implementation.

## What already exists elsewhere

- `deployments.json` at the repo root records the deployed hook, pool id and tokens
  per chain. That is the source of truth for anything the UI needs to address.
- The hook exposes a full read surface for a dashboard, all `external view`:
  `config()`, `poolState()`, `poolStateAux()`, `flowCovOf()`, `kappaOf()`,
  `beliefOf()`, `reserveOf()`, `targetFor()`, `flowUnitOf()`, `allowlisted()`.
- A working viem read layer was built and verified against a live chain. It was
  removed along with the first site rather than left half-wired; recover it from
  git history at `web/lib/chain.ts` if useful.

## Notes for whatever gets built here

- Values are fixed point. The belief and kappa are Q64.64; variance and the EWMA
  decays are Q32.32. Divide by `2^64` or `2^32` respectively before display.
- A variance ratio of zero means "no signal", not mean reversion. The controller
  declines to act on it, and the UI should say so rather than render `0.000`.
- Nothing about a deployment should be hardcoded. Read it from `deployments.json`
  or from environment variables, the same rule the contract applies to its own
  parameters.
