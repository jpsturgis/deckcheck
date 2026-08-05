// DDL for the bundled, read-only catalog (spec v2 §2, §3). Two tables the app
// joins by card_id; a sets table for code→set + printedTotal resolve fallbacks;
// a meta table for provenance / staleness detection. v2 additions vs v1: the
// primary key is the canonical `<set>-<number>` (§3.4), and every card carries a
// `source_tag` + `source_card_id` so cross-source key drift is detectable (§3.4).

export const SCHEMA = /* sql */ `
CREATE TABLE meta (
  key   TEXT PRIMARY KEY,
  value TEXT
);

CREATE TABLE sets (
  id             TEXT PRIMARY KEY,   -- canonical set code (§3.4), e.g. "sv3"
  source_id      TEXT NOT NULL,      -- the TCGdex set id, e.g. "sv03"
  name           TEXT NOT NULL,
  ptcgo_code     TEXT,               -- TCG Live code, nullable (§5.1)
  printed_total  INTEGER,            -- the "/191" set-pinning fallback (§6)
  total          INTEGER,
  standard_legal INTEGER NOT NULL DEFAULT 0,
  expanded_legal INTEGER NOT NULL DEFAULT 0,
  release_date   TEXT
);
CREATE INDEX idx_sets_ptcgo         ON sets(ptcgo_code);
CREATE INDEX idx_sets_printed_total ON sets(printed_total);

CREATE TABLE cards (
  card_id         TEXT PRIMARY KEY,  -- canonical "<set>-<number>" — the Sheet's row key (§3.4, §5.1)
  source_card_id  TEXT NOT NULL,     -- the source (TCGdex) card id, e.g. "sv03-125"
  set_id          TEXT NOT NULL,     -- canonical set code
  number          TEXT NOT NULL,     -- no leading zeros when numeric (§3.2)
  name            TEXT NOT NULL,
  supertype       TEXT NOT NULL,
  subtypes        TEXT NOT NULL,     -- JSON array
  equivalence_key TEXT NOT NULL,     -- precomputed by resolve() (§4)
  norm_version    TEXT NOT NULL,
  source_tag      TEXT NOT NULL,     -- e.g. "tcgdex" — key-drift detection (§3.4)
  regulation_mark TEXT,
  standard_legal  INTEGER NOT NULL DEFAULT 0,  -- per-printing legality overlay (§4.4)
  expanded_legal  INTEGER NOT NULL DEFAULT 0,
  image_small     TEXT,
  image_large     TEXT,
  attributes      TEXT NOT NULL      -- JSON display blob (attacks, abilities, rules, …)
);
CREATE INDEX idx_cards_set_number      ON cards(set_id, number);        -- resolve step 1
CREATE INDEX idx_cards_number          ON cards(number);                -- number-only fallback
CREATE INDEX idx_cards_equivalence_key ON cards(equivalence_key);       -- functional grouping
CREATE INDEX idx_cards_name_nocase     ON cards(name COLLATE NOCASE);   -- search

-- Search index (docs/performance.md). Without it, search is a full-table LIKE scan
-- across five expressions — ~22 ms per keystroke against a 23k-card snapshot.
--
-- The trigram tokenizer, not the default unicode61, because search is specified as a
-- case-insensitive SUBSTRING match: "zard" must find "Charizard". A word/prefix
-- tokenizer silently returns nothing for that, which is a wrong answer rather than a
-- slow one. Trigram costs more index (+3.6 MB on an 18.1 MB snapshot, vs +0.8 MB for
-- unicode61) and can only match patterns of 3+ characters — the app falls back to LIKE
-- for shorter tokens.
--
-- Contentless: only the index is stored, and rowid joins back to cards, so the
-- searchable text isn't duplicated into the file. Rows are inserted with an explicit
-- rowid read from cards.rowid after the cards are in. Nothing in the build VACUUMs —
-- that would renumber cards.rowid and silently break the join.
CREATE VIRTUAL TABLE cards_fts USING fts5(
  text,
  content='',
  tokenize='trigram case_sensitive 0'
);
`;
