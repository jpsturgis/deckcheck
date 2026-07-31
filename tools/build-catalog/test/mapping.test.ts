// v2 mapping regressions (spec §3.3/§3.4): TCGdex field-shapes → the
// provider-agnostic pipeline shapes, canonical identity, and the set-code map
// contract. Fixtures are trimmed copies of real /v2/en/cards responses.

import { test } from "node:test";
import assert from "node:assert/strict";
import { resolve } from "../src/resolve.js";
import {
  supertypeOf,
  subtypesOf,
  rulesOf,
  toResolvable,
  imageUrl,
} from "../src/tcgdex.js";
import {
  deriveCanonicalCode,
  normalizeNumber,
  canonicalCardId,
  canonicalSetCode,
} from "../src/set-code.js";
import type { TcgdexCardFull } from "../src/types.js";

const charizard: TcgdexCardFull = {
  id: "sv03-125",
  localId: "125",
  name: "Charizard ex",
  category: "Pokemon",
  image: "https://assets.tcgdex.net/en/sv/sv03/125",
  rarity: "Double rare",
  regulationMark: "G",
  legal: { standard: false, expanded: true },
  hp: 330,
  types: ["Darkness"],
  stage: "Stage2",
  suffix: "ex",
  evolveFrom: "Charmeleon",
  attacks: [
    { cost: ["Fire", "Fire"], name: "Burning Darkness", effect: "This attack does 30 more damage for each Prize card your opponent has taken.", damage: "180+" },
  ],
  abilities: [
    { type: "Ability", name: "Infernal Reign", effect: "When you play this Pokémon from your hand to evolve 1 of your Pokémon during your turn, you may search your deck for up to 3 Basic {R} Energy cards and attach them to your Pokémon in any way you like. Then, shuffle your deck." },
  ],
  weaknesses: [{ type: "Grass", value: "×2" }],
  retreat: 2,
};

const townStore: TcgdexCardFull = {
  id: "sv03-196",
  localId: "196",
  name: "Town Store",
  category: "Trainer",
  regulationMark: "G",
  legal: { standard: false, expanded: true },
  trainerType: "Stadium",
  effect: "Once during each player's turn, that player may search their deck for a Pokémon Tool card, reveal it, and put it into their hand. Then, that player shuffles their deck.",
};

// ── category → supertype ─────────────────────────────────────────────────────

test("supertypeOf maps TCGdex categories (Pokemon → Pokémon)", () => {
  assert.equal(supertypeOf("Pokemon"), "Pokémon");
  assert.equal(supertypeOf("Trainer"), "Trainer");
  assert.equal(supertypeOf("Energy"), "Energy");
  assert.equal(supertypeOf("Nonsense"), null);
  assert.equal(supertypeOf(undefined), null);
});

// ── subtype re-assembly (§4.1: subtype MUST be in the key) ───────────────────

test("subtypesOf folds stage+suffix / trainerType / energyType into subtypes", () => {
  assert.deepEqual(subtypesOf(charizard), ["Stage2", "ex"]);
  assert.deepEqual(subtypesOf(townStore), ["Stadium"]);
  assert.deepEqual(subtypesOf({ id: "x", localId: "1", name: "E", category: "Energy", energyType: "Special" }), ["Special"]);
  assert.deepEqual(subtypesOf({ id: "x", localId: "1", name: "P", category: "Pokemon" }), []);
});

// ── trainer/energy effect → rules (identity text, §4.1) ──────────────────────

test("rulesOf lifts trainer/energy effect into the rules array; Pokémon get none", () => {
  assert.deepEqual(rulesOf(townStore), [townStore.effect]);
  assert.deepEqual(rulesOf(charizard), []);
});

// ── full resolvable mapping feeds resolve() a stable key ─────────────────────

test("toResolvable produces a resolvable card that resolve() keys", () => {
  const r = toResolvable(charizard)!;
  assert.equal(r.supertype, "Pokémon");
  assert.equal(r.hp, "330"); // number → string
  assert.equal(r.evolvesFrom, "Charmeleon"); // evolveFrom → evolvesFrom
  assert.equal(r.convertedRetreatCost, 2); // retreat → convertedRetreatCost
  assert.equal(r.attacks![0]!.text, charizard.attacks![0]!.effect); // effect → text
  assert.equal(r.attacks![0]!.damage, "180+");
  const key = resolve(r).equivalence_key;
  assert.match(key, /^[0-9a-f]{16}$/);
});

test("toResolvable returns null for an unmappable category (orchestrator skips it)", () => {
  assert.equal(toResolvable({ id: "x", localId: "1", name: "?", category: undefined }), null);
});

test("a cross-printing reprint resolves to the SAME key regardless of set/number", () => {
  const reprint: TcgdexCardFull = { ...charizard, id: "sv08-201", localId: "201" };
  assert.equal(resolve(toResolvable(charizard)!).equivalence_key, resolve(toResolvable(reprint)!).equivalence_key);
});

// ── canonical identity (§3.4) ────────────────────────────────────────────────

test("deriveCanonicalCode collapses zero-padding, idempotent on unpadded ids", () => {
  assert.equal(deriveCanonicalCode("sv03"), "sv3");
  assert.equal(deriveCanonicalCode("sv08"), "sv8");
  assert.equal(deriveCanonicalCode("swsh3"), "swsh3");
  assert.equal(deriveCanonicalCode("base1"), "base1");
  assert.equal(deriveCanonicalCode("swsh12pt5"), "swsh12pt5");
});

test("normalizeNumber strips leading zeros only when purely numeric", () => {
  assert.equal(normalizeNumber("001"), "1");
  assert.equal(normalizeNumber("125"), "125");
  assert.equal(normalizeNumber("SV107"), "SV107");
  assert.equal(normalizeNumber("tg01"), "TG01");
});

test("canonicalCardId joins set code + normalized number (§3.4 worked example)", () => {
  assert.equal(canonicalCardId("sv3", normalizeNumber("125")), "sv3-125");
});

test("canonicalSetCode reads the committed map and throws loudly on an unmapped set", () => {
  const map = { sv03: "sv3" };
  assert.equal(canonicalSetCode("sv03", map), "sv3");
  assert.throws(() => canonicalSetCode("brandnew99", map), /not in set-code-map\.json/);
});

// ── image URL assembly ───────────────────────────────────────────────────────

test("imageUrl appends quality + extension, null-safe", () => {
  assert.equal(imageUrl("https://assets.tcgdex.net/en/sv/sv03/125", "low"), "https://assets.tcgdex.net/en/sv/sv03/125/low.webp");
  assert.equal(imageUrl("https://assets.tcgdex.net/en/sv/sv03/125", "high"), "https://assets.tcgdex.net/en/sv/sv03/125/high.webp");
  assert.equal(imageUrl(undefined, "low"), null);
});
