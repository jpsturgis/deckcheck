// ─────────────────────────────────────────────────────────────────────────────
// resolve() — the functional-equivalence pipeline (spec §4).
//
// Two physical cards are interchangeable "copies" iff they share a full gameplay
// profile. Neither data source links reprints, so equivalence is a DERIVED
// attribute hash: resolve(card) → equivalence_key.
//
// This is the single authority that produces equivalence_key. It runs HERE, at
// prep time, stamping every snapshot row. The phone never hashes — at intake and
// at decklist/search time it resolves a card to its snapshot row and reads the
// precomputed key (spec §2, §6). Keeping one implementation is what guarantees a
// decklist target and the inventory land in the same group (spec §4.3).
//
// Validated by the throwaway logic prototype on branch `prototype/equivalence-resolve`
// (issue #5). The algorithm below is kept byte-for-byte identical to what was
// validated there — changing it changes every key, so any change MUST bump
// NORM_VERSION and trigger a snapshot rebuild + inventory re-resolve (spec §4.3).
// ─────────────────────────────────────────────────────────────────────────────

import { createHash } from "node:crypto";

/** Bump when the normalization pipeline changes (spec §4.3). */
export const NORM_VERSION = "v1";

/** The profile-relevant subset of a card that resolve() reads. */
export interface ResolvableCard {
  name: string;
  supertype: "Pokémon" | "Trainer" | "Energy";
  subtypes?: string[];
  hp?: string | null;
  types?: string[];
  evolvesFrom?: string | null;
  attacks?: Attack[];
  abilities?: Ability[];
  weaknesses?: TypeValue[];
  resistances?: TypeValue[];
  retreatCost?: string[];
  convertedRetreatCost?: number;
  rules?: string[];
  flavorText?: string | null; // §4.2: dropped before hashing — NEVER part of the key
}

export interface Attack {
  name: string;
  cost?: string[];
  convertedEnergyCost?: number;
  damage?: string | null;
  text?: string | null;
}
export interface Ability {
  name: string;
  text?: string | null;
  type?: string;
}
export interface TypeValue {
  type: string;
  value: string;
}

// Energy name → symbol token (§4.2 "canonicalize energy symbols to tokens").
const ENERGY_TOKEN: Record<string, string> = {
  grass: "{G}",
  fire: "{R}",
  water: "{W}",
  lightning: "{L}",
  psychic: "{P}",
  fighting: "{F}",
  darkness: "{D}",
  metal: "{M}",
  fairy: "{Y}",
  dragon: "{N}",
  colorless: "{C}",
};

/**
 * §4.2 text normalization: lowercase · collapse whitespace · bracketed energy
 * letters → tokens · strip leading/trailing punctuation. Then EXACT match on the
 * normalized string (not fuzzy). Consequence (spec §4.2): an errata that changes
 * wording SPLITS equivalence unless it normalizes to the same string.
 */
export function normalizeText(s?: string | null): string {
  if (!s) return "";
  let t = s.toLowerCase();
  t = t.replace(/\[([a-z])\]/g, "{$1}"); // [R] → {r}-style inline energy tokens
  t = t.replace(/\s+/g, " ").trim(); // collapse whitespace
  t = t.replace(/^[\p{P}\s]+|[\p{P}\s]+$/gu, ""); // strip leading/trailing punctuation
  return t;
}

/** Energy-cost multiset → sorted array of tokens (order-independent, §4.1). */
export function canonicalizeCost(cost?: string[]): string[] {
  return (cost ?? [])
    .map((c) => ENERGY_TOKEN[c.toLowerCase()] ?? `{${c.toLowerCase()}}`)
    .sort();
}

function normDamage(d?: string | null): string {
  return normalizeText(d).replace(/\s+/g, "");
}

const BASIC_ENERGY_TYPES = [
  "Grass", "Fire", "Water", "Lightning", "Psychic", "Fighting",
  "Darkness", "Metal", "Fairy", "Dragon", "Colorless",
];

/**
 * §4.1 basic Energy is type-only. The pokemontcg.io dump ships basic energy with
 * an empty `types` array — the type lives only in the name ("Fire Energy",
 * "Basic Water Energy") — so derive it from the name when `types` is absent.
 * (§4.5: basic energy is never tracked/inventoried, so this only affects how it
 * groups in catalog search, not any owned-copy math.)
 */
function basicEnergyType(card: ResolvableCard): string | null {
  const fromTypes = (card.types ?? [])[0];
  if (fromTypes) return fromTypes;
  for (const ty of BASIC_ENERGY_TYPES) {
    if (new RegExp(`\\b${ty}\\b`, "i").test(card.name)) return ty;
  }
  return null;
}

type Profile = Record<string, unknown>;

/** Canonical, per-supertype gameplay profile (spec §4.1). */
export function buildProfile(card: ResolvableCard): Profile {
  const subtypes = [...(card.subtypes ?? [])].sort();

  switch (card.supertype) {
    case "Pokémon":
      return {
        supertype: "pokemon",
        name: normalizeText(card.name),
        hp: card.hp ?? null,
        types: [...(card.types ?? [])].sort(),
        subtypes,
        evolvesFrom: normalizeText(card.evolvesFrom),
        // attacks kept in card order (a reprint preserves order); each cost sorted.
        attacks: (card.attacks ?? []).map((a) => ({
          name: normalizeText(a.name),
          cost: canonicalizeCost(a.cost),
          damage: normDamage(a.damage),
          text: normalizeText(a.text),
        })),
        abilities: (card.abilities ?? []).map((ab) => ({
          name: normalizeText(ab.name),
          text: normalizeText(ab.text),
        })),
        weaknesses: sortTV(card.weaknesses),
        resistances: sortTV(card.resistances),
        retreat: card.convertedRetreatCost ?? (card.retreatCost?.length ?? 0),
        rules: (card.rules ?? []).map(normalizeText),
      };

    case "Trainer":
      // §4.1: the text IS the identity; subtype MUST be in the key so a Tool/Item
      // name clash or ACE-SPEC-vs-non never collapses.
      return {
        supertype: "trainer",
        name: normalizeText(card.name),
        subtypes,
        rules: (card.rules ?? []).map(normalizeText),
      };

    case "Energy": {
      // §4.1: Special Energy → name + effect text. Basic Energy → type-only.
      // (§4.5 basic energy isn't tracked at all, so basic grouping is effectively
      // moot — modeled here only so the branch is total.)
      const isBasic = subtypes.includes("Basic");
      return {
        supertype: "energy",
        basic: isBasic,
        name: isBasic ? null : normalizeText(card.name),
        basicType: isBasic ? basicEnergyType(card) : null,
        rules: isBasic ? [] : (card.rules ?? []).map(normalizeText),
      };
    }
  }
}

function sortTV(tv?: TypeValue[]): TypeValue[] {
  return [...(tv ?? [])]
    .map((x) => ({ type: x.type, value: x.value }))
    .sort((a, b) => (a.type + a.value).localeCompare(b.type + b.value));
}

/** Deterministic serialization: recursively sort object keys, keep array order. */
function canonicalStringify(value: unknown): string {
  if (Array.isArray(value)) {
    return `[${value.map(canonicalStringify).join(",")}]`;
  }
  if (value && typeof value === "object") {
    const keys = Object.keys(value as object).sort();
    return `{${keys
      .map((k) => `${JSON.stringify(k)}:${canonicalStringify((value as Record<string, unknown>)[k])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value ?? null);
}

export interface ResolveResult {
  equivalence_key: string; // truncated sha256 (~16 hex, spec §4.3)
  norm_version: string;
}

/** equivalence_key = truncated sha256 of the canonical per-supertype profile. */
export function resolve(card: ResolvableCard): ResolveResult {
  const serialized = canonicalStringify(buildProfile(card));
  const equivalence_key = createHash("sha256")
    .update(serialized)
    .digest("hex")
    .slice(0, 16);
  return { equivalence_key, norm_version: NORM_VERSION };
}
