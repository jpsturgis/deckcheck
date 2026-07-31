// Shapes for the TCGdex REST API (https://api.tcgdex.net/v2/en, source: the
// MIT-licensed tcgdex/cards-database) and the trimmed rows we write into the
// bundled catalog. TCGdex is the v2 default source (spec v2 §3.3); its field
// names differ from v1's pokemontcg.io dump, so `tcgdex.ts` maps them onto the
// provider-agnostic `ResolvableCard` shape that `resolve()` (§4) reads.

import type { ResolvableCard, Attack, Ability, TypeValue } from "./resolve.js";

/** A set in `/v2/en/sets` (brief) — the id is all we need from the list call. */
export interface TcgdexSetBrief {
  id: string;
  name: string;
  cardCount?: { total?: number; official?: number };
}

/** A set in `/v2/en/sets/{id}` (detail): metadata + the brief card list. */
export interface TcgdexSetDetail {
  id: string;
  name: string;
  serie?: { id: string; name: string };
  releaseDate?: string;
  legal?: { standard?: boolean; expanded?: boolean };
  cardCount?: { total?: number; official?: number };
  abbreviation?: { official?: string; localized?: string };
  cards?: TcgdexCardBrief[];
}

/** A card as it appears inside a set detail's `cards[]` — identity only. */
export interface TcgdexCardBrief {
  id: string; // e.g. "sv03-125"
  localId: string; // collector number as printed, e.g. "125" or "001" or "SV107"
  name: string;
  image?: string;
}

/** A card in `/v2/en/cards/{id}` (full) — the gameplay fields resolve() needs. */
export interface TcgdexCardFull {
  id: string;
  localId: string;
  name: string;
  category?: "Pokemon" | "Trainer" | "Energy";
  image?: string;
  rarity?: string;
  regulationMark?: string; // D/E/F/G/H — legality overlay (§4.4)
  legal?: { standard?: boolean; expanded?: boolean };

  // Pokémon
  hp?: number;
  types?: string[];
  stage?: string; // Basic / Stage1 / Stage2 / …
  suffix?: string; // ex / V / VMAX / VSTAR / … (kept in the subtype key)
  evolveFrom?: string;
  attacks?: TcgdexAttack[];
  abilities?: TcgdexAbility[];
  weaknesses?: TypeValue[];
  resistances?: TypeValue[];
  retreat?: number;

  // Trainer / Energy — the text IS the identity (§4.1)
  trainerType?: string; // Item / Supporter / Stadium / Tool / …
  energyType?: string; // Basic / Special
  effect?: string; // trainer/energy card text
}

export interface TcgdexAttack {
  name?: string;
  cost?: string[]; // energy type names, e.g. ["Fire","Fire"]
  damage?: number | string | null;
  effect?: string | null;
}
export interface TcgdexAbility {
  type?: string;
  name?: string;
  effect?: string | null;
}

// Re-export for convenience so the mapper can import everything from types.
export type { ResolvableCard, Attack, Ability, TypeValue };

/** One row of the catalog `sets` table. */
export interface CatalogSet {
  id: string; // canonical set code (§3.4), e.g. "sv3"
  source_id: string; // the TCGdex set id, e.g. "sv03" (traceability)
  name: string;
  ptcgo_code: string | null; // TCG Live code (TCGdex `abbreviation.official`)
  printed_total: number | null; // the "/191" set-pinning fallback (§6)
  total: number | null;
  standard_legal: 0 | 1;
  expanded_legal: 0 | 1;
  release_date: string | null;
}

/** One row of the catalog `cards` table. */
export interface CatalogCard {
  card_id: string; // canonical "<set>-<number>" — the Sheet's stable row key (§3.4, §5.1)
  source_card_id: string; // the TCGdex card id, e.g. "sv03-125" (drift traceability §3.4)
  set_id: string; // canonical set code
  number: string; // collector number, no leading zeros when numeric (§3.2)
  name: string;
  supertype: string;
  subtypes: string; // JSON array
  equivalence_key: string; // precomputed here (§4)
  norm_version: string;
  source_tag: string; // e.g. "tcgdex" — makes cross-source key drift detectable (§3.4)
  regulation_mark: string | null;
  standard_legal: 0 | 1; // per-printing legality overlay (§4.4)
  expanded_legal: 0 | 1;
  image_small: string | null;
  image_large: string | null;
  attributes: string; // JSON blob of display fields (attacks, abilities, rules, …)
}
