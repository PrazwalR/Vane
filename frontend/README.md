# frontend

The project site: a single static page built with Next.js, plus one client component that
reads the deployed hook from Sepolia in the visitor's browser.

```
pnpm install
pnpm dev        # http://localhost:3000
pnpm build      # static export of the page
```

## Where the numbers come from

Nothing on the page is typed by hand.

- `generated/deployments.json` is copied from `deployments.json` at the repository root by
  `scripts/sync-deployments.mjs` before every build. The copy is committed, so a deploy that
  uploads only this directory still has it.
- `generated/status.json` is written by `scripts/collect-status.sh` at the repository root
  from the toolchain: test counts, coverage, runtime size, slither findings and the
  worst-case gas figure. CI fails if the committed copy drifts from what the toolchain
  reports.
- `app/LiveState.tsx` reads the belief, the gain, both reserves and the pool's last rolled
  block straight from the hook every fifteen seconds, as one JSON-RPC batch to a public
  Sepolia endpoint. It needs an endpoint that accepts a six-call batch and sends permissive
  CORS headers; publicnode and 1rpc do, and the others tried do not.
- The simulator table in `app/page.tsx` is the one hand-copied block. Its comment names the
  commit and the command that reproduces it.

## Notes

- Values are fixed point. The belief and kappa are Q64.64; variance and the EWMA decays are
  Q32.32. Divide by `2^64` or `2^32` respectively before display.
- A variance ratio of zero means "no signal", not mean reversion. The controller declines
  to act on it, and the UI should say so rather than render `0.000`.
- The page shows a warning while the deployed hook predates the settlement rework. It
  decides that from the deployment record, by whether the hook's address carries the
  `BEFORE_SWAP` permission bit, so it cannot claim a fix the deployed bytecode lacks.
