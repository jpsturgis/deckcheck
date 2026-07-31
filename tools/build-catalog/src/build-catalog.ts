// ─────────────────────────────────────────────────────────────────────────────
// The Mac-side prep step (spec v2 §3). Transforms a user-supplied TCGdex source
// into the compact, read-only SQLite catalog the app bundles — keyed on a
// source-independent canonical `<set>-<number>` id (§3.4) and precomputing
// equivalence_key + norm_version per card via the shared resolve() pipeline (§4).
//
//   npm run build                          # fetch live TCGdex → build/catalog.sqlite
//   npm run build -- --out path.sqlite     # choose the output path
//   npm run build -- --cache-dir ./cache   # persist per-card JSON so rebuilds are cheap
//   npm run build -- --limit 3             # only the first n sets (quick smoke)
//   npm run build -- --concurrency 24      # per-card fetch concurrency (default 16)
//
// Refresh = re-run this + rebuild the app (§3.2). New sets drop ~monthly; a new
// set that isn't yet in set-code-map.json errors loudly (run gen-set-code-map).
//
// SHIP THE RECIPE, NEVER THE MEAL (§3.1): the built .sqlite and any cached JSON
// are gitignored build artifacts on the USER's machine — never committed, never
// hosted. This script is instructions; the data it produces is the user's own.
// ─────────────────────────────────────────────────────────────────────────────

import { DatabaseSync } from "node:sqlite";
import { mkdirSync, rmSync } from "node:fs";
import { dirname } from "node:path";
import { fetchTcgdex, SOURCE_TAG, toResolvable, displayAttributes, imageUrl } from "./tcgdex.js";
import { resolve, NORM_VERSION } from "./resolve.js";
import { SCHEMA } from "./schema.js";
import {
  loadSetCodeMap,
  canonicalSetCode,
  canonicalCardId,
  normalizeNumber,
} from "./set-code.js";
import type { CatalogCard, CatalogSet, TcgdexCardFull, TcgdexSetDetail } from "./types.js";

interface Args {
  out: string;
  cacheDir?: string;
  concurrency?: number;
  limit?: number;
  map?: string;
}

function parseArgs(argv: string[]): Args {
  const args: Args = { out: "build/catalog.sqlite" };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--out") args.out = argv[++i];
    else if (a === "--cache-dir") args.cacheDir = argv[++i];
    else if (a === "--concurrency") args.concurrency = Number(argv[++i]);
    else if (a === "--limit") args.limit = Number(argv[++i]);
    else if (a === "--map") args.map = argv[++i];
  }
  return args;
}

const bool01 = (v?: boolean): 0 | 1 => (v ? 1 : 0);

function toCatalogSet(s: TcgdexSetDetail, code: string): CatalogSet {
  return {
    id: code,
    source_id: s.id,
    name: s.name,
    ptcgo_code: s.abbreviation?.official ?? null,
    printed_total: s.cardCount?.official ?? null,
    total: s.cardCount?.total ?? null,
    standard_legal: bool01(s.legal?.standard),
    expanded_legal: bool01(s.legal?.expanded),
    release_date: s.releaseDate ?? null,
  };
}

function toCatalogCard(c: TcgdexCardFull, setCode: string): CatalogCard | null {
  const resolvable = toResolvable(c);
  if (!resolvable) return null; // unmappable category — skipped, counted by caller
  const { equivalence_key, norm_version } = resolve(resolvable);
  const number = normalizeNumber(c.localId);
  return {
    card_id: canonicalCardId(setCode, number),
    source_card_id: c.id,
    set_id: setCode,
    number,
    name: c.name,
    supertype: resolvable.supertype,
    subtypes: JSON.stringify(resolvable.subtypes ?? []),
    equivalence_key,
    norm_version,
    source_tag: SOURCE_TAG,
    regulation_mark: c.regulationMark ?? null,
    standard_legal: bool01(c.legal?.standard),
    expanded_legal: bool01(c.legal?.expanded),
    image_small: imageUrl(c.image, "low"),
    image_large: imageUrl(c.image, "high"),
    attributes: JSON.stringify(displayAttributes(c)),
  };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const log = (m: string) => console.log(m);
  const t0 = Date.now();

  const setCodeMap = loadSetCodeMap(args.map);

  const { sets, cards } = await fetchTcgdex({
    cacheDir: args.cacheDir,
    concurrency: args.concurrency,
    limit: args.limit,
    log,
  });

  // Canonical set code per TCGdex set id (throws loudly on an unmapped set §3.4),
  // and a card-id → owning-set-code index so each card knows its canonical set.
  const codeBySourceSet = new Map<string, string>();
  for (const s of sets) codeBySourceSet.set(s.id, canonicalSetCode(s.id, setCodeMap));
  const setCodeByCardId = new Map<string, string>();
  for (const s of sets) {
    const code = codeBySourceSet.get(s.id)!;
    for (const brief of s.cards ?? []) setCodeByCardId.set(brief.id, code);
  }

  log(`Transforming ${cards.length} cards + ${sets.length} sets…`);
  const setRows = sets.map((s) => toCatalogSet(s, codeBySourceSet.get(s.id)!));

  let skipped = 0;
  let unowned = 0;
  const cardRows: CatalogCard[] = [];
  for (const c of cards) {
    const setCode = setCodeByCardId.get(c.id);
    if (!setCode) { unowned++; continue; } // card not listed under any fetched set
    const row = toCatalogCard(c, setCode);
    if (!row) { skipped++; continue; }
    cardRows.push(row);
  }

  // fresh file every build
  mkdirSync(dirname(args.out), { recursive: true });
  rmSync(args.out, { force: true });
  const db = new DatabaseSync(args.out);
  db.exec(SCHEMA);

  const insertSet = db.prepare(
    `INSERT INTO sets (id,source_id,name,ptcgo_code,printed_total,total,standard_legal,expanded_legal,release_date)
     VALUES (?,?,?,?,?,?,?,?,?)`,
  );
  const insertCard = db.prepare(
    `INSERT INTO cards (card_id,source_card_id,set_id,number,name,supertype,subtypes,equivalence_key,norm_version,
       source_tag,regulation_mark,standard_legal,expanded_legal,image_small,image_large,attributes)
     VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
  );
  const insertMeta = db.prepare(`INSERT OR REPLACE INTO meta (key,value) VALUES (?,?)`);

  db.exec("BEGIN");
  for (const s of setRows) {
    insertSet.run(s.id, s.source_id, s.name, s.ptcgo_code, s.printed_total, s.total, s.standard_legal, s.expanded_legal, s.release_date);
  }
  const seen = new Set<string>();
  let dupes = 0;
  for (const c of cardRows) {
    if (seen.has(c.card_id)) { dupes++; continue; } // guard against source repeats / collisions
    seen.add(c.card_id);
    insertCard.run(c.card_id, c.source_card_id, c.set_id, c.number, c.name, c.supertype, c.subtypes,
      c.equivalence_key, c.norm_version, c.source_tag, c.regulation_mark, c.standard_legal, c.expanded_legal,
      c.image_small, c.image_large, c.attributes);
  }

  const groups = new Set(cardRows.map((c) => c.equivalence_key)).size;
  const now = new Date().toISOString();
  for (const [k, v] of [
    ["norm_version", NORM_VERSION],
    ["source_tag", SOURCE_TAG],
    ["source", `${SOURCE_TAG}:api.tcgdex.net/v2/en`],
    ["generated_at", now],
    ["set_count", String(setRows.length)],
    ["card_count", String(seen.size)],
    ["equivalence_group_count", String(groups)],
  ] as const) {
    insertMeta.run(k, v);
  }
  db.exec("COMMIT");
  db.close();

  const multiPrint = countMultiPrintGroups(cardRows);
  log("");
  log(`✓ ${args.out}`);
  log(`  sets:               ${setRows.length}`);
  log(`  cards:              ${seen.size}${dupes ? `  (${dupes} duplicate card_id skipped)` : ""}`);
  log(`  equivalence groups: ${groups}  (${multiPrint} span >1 printing → cross-printing "copies")`);
  if (skipped) log(`  skipped:            ${skipped} cards with an unmappable category`);
  if (unowned) log(`  unowned:            ${unowned} cards not listed under any fetched set`);
  log(`  norm_version:       ${NORM_VERSION}`);
  log(`  source:             ${SOURCE_TAG}`);
  log(`  elapsed:            ${((Date.now() - t0) / 1000).toFixed(1)}s`);
}

function countMultiPrintGroups(rows: CatalogCard[]): number {
  const byKey = new Map<string, Set<string>>();
  for (const r of rows) {
    let s = byKey.get(r.equivalence_key);
    if (!s) byKey.set(r.equivalence_key, (s = new Set()));
    s.add(r.card_id);
  }
  let n = 0;
  for (const s of byKey.values()) if (s.size > 1) n++;
  return n;
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
