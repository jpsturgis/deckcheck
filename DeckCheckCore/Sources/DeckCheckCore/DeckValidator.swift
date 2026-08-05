import Foundation

/// One thing wrong with a decklist, as a tournament judge would call it.
public struct DeckViolation: Equatable, Identifiable {
    public enum Kind: Equatable {
        /// The deck isn't exactly `DeckValidator.requiredCardCount` cards.
        case cardCount(actual: Int)
        /// More than four cards sharing a name (basic energy excepted).
        case copyLimit(name: String, count: Int)
        /// A card the format doesn't allow.
        case notLegal(name: String, format: LegalityFormat)
        /// A line that couldn't be resolved, so it can't be judged at all.
        case unidentified(raw: String)
    }

    public let kind: Kind
    public let message: String

    public var id: String { message }

    public init(kind: Kind, message: String) {
        self.kind = kind; self.message = message
    }
}

/// Deck legality for constructed play.
///
/// Three rules, and one of them is easy to get subtly wrong:
///
/// 1. **Exactly 60 cards.** Not "at most" — a 58-card deck is illegal.
/// 2. **At most four cards with the same name**, basic energy excepted.
/// 3. **Every card legal in the format**, when a format lens is applied.
///
/// Rule 2 is by **printed name**, and that is *not* the equivalence key the rest of
/// this package groups by. Two cards can share a name and play completely differently
/// — different Pikachu from different sets get different equivalence keys — and the
/// rule still caps them at four *between them*. Grouping by equivalence key here would
/// wave through an illegal deck. Conversely, a card and its reprint share a name, so
/// name-grouping catches those too; name is the stricter and correct lens.
///
/// This is deliberately about legality only. Whether you *own* the cards is the
/// gap-check's question, and the two are kept apart — a deck can be perfectly legal and
/// entirely unbuildable.
public enum DeckValidator {
    public static let requiredCardCount = 60
    public static let copyLimit = 4

    public static func validate(decklist: String,
                                catalog: any CatalogLookup,
                                lens: LegalityFormat? = nil) -> [DeckViolation] {
        let resolved = DecklistParser.parse(decklist).map { LineResolver.resolve($0, catalog: catalog) }
        return validate(resolved: resolved, lens: lens)
    }

    public static func validate(resolved: [ResolvedLine],
                                lens: LegalityFormat? = nil) -> [DeckViolation] {
        var out: [DeckViolation] = []

        // ── 1. deck size ──
        let total = resolved.reduce(0) { $0 + $1.quantity }
        if total != requiredCardCount {
            let delta = total - requiredCardCount
            let detail = delta > 0 ? "\(delta) over" : "\(-delta) short"
            out.append(DeckViolation(
                kind: .cardCount(actual: total),
                message: "\(total) cards — a deck must be exactly \(requiredCardCount) (\(detail))."))
        }

        // ── 2. four-copy rule, by name ──
        // Basic energy is exempt, and it's exempt by rule, not by our not tracking it.
        var countsByName: [String: (display: String, count: Int)] = [:]
        for line in resolved {
            guard let name = countableName(line) else { continue }
            let key = Normalize.name(name)
            let existing = countsByName[key]
            countsByName[key] = (display: existing?.display ?? name,
                                 count: (existing?.count ?? 0) + line.quantity)
        }
        for (_, entry) in countsByName.sorted(by: { $0.value.display < $1.value.display })
        where entry.count > copyLimit {
            out.append(DeckViolation(
                kind: .copyLimit(name: entry.display, count: entry.count),
                message: "\(entry.count)× \(entry.display) — the limit is \(copyLimit) cards with the same name."))
        }

        // ── 3. format legality ──
        if let lens {
            var reported = Set<String>()
            for line in resolved {
                guard case let .resolved(card) = line.resolution else { continue }
                let legal = lens == .standard ? card.standardLegal : card.expandedLegal
                guard !legal, reported.insert(card.name).inserted else { continue }
                out.append(DeckViolation(
                    kind: .notLegal(name: card.name, format: lens),
                    message: "\(card.name) isn't legal in \(lens == .standard ? "Standard" : "Expanded")."))
            }
        }

        // ── 4. lines we couldn't place ──
        // Last, and phrased as "can't judge" rather than "wrong": an unresolved promo
        // is a gap in our catalog, not necessarily a problem with the deck.
        for line in resolved {
            guard case .unidentified = line.resolution else { continue }
            out.append(DeckViolation(
                kind: .unidentified(raw: line.parsed.raw),
                message: "Couldn't identify “\(line.parsed.raw)” — it isn't counted above."))
        }

        return out
    }

    /// The name a line contributes to the four-copy tally, or nil when it's exempt.
    ///
    /// Prefers the *catalog's* name over the decklist's spelling so that a list writing
    /// "Boss' Orders" and one writing "Boss's Orders" land in the same bucket.
    private static func countableName(_ line: ResolvedLine) -> String? {
        switch line.resolution {
        case .basicEnergy:          return nil            // exempt by rule
        case let .resolved(card):   return card.name
        case .unidentified:         return nil            // reported separately; can't judge
        }
    }
}
