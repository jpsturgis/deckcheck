// ─────────────────────────────────────────────────────────────────────────────
// TCGdex source adapter (spec v2 §3.3). Pulls the card + sets data from the
// TCGdex REST API and maps its field names onto the provider-agnostic shapes the
// rest of the pipeline speaks: `ResolvableCard` for resolve() (§4) and the
// display attributes the app joins onto an inventory row (§2).
//
// TCGdex has no bulk full-card dump — the set-list and set-detail calls are brief
// (identity only), so gameplay fields require one `/cards/{id}` call per card
// (~23k). Those responses are cached under `cacheDir` so a monthly rebuild only
// fetches new/changed cards. This runs Mac-side once per build, never on-device.
// ─────────────────────────────────────────────────────────────────────────────

import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import type {
  TcgdexSetBrief,
  TcgdexSetDetail,
  TcgdexCardFull,
  ResolvableCard,
} from "./types.js";

export const SOURCE_TAG = "tcgdex";
const API = "https://api.tcgdex.net/v2/en";

export interface FetchOptions {
  /** Persistent JSON cache dir so rebuilds don't re-hit every card. */
  cacheDir?: string;
  /** Concurrency for per-card fetches. */
  concurrency?: number;
  /** Only the first n sets (quick smoke). */
  limit?: number;
  log?: (msg: string) => void;
}

export interface TcgdexData {
  sets: TcgdexSetDetail[];
  cards: TcgdexCardFull[];
}

async function mapLimit<T, R>(items: T[], limit: number, fn: (item: T, i: number) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let next = 0;
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (true) {
      const i = next++;
      if (i >= items.length) return;
      out[i] = await fn(items[i], i);
    }
  });
  await Promise.all(workers);
  return out;
}

async function getJSON<T>(url: string, tries = 4): Promise<T> {
  let lastErr: unknown;
  for (let attempt = 1; attempt <= tries; attempt++) {
    try {
      const res = await fetch(url);
      if (res.status === 404) throw new NotFound(url);
      if (!res.ok) throw new Error(`HTTP ${res.status} for ${url}`);
      return (await res.json()) as T;
    } catch (err) {
      if (err instanceof NotFound) throw err; // don't retry a real 404
      lastErr = err;
      if (attempt < tries) await new Promise((r) => setTimeout(r, 500 * attempt));
    }
  }
  throw lastErr;
}

class NotFound extends Error {}

/** Fetch a full card, backed by an on-disk JSON cache keyed by card id. */
async function getCardCached(id: string, cacheDir: string | undefined): Promise<TcgdexCardFull | null> {
  if (cacheDir) {
    const file = join(cacheDir, `${id}.json`);
    if (existsSync(file)) return JSON.parse(readFileSync(file, "utf8")) as TcgdexCardFull;
    try {
      const card = await getJSON<TcgdexCardFull>(`${API}/cards/${encodeURIComponent(id)}`);
      writeFileSync(file, JSON.stringify(card));
      return card;
    } catch (err) {
      if (err instanceof NotFound) return null;
      throw err;
    }
  }
  try {
    return await getJSON<TcgdexCardFull>(`${API}/cards/${encodeURIComponent(id)}`);
  } catch (err) {
    if (err instanceof NotFound) return null;
    throw err;
  }
}

export async function fetchTcgdex(opts: FetchOptions = {}): Promise<TcgdexData> {
  const log = opts.log ?? (() => {});
  const concurrency = opts.concurrency ?? 16;
  if (opts.cacheDir) mkdirSync(opts.cacheDir, { recursive: true });

  log(`Fetching set list…`);
  let setList = await getJSON<TcgdexSetBrief[]>(`${API}/sets`);
  if (opts.limit) setList = setList.slice(0, opts.limit);
  log(`${setList.length} sets. Fetching set details…`);

  let doneSets = 0;
  const sets = await mapLimit(setList, Math.min(concurrency, 8), async (s) => {
    const detail = await getJSON<TcgdexSetDetail>(`${API}/sets/${encodeURIComponent(s.id)}`);
    doneSets++;
    if (doneSets % 25 === 0 || doneSets === setList.length) log(`  …${doneSets}/${setList.length} sets`);
    return detail;
  });

  const cardIds = sets.flatMap((s) => (s.cards ?? []).map((c) => c.id));
  log(`${cardIds.length} cards. Fetching card details${opts.cacheDir ? " (cached)" : ""}…`);

  let doneCards = 0;
  let missing = 0;
  const fetched = await mapLimit(cardIds, concurrency, async (id) => {
    const card = await getCardCached(id, opts.cacheDir);
    doneCards++;
    if (card === null) missing++;
    if (doneCards % 500 === 0 || doneCards === cardIds.length) {
      log(`  …${doneCards}/${cardIds.length} cards${missing ? ` (${missing} missing)` : ""}`);
    }
    return card;
  });

  const cards = fetched.filter((c): c is TcgdexCardFull => c !== null);
  return { sets, cards };
}

// ── Mapping: TCGdex shapes → the provider-agnostic pipeline shapes ───────────

export type Supertype = ResolvableCard["supertype"];

/** TCGdex `category` → resolve()'s `supertype`. Returns null if unmappable. */
export function supertypeOf(category?: string): Supertype | null {
  switch (category) {
    case "Pokemon":
      return "Pokémon";
    case "Trainer":
      return "Trainer";
    case "Energy":
      return "Energy";
    default:
      return null;
  }
}

/**
 * TCGdex splits what pokemontcg.io calls `subtypes` across `stage`/`suffix`
 * (Pokémon), `trainerType` (Trainer) and `energyType` (Energy). Re-assemble them
 * into the single `subtypes` array resolve() keys on — the subtype MUST be in the
 * key so an ex-vs-non or Item-vs-Tool clash never collapses (§4.1). Energy's
 * "Basic"/"Special" here is exactly what resolve() checks for basic energy.
 */
export function subtypesOf(c: TcgdexCardFull): string[] {
  switch (c.category) {
    case "Pokemon":
      return [c.stage, c.suffix].filter((x): x is string => !!x);
    case "Trainer":
      return c.trainerType ? [c.trainerType] : [];
    case "Energy":
      return c.energyType ? [c.energyType] : [];
    default:
      return [];
  }
}

/**
 * Trainer/Energy card text is the identity (§4.1). pokemontcg.io carries it in a
 * `rules` array; TCGdex carries it in `effect`. Map it onto `rules` so both
 * sources feed resolve() the same field. Pokémon have no rules-box text in
 * TCGdex; the `suffix` subtype already discriminates ex/V/etc.
 */
export function rulesOf(c: TcgdexCardFull): string[] {
  if ((c.category === "Trainer" || c.category === "Energy") && c.effect) return [c.effect];
  return [];
}

const damageToText = (d?: number | string | null): string | null =>
  d === undefined || d === null ? null : String(d);

/** Map a TCGdex full card onto the profile-relevant `ResolvableCard`. */
export function toResolvable(c: TcgdexCardFull): ResolvableCard | null {
  const supertype = supertypeOf(c.category);
  if (!supertype) return null;
  return {
    name: c.name,
    supertype,
    subtypes: subtypesOf(c),
    hp: c.hp === undefined ? null : String(c.hp),
    types: c.types ?? [],
    evolvesFrom: c.evolveFrom ?? null,
    attacks: (c.attacks ?? []).map((a) => ({
      name: a.name ?? "",
      cost: a.cost ?? [],
      damage: damageToText(a.damage),
      text: a.effect ?? null,
    })),
    abilities: (c.abilities ?? []).map((ab) => ({
      name: ab.name ?? "",
      text: ab.effect ?? null,
    })),
    weaknesses: c.weaknesses ?? [],
    resistances: c.resistances ?? [],
    convertedRetreatCost: c.retreat ?? 0,
    rules: rulesOf(c),
  };
}

/** Display fields the app needs when it joins an inventory row to the catalog (§2). */
export function displayAttributes(c: TcgdexCardFull) {
  return {
    hp: c.hp === undefined ? null : String(c.hp),
    types: c.types ?? [],
    evolvesFrom: c.evolveFrom ?? null,
    attacks: (c.attacks ?? []).map((a) => ({
      name: a.name ?? "",
      cost: a.cost ?? [],
      damage: damageToText(a.damage),
      text: a.effect ?? null,
    })),
    abilities: (c.abilities ?? []).map((ab) => ({
      name: ab.name ?? "",
      text: ab.effect ?? null,
      type: ab.type ?? null,
    })),
    weaknesses: c.weaknesses ?? [],
    resistances: c.resistances ?? [],
    retreatCost: c.retreat ?? 0,
    rules: rulesOf(c),
    rarity: c.rarity ?? null,
  };
}

/** TCGdex image base URL → a concrete asset URL (quality + extension appended). */
export function imageUrl(base: string | undefined, quality: "low" | "high"): string | null {
  return base ? `${base}/${quality}.webp` : null;
}
