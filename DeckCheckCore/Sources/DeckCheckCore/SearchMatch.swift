import Foundation

/// Multi-term catalog search matching (spec §7.3, extended). The query is split into
/// whitespace tokens, and a card matches only when **every** token is a case-insensitive
/// substring of at least one of its fields: card **name**, **set name**, **set code**,
/// collector **number**, or **number/printedTotal**. So the terms are optional and
/// additive — "charizard" widens by name, "charizard 125" or "charizard obf" narrows to
/// a printing, and "mega evolution" or "MEG" match by set with no name at all.
///
/// The tokenization (apostrophe-folding + lowercasing) is the shared authority; the
/// SQLite catalog reuses `tokens(_:)` and mirrors the per-field match in SQL, while the
/// in-memory test fake uses `matches(_:tokens:)` directly.
public enum SearchMatch {
    /// Fold the query into comparable tokens: strip apostrophe variants (iOS smart
    /// quotes and look-alikes), lowercase, split on whitespace, drop empties.
    public static func tokens(_ query: String) -> [String] {
        fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Whether a card matches all the given (already-folded) tokens.
    public static func matches(_ card: CatalogCard, tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return false }
        let fields = fields(card)
        return tokens.allSatisfy { t in fields.contains { $0.contains(t) } }
    }

    /// The folded, searchable fields of a card.
    static func fields(_ card: CatalogCard) -> [String] {
        var f = [fold(card.name), fold(card.setName), fold(card.ptcgoCode ?? ""), fold(card.number)]
        if let total = card.printedTotal { f.append(fold("\(card.number)/\(total)")) }
        return f.filter { !$0.isEmpty }
    }

    /// Lowercase + drop apostrophe variants, so "Arven's", "Arven’s" (curly) and
    /// "Arvens" all compare equal — matching the catalog's apostrophe-folded name column.
    private static func fold(_ s: String) -> String {
        var t = s
        for a in Normalize.apostrophes { t = t.replacingOccurrences(of: a, with: "") }
        return t.lowercased()
    }
}
