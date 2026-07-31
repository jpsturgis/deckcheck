import Foundation

// The full inventory-Sheet row (spec v2 §5.1) — the "Inventory" tab's schema, the
// database of record. v2 reaches this Sheet through the direct Google Sheets API
// over the user's own OAuth token (§5), so the app both READS it (into the local
// read-cache the gap-check/search core consumes) and WRITES it (append / set-qty /
// delete-at-0 via the reconciler in SheetSync.swift, §5.2).
//
// `OwnedCard` (Models.swift) is the 3 machine columns the gap-check needs; this is
// the whole row — human columns included — because appending a new printing has to
// write the person-facing columns too, and edits must preserve them.

/// One row of the inventory Sheet (spec §5.1). Human columns for the person,
/// machine columns for the app. The app locates a row by `cardId`, never by
/// position (§5.1) — so the person may hand-sort/filter the Sheet freely.
public struct InventoryRow: Equatable {
    public var name: String            // card name — denormalized for readability
    public var set: String             // set name, e.g. "Obsidian Flames"
    public var code: String?           // TCG Live set code — nullable; identity never depends on it
    public var number: String          // collector number
    public var qty: Int                // quantity owned of this printing (row deleted at 0)
    public var location: String?       // free-text physical-location aid — optional
    public var cardId: String          // canonical "<set>-<number>" (§3.4) — the stable row key
    public var equivalenceKey: String  // denormalized hash (§4)
    public var normVersion: String     // normalization version — bump → app re-resolve()s

    public init(name: String, set: String, code: String?, number: String, qty: Int,
                location: String?, cardId: String, equivalenceKey: String, normVersion: String) {
        self.name = name; self.set = set; self.code = code; self.number = number
        self.qty = qty; self.location = location; self.cardId = cardId
        self.equivalenceKey = equivalenceKey; self.normVersion = normVersion
    }

    /// The 3 machine columns the gap-check / search core consumes (§5.3 read-cache).
    /// A row at qty 0 shouldn't exist (it's deleted), so this is nil-guarded on qty.
    public var owned: OwnedCard? {
        qty > 0 ? OwnedCard(cardId: cardId, equivalenceKey: equivalenceKey, qty: qty) : nil
    }
}

/// The nine inventory columns (spec §5.1), each bound to its Sheet header string.
/// Header-driven, exactly like the existing gap-check inventory loader — so the
/// Sheet's *column order* may vary and the app still maps correctly.
public enum InventoryColumn: String, CaseIterable {
    case name          = "name"
    case set           = "set"
    case code          = "code"
    case number        = "number"
    case qty           = "qty"
    case location      = "location"
    case cardId        = "card_id"
    case equivalenceKey = "equivalence_key"
    case normVersion   = "norm_version"

    /// This column's value from a row, rendered as the Sheet cell string.
    public func cell(of row: InventoryRow) -> String {
        switch self {
        case .name:           return row.name
        case .set:            return row.set
        case .code:           return row.code ?? ""
        case .number:         return row.number
        case .qty:            return String(row.qty)
        case .location:       return row.location ?? ""
        case .cardId:         return row.cardId
        case .equivalenceKey: return row.equivalenceKey
        case .normVersion:    return row.normVersion
        }
    }
}

public extension InventoryRow {
    /// The canonical header order for a freshly-created "Inventory" tab (§8.2 onboarding).
    static var canonicalHeader: [String] { InventoryColumn.allCases.map(\.rawValue) }
}
