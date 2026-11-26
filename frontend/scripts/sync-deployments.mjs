// deployments.json lives at the repository root because the Foundry scripts write it.
// Next refuses to import from outside its own project root, so copy it in before a
// build rather than duplicating it by hand, which would drift the moment a redeploy
// changes an address.
import { copyFileSync, existsSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const source = join(here, "..", "..", "deployments.json");
const targetDir = join(here, "..", "generated");
const target = join(targetDir, "deployments.json");

// The generated copy is committed, so a build that cannot see the repository root --
// a CLI deploy from this directory, for instance, which uploads only this directory --
// still has the data it needs. Refreshing is best-effort; missing source is not fatal.
if (!existsSync(source)) {
  if (existsSync(target)) {
    console.log("sync-deployments: repo root not visible, using the committed copy");
    process.exit(0);
  }
  console.error(`sync-deployments: ${source} not found and no committed copy exists`);
  process.exit(1);
}

mkdirSync(targetDir, { recursive: true });
copyFileSync(source, target);
console.log("sync-deployments: copied deployments.json");
