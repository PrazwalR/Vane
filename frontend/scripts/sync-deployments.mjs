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

if (!existsSync(source)) {
  console.error(`sync-deployments: ${source} not found`);
  process.exit(1);
}

mkdirSync(targetDir, { recursive: true });
copyFileSync(source, target);
console.log("sync-deployments: copied deployments.json");
