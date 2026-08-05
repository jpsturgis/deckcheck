// The text stamped into the cards_fts search index.
//
// This has to fold a card's searchable fields exactly the way the app folds a typed
// query, or the index and the query disagree about what matches — the index would be
// fast and wrong. The app's authority is SearchMatch.fold / Normalize.apostrophes in
// DeckCheckCore (and SearchMatch.fields for which fields are searchable). Keep the
// two in step; test/search-index.test.ts pins the folding.

/** Apostrophe variants that must all fold away — mirrors Normalize.apostrophes. */
const APOSTROPHES = ["\u{2019}", "\u{2018}", "\u{02BC}", "'"];

/** Stamped into meta so a snapshot's search index is identifiable by shape. */
export const SEARCH_INDEX_VERSION = "fts5-trigram-v1";

/** Drop every apostrophe variant, then lowercase — mirrors SearchMatch.fold. */
export function foldForSearch(s: string): string {
  let t = s;
  for (const a of APOSTROPHES) t = t.split(a).join("");
  return t.toLowerCase();
}

/** One card's searchable fields, as SearchMatch.fields defines them. */
export interface SearchableCard {
  name: string;
  set_name: string;
  ptcgo_code: string | null;
  number: string;
  printed_total: number | null;
}

/**
 * The indexed text for one card: the five searchable fields, folded, one per line.
 * Newline-separated so a trigram can't straddle two fields and invent a match that
 * neither field contains.
 */
export function searchText(r: SearchableCard): string {
  const fields = [r.name, r.set_name, r.ptcgo_code ?? "", r.number];
  if (r.printed_total != null) fields.push(`${r.number}/${r.printed_total}`);
  return fields
    .map(foldForSearch)
    .filter((f) => f.length > 0)
    .join("\n");
}
