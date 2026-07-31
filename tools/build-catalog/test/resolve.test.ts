// The 7 equivalence claims from spec §4, validated interactively via the logic
// prototype (issue #5), pinned here as regression tests. Each scenario asserts
// that its member cards either share an equivalence_key (SAME) or are all distinct
// (SPLIT). If one of these flips, resolve() drifted from the spec.

import { test } from "node:test";
import assert from "node:assert/strict";
import { resolve, type ResolvableCard } from "../src/resolve.js";

type Card = ResolvableCard & { _id: string };
const key = (c: Card) => resolve(c).equivalence_key;

function expectSame(cards: Card[]) {
  const keys = cards.map(key);
  assert.equal(new Set(keys).size, 1, `expected SAME, got ${keys.join(", ")}`);
}
function expectSplit(cards: Card[]) {
  const keys = cards.map(key);
  assert.equal(new Set(keys).size, keys.length, `expected SPLIT, got ${keys.join(", ")}`);
}

test("S1 cross-set reprint → SAME (identity fields not in key)", () => {
  const base: Card = { _id: "a", name: "Boss's Orders", supertype: "Trainer", subtypes: ["Supporter"],
    rules: ["Switch 1 of your opponent's Benched Pokémon with their Active Pokémon."] };
  const reprint: Card = { ...base, _id: "b", flavorText: "reprint art" };
  expectSame([base, reprint]);
});

test("S2 distinct same-name variants → SPLIT", () => {
  const a: Card = { _id: "a", name: "Charizard ex", supertype: "Pokémon", subtypes: ["Stage 2", "ex"], hp: "330",
    attacks: [{ name: "Burning Darkness", cost: ["Fire", "Fire"], damage: "180" }] };
  const b: Card = { _id: "b", name: "Charizard ex", supertype: "Pokémon", subtypes: ["Stage 2", "ex"], hp: "330",
    attacks: [{ name: "Explosive Vortex", cost: ["Fire", "Fire", "Colorless"], damage: "330" }] };
  expectSplit([a, b]);
});

test("S3 errata rewording → SPLIT (exact-match normalization)", () => {
  const a: Card = { _id: "a", name: "Ultra Ball", supertype: "Trainer", subtypes: ["Item"],
    rules: ["You can use this card only if you discard 2 other cards from your hand."] };
  const b: Card = { ...a, _id: "b", rules: ["Discard 2 cards from your hand."] };
  expectSplit([a, b]);
});

test("S4 flavor-only difference → SAME (flavor dropped)", () => {
  const a: Card = { _id: "a", name: "Pikachu", supertype: "Pokémon", subtypes: ["Basic"], hp: "60", types: ["Lightning"],
    attacks: [{ name: "Gnaw", cost: ["Colorless"], damage: "20" }], flavorText: "flavor one" };
  const b: Card = { ...a, _id: "b", flavorText: "totally different flavor two" };
  expectSame([a, b]);
});

test("S5 Tool vs Item name clash → SPLIT (subtype in key)", () => {
  const tool: Card = { _id: "a", name: "Buddy Gear", supertype: "Trainer", subtypes: ["Pokémon Tool"],
    rules: ["The Pokémon this card is attached to has no Retreat Cost."] };
  const item: Card = { ...tool, _id: "b", subtypes: ["Item"] };
  expectSplit([tool, item]);
});

test("S6 ACE SPEC vs non-ACE-SPEC → SPLIT (flag in key)", () => {
  const plain: Card = { _id: "a", name: "Master Ball", supertype: "Trainer", subtypes: ["Item"],
    rules: ["Search your deck for a Pokémon, reveal it, and put it into your hand. Then, shuffle your deck."] };
  const ace: Card = { ...plain, _id: "b", subtypes: ["Item", "ACE SPEC"] };
  expectSplit([plain, ace]);
});

test("S7 energy-cost order → SAME (sorted multiset)", () => {
  const a: Card = { _id: "a", name: "Cinderace", supertype: "Pokémon", subtypes: ["Stage 2"], hp: "170", types: ["Fire"],
    attacks: [{ name: "Blaze Kick", cost: ["Fire", "Colorless", "Colorless"], damage: "130" }] };
  const b: Card = { ...a, _id: "b",
    attacks: [{ name: "Blaze Kick", cost: ["Colorless", "Fire", "Colorless"], damage: "130" }] };
  expectSame([a, b]);
});

test("basic energy is type-only, derived from name when types[] is empty (§4.1/§4.5)", () => {
  // pokemontcg.io ships basic energy with types: [] — type is only in the name.
  const fire: Card = { _id: "a", name: "Fire Energy", supertype: "Energy", subtypes: ["Basic"], types: [] };
  const water: Card = { _id: "b", name: "Basic Water Energy", supertype: "Energy", subtypes: ["Basic"], types: [] };
  const fire2: Card = { _id: "c", name: "Fire Energy", supertype: "Energy", subtypes: ["Basic"], types: [] };
  expectSplit([fire, water]); // different types → different groups
  expectSame([fire, fire2]); // same type across printings → one group
});

test("determinism: resolve() is stable across calls", () => {
  const c: Card = { _id: "a", name: "Snorlax", supertype: "Pokémon", subtypes: ["Basic"], hp: "150", types: ["Colorless"] };
  assert.equal(key(c), key(structuredClone(c)));
});
