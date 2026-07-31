// ─────────────────────────────────────────────────────────────────────────────
// Provider-independent identity (spec v2 §3.4).
//
// v1 keyed identity to a pokemontcg.io id (`ptcg:<id>`). v2 keys to a canonical
// `<set>-<number>` that is stable across sources and re-builds. The mapping from
// a source's set identifiers → our canonical set code lives in a CHECKED-IN map
// (`set-code-map.json`) that is the source of truth. `deriveCanonicalCode()` is
// the documented rule the map generator seeds from — the build itself only reads
// the committed map, and errors on any unmapped set so a new set forces a human
// to assign (or confirm) its canonical code on refresh.
// ─────────────────────────────────────────────────────────────────────────────

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
/** Repo-relative path to the committed map (tools/build-catalog/set-code-map.json). */
export const SET_CODE_MAP_PATH = join(HERE, "..", "set-code-map.json");

/**
 * The derivation the generator seeds the map from: collapse zero-padding in each
 * digit-group that follows a letter, so TCGdex's `sv03` → canonical `sv3` (the
 * worked example in §3.4). Idempotent on already-unpadded ids (`swsh3`, `base1`,
 * `swsh12pt5`). This is a SEED rule, not a runtime fallback — the committed map
 * is authoritative and human-correctable per set.
 */
export function deriveCanonicalCode(tcgdexSetId: string): string {
  return tcgdexSetId.replace(/([A-Za-z])0+(\d)/g, "$1$2");
}

/**
 * Collector-number normalization (§3.2): strip leading zeros when the localId is
 * purely numeric (`001` → `1`), otherwise keep it verbatim (promos/subsets like
 * `SV107`, `TG01`, `GG70` are already meaningful strings). Uppercased for a
 * stable card_id regardless of source casing.
 */
export function normalizeNumber(localId: string): string {
  const s = localId.trim();
  if (/^\d+$/.test(s)) return String(Number(s));
  return s.toUpperCase();
}

export type SetCodeMap = Record<string, string>;

/** Load the committed TCGdex-set-id → canonical-code map. */
export function loadSetCodeMap(path: string = SET_CODE_MAP_PATH): SetCodeMap {
  const raw = JSON.parse(readFileSync(path, "utf8")) as unknown;
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw new Error(`set-code-map.json must be a JSON object of { tcgdexSetId: canonicalCode }`);
  }
  return raw as SetCodeMap;
}

/**
 * Resolve a TCGdex set id to its canonical code via the committed map. Throws
 * (loudly, by design) when a set is missing — the caller surfaces "run
 * gen-set-code-map" so refreshes never silently invent an id.
 */
export function canonicalSetCode(tcgdexSetId: string, map: SetCodeMap): string {
  const code = map[tcgdexSetId];
  if (!code) {
    throw new Error(
      `set "${tcgdexSetId}" is not in set-code-map.json — run \`npm run gen-set-code-map\` ` +
        `to add it, then review the assigned canonical code before rebuilding (§3.4).`,
    );
  }
  return code;
}

/** Build a canonical card_id from a canonical set code + normalized number. */
export function canonicalCardId(setCode: string, normalizedNumber: string): string {
  return `${setCode}-${normalizedNumber}`;
}
