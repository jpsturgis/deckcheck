// ─────────────────────────────────────────────────────────────────────────────
// Author-side tool (spec v2 §3.4). (Re)generates the checked-in set-code map:
// fetches the TCGdex set list, assigns each a canonical code via the documented
// derivation (deriveCanonicalCode — collapse zero-padding, `sv03` → `sv3`), and
// merges the result over any EXISTING committed map so hand-authored overrides
// survive a refresh. New sets appear with a derived code for a human to confirm.
//
//   npm run gen-set-code-map                 # merge into set-code-map.json
//   npm run gen-set-code-map -- --check      # exit non-zero if the map is stale
//   npm run gen-set-code-map -- --limit 3    # only the first n sets (smoke)
//
// This tool talks to TCGdex to enumerate set ids; the BUILD never derives at
// runtime — it reads only the committed map, so the canonical id of any set is a
// reviewed, version-controlled decision.
// ─────────────────────────────────────────────────────────────────────────────

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { deriveCanonicalCode, SET_CODE_MAP_PATH, type SetCodeMap } from "./set-code.js";
import type { TcgdexSetBrief } from "./types.js";

const API = "https://api.tcgdex.net/v2/en";

interface Args {
  check: boolean;
  limit?: number;
  out: string;
}

function parseArgs(argv: string[]): Args {
  const args: Args = { check: false, out: SET_CODE_MAP_PATH };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--check") args.check = true;
    else if (a === "--limit") args.limit = Number(argv[++i]);
    else if (a === "--out") args.out = argv[++i];
  }
  return args;
}

/** Sort keys so the committed JSON diff is stable across runs. */
function stableMapJSON(map: SetCodeMap): string {
  const sorted: SetCodeMap = {};
  for (const k of Object.keys(map).sort()) sorted[k] = map[k];
  return JSON.stringify(sorted, null, 2) + "\n";
}

function reportCollisions(map: SetCodeMap, log: (m: string) => void): void {
  const byCode = new Map<string, string[]>();
  for (const [src, code] of Object.entries(map)) {
    const arr = byCode.get(code) ?? [];
    arr.push(src);
    byCode.set(code, arr);
  }
  const collisions = [...byCode.entries()].filter(([, srcs]) => srcs.length > 1);
  if (collisions.length) {
    log(`⚠ ${collisions.length} canonical code(s) map from >1 TCGdex set — resolve by hand:`);
    for (const [code, srcs] of collisions) log(`    ${code}  ←  ${srcs.join(", ")}`);
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const log = (m: string) => console.log(m);

  const existing: SetCodeMap = existsSync(args.out)
    ? (JSON.parse(readFileSync(args.out, "utf8")) as SetCodeMap)
    : {};

  log(`Fetching set list from TCGdex…`);
  let setList = (await (await fetch(`${API}/sets`)).json()) as TcgdexSetBrief[];
  if (args.limit) setList = setList.slice(0, args.limit);

  const merged: SetCodeMap = { ...existing };
  let added = 0;
  for (const s of setList) {
    if (!(s.id in merged)) {
      merged[s.id] = deriveCanonicalCode(s.id);
      added++;
    }
  }

  const nextJSON = stableMapJSON(merged);
  const prevJSON = existsSync(args.out) ? readFileSync(args.out, "utf8") : "";
  const changed = nextJSON !== prevJSON;

  reportCollisions(merged, log);

  if (args.check) {
    if (changed) {
      log(`✗ set-code-map.json is stale (${added} new set(s)). Run \`npm run gen-set-code-map\`.`);
      process.exit(1);
    }
    log(`✓ set-code-map.json is up to date (${Object.keys(merged).length} sets).`);
    return;
  }

  writeFileSync(args.out, nextJSON);
  log(`✓ ${args.out}  (${Object.keys(merged).length} sets, ${added} newly derived)`);
  if (added) log(`  Review the ${added} newly-derived code(s) before committing (§3.4).`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
