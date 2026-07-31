import Foundation

/// The catalog read surface the query-core needs. The app backs this with the
/// bundled SQLite snapshot; tests back it with an in-memory fake.
/// Keeping resolution behind a protocol is what lets the whole core be unit-tested
/// without a database.
public protocol CatalogLookup {
    /// Printings matching a TCG Live set code + collector number.
    func cards(setCode: String, number: String) -> [CatalogCard]
    /// Printings matching a collector number across all sets (number-only fallback).
    func cards(number: String) -> [CatalogCard]
    /// Printings in a set with the given printed total + collector number — the
    /// "/191" set-pinning path used when the set code is unreadable.
    func cards(printedTotal: Int, number: String) -> [CatalogCard]
    /// A single printing by its stable id (for owned-printing legality/display joins).
    func card(byId cardId: String) -> CatalogCard?
    /// Every printing in a functional-equivalence group (for the card detail view, #29).
    func cards(equivalenceKey: String) -> [CatalogCard]
    /// Every card in the snapshot — for pushing the slim resolution index into the
    /// user's sheet (in-browser gap-check). A protocol *requirement* (not
    /// just an extension) so a real backend's implementation is dynamically dispatched
    /// through `any CatalogLookup`; the default returns [] for backends that can't
    /// enumerate (e.g. in-memory test doubles).
    func allCards() -> [CatalogCard]
}

public extension CatalogLookup {
    func allCards() -> [CatalogCard] { [] }
}

/// Text normalization shared by resolution + basic-energy detection.
enum Normalize {
    /// Apostrophe variants that must all fold together: straight (U+0027), curly
    /// (U+2019, what iOS "smart punctuation" types), plus a couple of look-alikes.
    static let apostrophes = ["\u{2019}", "\u{2018}", "\u{02BC}", "'"]

    static func name(_ s: String) -> String {
        var t = s
        for a in apostrophes { t = t.replacingOccurrences(of: a, with: "") }
        return t.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
