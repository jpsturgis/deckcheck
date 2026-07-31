import Foundation

// Value types shared across the query-core (spec §4, §5, §7.4).

/// Card supertype. Only what the query-core needs; the catalog carries the rest.
public enum Supertype: String, Equatable {
    case pokemon = "Pokémon"
    case trainer = "Trainer"
    case energy = "Energy"
    case unknown
}

/// A row of the bundled catalog snapshot (spec §3.1) — the subset the query-core
/// reads. `equivalenceKey` is precomputed at prep time (spec §4.3); the core never
/// hashes, it groups by this key.
public struct CatalogCard: Equatable {
    public let cardId: String          // "ptcg:sv8-4" — stable identity (§5.1)
    public let setId: String
    public let setName: String
    public let ptcgoCode: String?      // TCG Live set code — nullable (§3.2)
    public let number: String          // collector number, no leading zeros (§3.2)
    public let name: String
    public let supertype: Supertype
    public let equivalenceKey: String  // functional-equivalence group (§4)
    public let standardLegal: Bool     // per-printing legality overlay (§4.4)
    public let expandedLegal: Bool
    public let regulationMark: String?
    public let printedTotal: Int?      // the set's printed total — the "/191" set-pin (§3.2)
    public let imageSmall: String?     // thumbnail URL, for the correction picker (§7.1)
    public let imageLarge: String?     // full card image URL, for the detail view (#29)
    public let releaseDate: String?    // the set's release date, "YYYY/MM/DD" — sorts printings newest-first (#53)
    public let hp: String?             // HP, e.g. "160" — a recognizer disambiguator (§6); nil for Trainer/Energy

    public init(cardId: String, setId: String, setName: String, ptcgoCode: String?,
                number: String, name: String, supertype: Supertype, equivalenceKey: String,
                standardLegal: Bool, expandedLegal: Bool, regulationMark: String? = nil,
                printedTotal: Int? = nil, imageSmall: String? = nil, imageLarge: String? = nil,
                releaseDate: String? = nil, hp: String? = nil) {
        self.cardId = cardId; self.setId = setId; self.setName = setName
        self.ptcgoCode = ptcgoCode; self.number = number; self.name = name
        self.supertype = supertype; self.equivalenceKey = equivalenceKey
        self.standardLegal = standardLegal; self.expandedLegal = expandedLegal
        self.regulationMark = regulationMark
        self.printedTotal = printedTotal; self.imageSmall = imageSmall; self.imageLarge = imageLarge
        self.hp = hp
        self.releaseDate = releaseDate
    }
}

public extension Sequence where Element == CatalogCard {
    /// Printings ordered by set release date, newest first (#53) — surfaces the current
    /// printing ahead of older reprints. `release_date` is "YYYY/MM/DD", so a plain
    /// string compare is chronological; printings whose set carries no date sort last,
    /// with collector number as a stable tiebreak within a single release.
    func orderedNewestFirst() -> [CatalogCard] {
        sorted { a, b in
            let ra = a.releaseDate ?? "", rb = b.releaseDate ?? ""
            if ra != rb { return ra > rb }
            return a.number.localizedStandardCompare(b.number) == .orderedAscending
        }
    }
}

/// An owned printing, as it comes from the inventory Sheet (§5.1): the machine
/// columns the diff needs. `equivalenceKey` is denormalized in the Sheet;
/// per-printing legality is looked up from the catalog by `cardId` when needed.
public struct OwnedCard: Equatable {
    public let cardId: String
    public let equivalenceKey: String
    public let qty: Int

    public init(cardId: String, equivalenceKey: String, qty: Int) {
        self.cardId = cardId; self.equivalenceKey = equivalenceKey; self.qty = qty
    }
}

/// One parsed decklist line (spec §7.4 input). `setCode`/`number` are nil when the
/// line is bare (e.g. a basic-energy line, or a name-only paste).
public struct ParsedLine: Equatable {
    public let quantity: Int
    public let name: String
    public let setCode: String?
    public let number: String?
    public let raw: String

    public init(quantity: Int, name: String, setCode: String?, number: String?, raw: String) {
        self.quantity = quantity; self.name = name
        self.setCode = setCode; self.number = number; self.raw = raw
    }
}

/// How a decklist line resolved against the catalog.
public enum LineResolution: Equatable {
    case resolved(CatalogCard)         // a unique functional printing (one equivalence_key)
    case basicEnergy(name: String)     // auto-satisfied — basic energy isn't tracked (§4.5)
    case unidentified(reason: String)  // bucketed for manual attention, excluded from buildable (§7.4)
}

public struct ResolvedLine: Equatable {
    public let parsed: ParsedLine
    public let resolution: LineResolution
    public var quantity: Int { parsed.quantity }

    public init(parsed: ParsedLine, resolution: LineResolution) {
        self.parsed = parsed; self.resolution = resolution
    }
}

/// Optional legality lens (spec §4.4, §7.4) — off by default, user-selected.
public enum LegalityFormat: String, Equatable {
    case standard, expanded
}

/// One card's standing in the gap-check.
public enum CardStatus: Equatable {
    case have     // owned functional copies ≥ required
    case short    // own some, need more
    case missing  // own none in the equivalence group
}

/// One line of the gap-first report — an equivalence group required by the deck.
public struct GapEntry: Equatable {
    public let name: String
    public let equivalenceKey: String
    public let requiredQty: Int
    public let ownedQty: Int
    public let shortQty: Int
    public let status: CardStatus
    /// You own the functional card but via a *different printing* than the deck lists (§7.4 "🔁").
    public let differentPrinting: Bool
    /// Legality lens on: you own a functional copy but none of your printings are legal in the format.
    public let ownedNoLegalPrinting: Bool
    /// A representative catalog printing for display / export naming.
    public let representative: CatalogCard

    public init(name: String, equivalenceKey: String, requiredQty: Int, ownedQty: Int,
                shortQty: Int, status: CardStatus, differentPrinting: Bool,
                ownedNoLegalPrinting: Bool, representative: CatalogCard) {
        self.name = name; self.equivalenceKey = equivalenceKey
        self.requiredQty = requiredQty; self.ownedQty = ownedQty; self.shortQty = shortQty
        self.status = status; self.differentPrinting = differentPrinting
        self.ownedNoLegalPrinting = ownedNoLegalPrinting; self.representative = representative
    }
}

/// The gap-first report (spec §7.4).
public struct GapReport: Equatable {
    public let entries: [GapEntry]        // identified non-energy cards, sorted missing→short→have
    public let unidentified: [ParsedLine] // ❓ couldn't identify — excluded from buildable
    public let basicEnergyQty: Int        // 🔋 auto-satisfied
    public let deckTotal: Int             // sum of every parsed line's qty (the "/60")
    public let buildableQty: Int          // covered now (functional ownership + basic energy)
    public let shortTotal: Int            // total copies you still need
    public let legalityLens: LegalityFormat?

    public var missing: [GapEntry] { entries.filter { $0.status == .missing } }
    public var short: [GapEntry] { entries.filter { $0.status == .short } }
    public var have: [GapEntry] { entries.filter { $0.status == .have } }

    public init(entries: [GapEntry], unidentified: [ParsedLine], basicEnergyQty: Int,
                deckTotal: Int, buildableQty: Int, shortTotal: Int, legalityLens: LegalityFormat?) {
        self.entries = entries; self.unidentified = unidentified
        self.basicEnergyQty = basicEnergyQty; self.deckTotal = deckTotal
        self.buildableQty = buildableQty; self.shortTotal = shortTotal
        self.legalityLens = legalityLens
    }
}
