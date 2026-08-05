// The search index has to answer exactly what the old LIKE scan answered — it is a
// speed change, not a behaviour change. These run the real SCHEMA against an
// in-memory database and query it the way SQLiteCatalog does, so a tokenizer or
// folding mistake fails here rather than on a phone.

import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { SCHEMA } from "../src/schema.js";
import { searchText, foldForSearch, SEARCH_INDEX_VERSION } from "../src/search-index.js";

interface Row {
  card_id: string;
  set_id: string;
  number: string;
  name: string;
}

const SETS = [
  { id: "obf", name: "Obsidian Flames", ptcgo_code: "OBF", printed_total: 197 },
  { id: "paf", name: "Paldean Fates", ptcgo_code: "PAF", printed_total: 91 },
];
const CARDS: Row[] = [
  { card_id: "obf-125", set_id: "obf", number: "125", name: "Charizard ex" },
  { card_id: "paf-234", set_id: "paf", number: "234", name: "Charizard ex" },
  { card_id: "obf-197", set_id: "obf", number: "197", name: "Pidgeot ex" },
  { card_id: "paf-233", set_id: "paf", number: "233", name: "Arven\u{2019}s Mabosstiff ex" },
];

function build(): DatabaseSync {
  const db = new DatabaseSync(":memory:");
  db.exec(SCHEMA);
  const insSet = db.prepare(
    `INSERT INTO sets (id,source_id,name,ptcgo_code,printed_total,total,standard_legal,expanded_legal,release_date)
     VALUES (?,?,?,?,?,?,1,1,'2023/08/11')`,
  );
  for (const s of SETS) insSet.run(s.id, s.id, s.name, s.ptcgo_code, s.printed_total, s.printed_total);
  const insCard = db.prepare(
    `INSERT INTO cards (card_id,source_card_id,set_id,number,name,supertype,subtypes,equivalence_key,
       norm_version,source_tag,regulation_mark,standard_legal,expanded_legal,image_small,image_large,attributes)
     VALUES (?,?,?,?,?,'Pokémon','[]','k','v1','tcgdex','H',1,1,NULL,NULL,'{}')`,
  );
  for (const c of CARDS) insCard.run(c.card_id, c.card_id, c.set_id, c.number, c.name);

  const insFts = db.prepare(`INSERT INTO cards_fts (rowid, text) VALUES (?,?)`);
  const rows = db
    .prepare(
      `SELECT c.rowid AS rowid, c.name AS name, s.name AS set_name, s.ptcgo_code AS ptcgo_code,
              c.number AS number, s.printed_total AS printed_total
         FROM cards c JOIN sets s ON c.set_id = s.id`,
    )
    .all() as unknown as Array<Parameters<typeof searchText>[0] & { rowid: number }>;
  for (const r of rows) insFts.run(r.rowid, searchText(r));
  return db;
}

/** What SQLiteCatalog runs: tokens of 3+ chars ANDed as trigram substring matches. */
function search(db: DatabaseSync, query: string): string[] {
  const tokens = foldForSearch(query).split(/\s+/).filter(Boolean);
  const match = tokens.map((t) => `"${t.replace(/"/g, '""')}"`).join(" AND ");
  return (
    db
      .prepare(
        `SELECT c.card_id FROM cards c JOIN cards_fts ON cards_fts.rowid = c.rowid
          WHERE cards_fts MATCH ? ORDER BY c.name`,
      )
      .all(match) as unknown as Array<{ card_id: string }>
  )
    .map((r) => r.card_id)
    .sort();
}

/** The scan the index replaces — the reference answer. */
function likeSearch(db: DatabaseSync, query: string): string[] {
  const tokens = foldForSearch(query).split(/\s+/).filter(Boolean);
  const per =
    `(REPLACE(REPLACE(c.name, char(8217), ''), char(39), '') LIKE ? COLLATE NOCASE` +
    ` OR s.name LIKE ? COLLATE NOCASE OR s.ptcgo_code LIKE ? COLLATE NOCASE` +
    ` OR c.number LIKE ? COLLATE NOCASE OR (c.number || '/' || s.printed_total) LIKE ? COLLATE NOCASE)`;
  const sql =
    `SELECT c.card_id FROM cards c JOIN sets s ON c.set_id = s.id WHERE ` +
    tokens.map(() => per).join(" AND ") +
    ` ORDER BY c.name`;
  const binds: string[] = [];
  for (const t of tokens) for (let i = 0; i < 5; i++) binds.push(`%${t}%`);
  return (db.prepare(sql).all(...binds) as unknown as Array<{ card_id: string }>).map((r) => r.card_id).sort();
}

test("the schema creates a queryable search index", () => {
  const db = build();
  assert.deepEqual(search(db, "charizard"), ["obf-125", "paf-234"]);
  db.close();
});

test("the index agrees with the LIKE scan it replaces", () => {
  const db = build();
  for (const q of [
    "char",
    "charizard",
    "CHARIZARD",
    "zard", // infix — unicode61 would return nothing here
    "pidgeot",
    "nothing",
    "Obsidian Flames",
    "OBF 125",
    "Charizard PAF",
    "125/197",
    "Charizard ZZZ",
    "Arven\u{2019}s Mabosstiff",
    "Arven's Mabosstiff",
    "Arvens Mabosstiff",
  ]) {
    assert.deepEqual(search(db, q), likeSearch(db, q), `diverged for ${JSON.stringify(q)}`);
  }
  db.close();
});

test("folding drops every apostrophe variant and lowercases", () => {
  // The app folds a typed query the same way (SearchMatch.fold); if these drift, a
  // query and the index stop agreeing about what a name is.
  assert.equal(foldForSearch("Arven\u{2019}s"), "arvens");
  assert.equal(foldForSearch("Arven\u{2018}s"), "arvens");
  assert.equal(foldForSearch("Arven\u{02BC}s"), "arvens");
  assert.equal(foldForSearch("Arven's"), "arvens");
});

test("indexed text carries every searchable field, one per line", () => {
  const text = searchText({
    name: "Charizard ex",
    set_name: "Obsidian Flames",
    ptcgo_code: "OBF",
    number: "125",
    printed_total: 197,
  });
  assert.deepEqual(text.split("\n"), [
    "charizard ex",
    "obsidian flames",
    "obf",
    "125",
    "125/197",
  ]);
  // A set with no printed total simply omits the number/total field.
  assert.deepEqual(
    searchText({ name: "X", set_name: "Y", ptcgo_code: null, number: "1", printed_total: null }).split("\n"),
    ["x", "y", "1"],
  );
});

test("a trigram cannot straddle two fields", () => {
  // Fields are newline-separated: "obfx" must not match a card whose code is "OBF"
  // and whose next field starts with "x". Without the separator this invents matches.
  const db = build();
  assert.deepEqual(search(db, "obf125"), []);
  db.close();
});

test("the index version is stamped", () => {
  assert.equal(SEARCH_INDEX_VERSION, "fts5-trigram-v1");
});
