import Foundation

// Resolve an OCR read of a card to a catalog printing.
// Platform-independent so it's unit-tested here and reused by the app's scanner.

/// A collector-number / printed-total pair read off the card, e.g. 57 / 191.
public struct NumberTotal: Equatable {
    public let number: String        // collector number, leading zeros stripped
    public let printedTotal: String  // set total, e.g. "191"
    public init(number: String, printedTotal: String) {
        self.number = number; self.printedTotal = printedTotal
    }
}

/// The OCR read as candidates. The scanner fills this; the resolver consumes it.
public struct RecognizedCard {
    public var nameGuess: String?
    public var setCodes: [String]        // noisy OCR set-code guesses
    public var numberTotals: [NumberTotal] // strong signal: number + total
    public var looseNumbers: [String]    // fallback numbers (may include HP/damage noise)
    public var hp: String?               // HP value read off the card, e.g. "160" — a disambiguator

    public init(nameGuess: String? = nil, setCodes: [String] = [],
                numberTotals: [NumberTotal] = [], looseNumbers: [String] = [],
                hp: String? = nil) {
        self.nameGuess = nameGuess; self.setCodes = setCodes
        self.numberTotals = numberTotals; self.looseNumbers = looseNumbers
        self.hp = hp
    }
}

public struct PrintingResolution: Equatable {
    public enum Confidence: Equatable { case confident, uncertain }
    public var best: CatalogCard?         // the resolved printing, if unambiguous
    public var candidates: [CatalogCard]  // alternatives for the correction picker
    public var confidence: Confidence
    public init(best: CatalogCard?, candidates: [CatalogCard], confidence: Confidence) {
        self.best = best; self.candidates = candidates; self.confidence = confidence
    }
}

public enum PrintingResolver {
    // How much each corroborating signal is worth. The collector number is the entry
    // condition (every candidate matches it) and scores nothing on its own — a card is
    // only trusted when a *second*, independent on-card signal agrees, which is what
    // stops same-number/different-set collisions from resolving confidently.
    static let scoreTotal = 100   // printed set total ("/197") matches — near-unique with the number
    static let scoreName  = 100   // OCR'd card name matches
    static let scoreCode  = 60    // OCR'd set code matches ptcgoCode
    static let scoreHP    = 50    // HP matches — cheap to read, differs across colliding cards
    /// Minimum score to auto-pick: at least one real signal beyond the number.
    static let minConfident = scoreHP
    /// The leader must beat the runner-up functional group by at least this much;
    /// otherwise it's ambiguous and goes to the picker rather than a confident wrong pick.
    static let margin = scoreHP

    /// Score every catalog printing that shares a read collector number by how many
    /// other read signals corroborate it, group by functional key, and auto-pick the
    /// leader only when it clears `minConfident` *and* beats the runner-up group by
    /// `margin`. Everything else becomes a ranked candidate list for the picker.
    public static func resolve(_ rec: RecognizedCard, catalog: any CatalogLookup) -> PrintingResolution {
        let readNumbers = Set(rec.numberTotals.map(\.number) + rec.looseNumbers)
        guard !readNumbers.isEmpty else {
            return .init(best: nil, candidates: [], confidence: .uncertain)
        }

        // Every printing matching a read number (deduped) is a candidate.
        var byId: [String: CatalogCard] = [:]
        for n in readNumbers {
            for c in catalog.cards(number: n) { byId[c.cardId] = c }
        }
        let matched = Array(byId.values)
        guard !matched.isEmpty else {
            return .init(best: nil, candidates: [], confidence: .uncertain)
        }

        let name = rec.nameGuess.map(Normalize.name)
        func score(_ c: CatalogCard) -> Int {
            var s = 0
            if rec.numberTotals.contains(where: { $0.number == c.number && Int($0.printedTotal) == c.printedTotal }) {
                s += scoreTotal
            }
            if let name, Normalize.name(c.name) == name { s += scoreName }
            if let code = c.ptcgoCode,
               rec.setCodes.contains(where: { $0.caseInsensitiveCompare(code) == .orderedSame }) {
                s += scoreCode
            }
            if let hp = rec.hp, let cardHP = c.hp, hp == cardHP { s += scoreHP }
            return s
        }

        // Collapse to one entry per functional-equivalence group: its best-scoring (then
        // newest) printing, and the group's score = that printing's score.
        var groups: [(card: CatalogCard, score: Int)] = []
        for (_, cards) in Dictionary(grouping: matched, by: \.equivalenceKey) {
            let best = cards.map { (card: $0, score: score($0)) }.max { a, b in
                a.score != b.score ? a.score < b.score : isOlder(a.card, b.card)
            }!
            groups.append(best)
        }
        groups.sort { a, b in a.score != b.score ? a.score > b.score : isOlder(b.card, a.card) }

        let leader = groups[0]
        let clears = leader.score >= minConfident
        let ahead = groups.count == 1 || (leader.score - groups[1].score) >= margin
        if clears && ahead {
            return .init(best: leader.card, candidates: groups.map(\.card), confidence: .confident)
        }
        return .init(best: nil, candidates: Array(groups.prefix(24).map(\.card)), confidence: .uncertain)
    }

    /// True when `a` is an older printing than `b` (older/undated sorts down in ties).
    private static func isOlder(_ a: CatalogCard, _ b: CatalogCard) -> Bool {
        (a.releaseDate ?? "") < (b.releaseDate ?? "")
    }
}
