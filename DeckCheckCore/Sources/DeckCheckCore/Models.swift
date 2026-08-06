import Foundation

// Value types shared across the query-core.

/// Card supertype. Only what the query-core needs; the catalog carries the rest.
public enum Supertype: String, Equatable {
    case pokemon = "Pokémon"
    case trainer = "Trainer"
    case energy = "Energy"
    case unknown
}

/// A row of the bundled catalog snapshot — the subset the query-core
/// reads. `equivalenceKey` is precomputed at prep time; the core never
/// hashes, it groups by this key.
public struct CatalogCard: Equatable {
    public let cardId: String          // "ptcg:sv8-4" — stable identity
    public let setId: String
    public let setName: String
    public let ptcgoCode: String?      // TCG Live set code — nullable
    public let number: String          // collector number, no leading zeros
    public let name: String
    public let supertype: Supertype
    public let subtypes: [String]      // Item / Tool / Supporter / Stadium, Basic / Stage 2, …
    public let equivalenceKey: String  // functional-equivalence group
    public let standardLegal: Bool     // per-printing legality overlay
    public let expandedLegal: Bool
    public let regulationMark: String?
    public let printedTotal: Int?      // the set's printed total — the "/191" set-pin
    public let imageSmall: String?     // thumbnail URL, for the correction picker
    public let imageLarge: String?     // full card image URL, for the detail view
    public let releaseDate: String?    // the set's release date, "YYYY/MM/DD" — sorts printings newest-first
    public let hp: String?             // HP, e.g. "160" — a recognizer disambiguator; nil for Trainer/Energy

    public init(cardId: String, setId: String, setName: String, ptcgoCode: String?,
                number: String, name: String, supertype: Supertype, equivalenceKey: String,
                standardLegal: Bool, expandedLegal: Bool, regulationMark: String? = nil,
                printedTotal: Int? = nil, imageSmall: String? = nil, imageLarge: String? = nil,
                releaseDate: String? = nil, hp: String? = nil, subtypes: [String] = []) {
        self.cardId = cardId; self.setId = setId; self.setName = setName
        self.ptcgoCode = ptcgoCode; self.number = number; self.name = name
        self.supertype = supertype; self.subtypes = subtypes; self.equivalenceKey = equivalenceKey
        self.standardLegal = standardLegal; self.expandedLegal = expandedLegal
        self.regulationMark = regulationMark
        self.printedTotal = printedTotal; self.imageSmall = imageSmall; self.imageLarge = imageLarge
        self.hp = hp
        self.releaseDate = releaseDate
    }
}

public extension Sequence where Element == CatalogCard {
    /// Printings ordered by set release date, newest first — surfaces the current
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

public extension CatalogCard {
    /// `058/132` — zero-pad the collector number to at least `minWidth` (and to the
    /// printed total's own width, whichever is wider) and append the total. Non-numeric
    /// numbers (TG/GG galleries) pass through unchanged, and so does a **zero** total:
    /// promo sets carry `printedTotal = 0`, and a black star promo prints its number
    /// with no "/total" at all — treating zero as real would emit "5/0", which nothing
    /// can match against.
    ///
    /// `minWidth: 0` (the default) is TCGplayer Mass Entry's own convention — pad only
    /// to the total's width, and leave the total itself exactly as printed. The
    /// printed-card convention on the card itself instead floors the *number* at 3
    /// digits regardless of the total ("029/086"); pass `minWidth: 3` for that. Either
    /// way only the number is padded — the total is shown as-is.
    func designation(minWidth: Int = 0) -> String {
        guard let total = printedTotal, total > 0, number.allSatisfy(\.isNumber) else { return number }
        let width = max(minWidth, String(total).count, number.count)
        let padded = String(repeating: "0", count: max(0, width - number.count)) + number
        return "\(padded)/\(total)"
    }
}

/// An owned printing, as it comes from the inventory Sheet: the machine
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

/// One parsed decklist line. `setCode`/`number` are nil when the
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
    case basicEnergy(name: String)     // auto-satisfied — basic energy isn't tracked
    case unidentified(reason: String)  // bucketed for manual attention, excluded from buildable
}

public struct ResolvedLine: Equatable {
    public let parsed: ParsedLine
    public let resolution: LineResolution
    public var quantity: Int { parsed.quantity }

    public init(parsed: ParsedLine, resolution: LineResolution) {
        self.parsed = parsed; self.resolution = resolution
    }
}

/// Optional legality lens — off by default, user-selected.
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
    /// Copies owned in this exact equivalence group.
    public let ownedQty: Int
    /// Copies owned of what `ErrataBridge` says is the same card printed with different
    /// wording. Counted toward the deck, but reported separately — see `GapReport`.
    public let errataOwnedQty: Int
    public let shortQty: Int
    public let status: CardStatus
    /// You own the functional card but via a *different printing* than the deck lists.
    public let differentPrinting: Bool
    /// Legality lens on: you own a functional copy but none of your printings are legal in the format.
    public let ownedNoLegalPrinting: Bool
    /// A representative catalog printing for display / export naming.
    public let representative: CatalogCard
    /// The differently-worded printings you own, newest first — so the report can show
    /// *which* copies it's counting.
    public let errataPrintings: [CatalogCard]

    /// Copies that can go in the deck: exact group plus bridged wording variants.
    public var effectiveOwnedQty: Int { ownedQty + errataOwnedQty }

    public init(name: String, equivalenceKey: String, requiredQty: Int, ownedQty: Int,
                shortQty: Int, status: CardStatus, differentPrinting: Bool,
                ownedNoLegalPrinting: Bool, representative: CatalogCard,
                errataOwnedQty: Int = 0, errataPrintings: [CatalogCard] = []) {
        self.name = name; self.equivalenceKey = equivalenceKey
        self.requiredQty = requiredQty; self.ownedQty = ownedQty; self.shortQty = shortQty
        self.status = status; self.differentPrinting = differentPrinting
        self.ownedNoLegalPrinting = ownedNoLegalPrinting; self.representative = representative
        self.errataOwnedQty = errataOwnedQty; self.errataPrintings = errataPrintings
    }
}

/// The gap-first report.
public struct GapReport: Equatable {
    public let entries: [GapEntry]        // identified non-energy cards, sorted missing→short→have
    public let unidentified: [ParsedLine] // ❓ couldn't identify — excluded from buildable
    public let basicEnergyQty: Int        // 🔋 auto-satisfied
    public let deckTotal: Int             // sum of every parsed line's qty (the "/60")
    public let buildableQty: Int          // covered now (functional ownership + basic energy)
    public let shortTotal: Int            // total copies you still need
    public let legalityLens: LegalityFormat?

    // The four display buckets are mutually exclusive and together cover `entries`.
    // Anything the errata bridge contributed to gets its own bucket rather than being
    // folded into have/short, so a wording difference is always visible.
    public var missing: [GapEntry] { entries.filter { $0.status == .missing } }
    public var short: [GapEntry] { entries.filter { $0.status == .short && $0.errataOwnedQty == 0 } }
    public var have: [GapEntry] { entries.filter { $0.status == .have && $0.errataOwnedQty == 0 } }
    /// Covered — wholly or partly — by a printing whose wording differs (see `ErrataBridge`).
    public var differentWording: [GapEntry] { entries.filter { $0.errataOwnedQty > 0 } }

    public init(entries: [GapEntry], unidentified: [ParsedLine], basicEnergyQty: Int,
                deckTotal: Int, buildableQty: Int, shortTotal: Int, legalityLens: LegalityFormat?) {
        self.entries = entries; self.unidentified = unidentified
        self.basicEnergyQty = basicEnergyQty; self.deckTotal = deckTotal
        self.buildableQty = buildableQty; self.shortTotal = shortTotal
        self.legalityLens = legalityLens
    }
}
