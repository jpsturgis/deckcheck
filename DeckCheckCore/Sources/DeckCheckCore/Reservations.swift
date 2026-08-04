import Foundation

// Deck reservations (the "in-use" feature). Decklists live as hand-maintained tabs
// in the user's Sheet (one `Deck: <name>` tab per deck). The app reads them and, per
// functional-equivalence group, sums how many copies the decks require ("reserved").
// The Cards view then shows `available = owned − reserved`. Because reserved is always
// recomputed from the current deck tabs, deleting a tab or changing a count releases
// those cards automatically.
//
// Pure + testable: reuses the same DecklistParser → LineResolver the gap-check uses,
// so a deck line reserves exactly the functional group it would satisfy.

/// One deck: its display name and the raw TCG Live decklist text (from its Sheet tab).
public struct DeckList: Equatable {
    public let name: String
    public let text: String
    /// The tab this came from, e.g. "Deck: Charizard ex". Kept verbatim so writing back
    /// never has to guess at the original spacing.
    public let tabTitle: String
    /// Whether the deck is physically assembled. An unbuilt deck — one that's an idea
    /// rather than a stack of sleeves — still gap-checks, but reserves nothing, so its
    /// cards stay free for the decks you have actually built. Read from a `#built:`
    /// line in the tab (see `DeckDirectives`); true when absent.
    public let isBuilt: Bool

    public init(name: String, text: String, tabTitle: String? = nil, isBuilt: Bool? = nil) {
        self.name = name
        self.text = text
        self.tabTitle = tabTitle ?? "\(GoogleSheets.deckTabPrefix) \(name)"
        self.isBuilt = isBuilt ?? DeckDirectives.isBuilt(text)
    }

    /// A copy with `isBuilt` overridden — how the app applies a toggle optimistically
    /// while the write to the Sheet is still in flight.
    public func setting(isBuilt: Bool) -> DeckList {
        DeckList(name: name, text: text, tabTitle: tabTitle, isBuilt: isBuilt)
    }
}

/// How many copies of each functional-equivalence group the decks reserve, and which
/// decks use each group (for display).
public struct Reservations: Equatable {
    public let reservedByKey: [String: Int]
    public let deckNamesByKey: [String: [String]]

    public init(reservedByKey: [String: Int] = [:], deckNamesByKey: [String: [String]] = [:]) {
        self.reservedByKey = reservedByKey; self.deckNamesByKey = deckNamesByKey
    }

    /// Copies reserved across all decks for a functional group.
    public func reserved(forKey key: String) -> Int { reservedByKey[key] ?? 0 }
    /// Deck names that use a functional group (deduped, in first-seen order).
    public func decks(forKey key: String) -> [String] { deckNamesByKey[key] ?? [] }

    public var isEmpty: Bool { reservedByKey.isEmpty }
}

public enum ReservationEngine {
    /// Compute reservations across all decks. Each resolvable line reserves its
    /// functional group by the line quantity; basic-energy and unidentified lines
    /// reserve nothing (they aren't tracked / can't be resolved). A group used by the
    /// same deck on multiple lines counts that deck once in `deckNamesByKey`.
    ///
    /// Decks marked not built are skipped entirely — a deck you've sketched but haven't
    /// sleeved shouldn't make its cards look unavailable.
    public static func compute(decks: [DeckList], catalog: CatalogLookup) -> Reservations {
        var reserved: [String: Int] = [:]
        var deckNames: [String: [String]] = [:]

        for deck in decks where deck.isBuilt {
            var keysThisDeck: [String] = []
            var seen = Set<String>()
            for line in DecklistParser.parse(deck.text) {
                guard case let .resolved(card) = LineResolver.resolve(line, catalog: catalog).resolution
                else { continue }
                reserved[card.equivalenceKey, default: 0] += line.quantity
                if seen.insert(card.equivalenceKey).inserted { keysThisDeck.append(card.equivalenceKey) }
            }
            for key in keysThisDeck { deckNames[key, default: []].append(deck.name) }
        }
        return Reservations(reservedByKey: reserved, deckNamesByKey: deckNames)
    }
}
