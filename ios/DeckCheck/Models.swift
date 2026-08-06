import Foundation
import DeckCheckCore

// Value types for the Google Sheet ↔ app boundary: the read-cache row
// (InventoryRow) and a pending outbox mutation (OutboxOp). The Sheets API read is
// mapped into these in GoogleSheetsService.

/// One inventory row as the Sheet stores it — the local read-cache element.
///
/// Google Sheets silently stores numeric-looking cells as *numbers*, so `doGet` can
/// return `number`, `code`, etc. as JSON numbers rather than strings. Decoding is
/// therefore tolerant: every text field accepts a string OR a number and coerces to
/// String, and `qty` accepts either. (Encoding — for the on-disk cache — is the plain
/// synthesized form.)
struct InventoryRow: Codable, Identifiable, Equatable {
    var card_id: String
    var name: String
    var set: String
    var code: String
    var number: String
    var qty: Int
    var location: String
    var equivalence_key: String
    var norm_version: String
    var id: String { card_id }

    enum CodingKeys: String, CodingKey {
        case card_id, name, set, code, number, qty, location, equivalence_key, norm_version
    }

    /// Memberwise init (the custom `init(from:)` suppresses the synthesized one) —
    /// used to build read-cache rows from the v2 Sheets `SheetTable`.
    init(card_id: String, name: String, set: String, code: String, number: String,
         qty: Int, location: String, equivalence_key: String, norm_version: String) {
        self.card_id = card_id; self.name = name; self.set = set; self.code = code
        self.number = number; self.qty = qty; self.location = location
        self.equivalence_key = equivalence_key; self.norm_version = norm_version
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        card_id = Self.string(c, .card_id)
        name = Self.string(c, .name)
        set = Self.string(c, .set)
        code = Self.string(c, .code)
        number = Self.string(c, .number)
        location = Self.string(c, .location)
        equivalence_key = Self.string(c, .equivalence_key)
        norm_version = Self.string(c, .norm_version)
        qty = Self.int(c, .qty)
    }

    /// Decode a cell as String whether the JSON has a string or a number.
    private static func string(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String {
        if let s = try? c.decode(String.self, forKey: key) { return s }
        if let i = try? c.decode(Int.self, forKey: key) { return String(i) }
        if let d = try? c.decode(Double.self, forKey: key) {
            return d == d.rounded() ? String(Int(d)) : String(d) // 125.0 → "125"
        }
        if let b = try? c.decode(Bool.self, forKey: key) { return String(b) }
        return ""
    }

    private static func int(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int {
        if let i = try? c.decode(Int.self, forKey: key) { return i }
        if let d = try? c.decode(Double.self, forKey: key) { return Int(d) }
        if let s = try? c.decode(String.self, forKey: key) { return Int(s) ?? 0 }
        return 0
    }
}

/// A pending mutation in the durable outbox, also the doPost op shape.
/// `id` is a client-generated id echoed in the doPost result so an entry leaves the
/// outbox only once its write is acknowledged.
struct OutboxOp: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case intake, removal }
    var id: String
    var op: Kind
    var card_id: String
    var name: String = ""
    var set: String = ""
    var code: String = ""
    var number: String = ""
    var location: String = ""
    var equivalence_key: String = ""
    var norm_version: String = ""
}

extension Array where Element == InventoryRow {
    /// Map the read-cache to the engines' owned-copy view.
    var ownedCards: [OwnedCard] {
        map { OwnedCard(cardId: $0.card_id, equivalenceKey: $0.equivalence_key, qty: $0.qty) }
    }

    /// Map the read-cache to the engines' full owned-row view — `SearchService
    /// .ownedGroups`'s input. Same facts, Core's field names and optionality
    /// (blank strings become `nil`).
    var asCoreRows: [DeckCheckCore.InventoryRow] {
        map {
            DeckCheckCore.InventoryRow(
                name: $0.name, set: $0.set, code: $0.code.isEmpty ? nil : $0.code,
                number: $0.number, qty: $0.qty, location: $0.location.isEmpty ? nil : $0.location,
                cardId: $0.card_id, equivalenceKey: $0.equivalence_key, normVersion: $0.norm_version)
        }
    }
}
