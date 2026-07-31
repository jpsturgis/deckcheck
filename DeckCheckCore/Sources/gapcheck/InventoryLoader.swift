import Foundation
import DeckCheckCore

/// Loads owned inventory for the gap-check from either shape the project produces:
///   • the Apps Script `doGet` JSON (`{ "inventory": [ {card_id, equivalence_key, qty}, … ] }`)
///   • a CSV export of the inventory Sheet (header row with those columns)
///
/// `equivalence_key` may be blank — we fill it from the catalog by `card_id` — so a
/// bare `card_id,qty` inventory works too.
enum InventoryLoader {
    struct RawRow { var cardId: String; var equivalenceKey: String; var qty: Int }

    static func load(path: String, catalog: CatalogLookup) throws -> [OwnedCard] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let raws = trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
            ? try parseJSON(trimmed)
            : parseCSV(text)

        return raws.compactMap { r in
            let key = r.equivalenceKey.isEmpty
                ? (catalog.card(byId: r.cardId)?.equivalenceKey ?? "")
                : r.equivalenceKey
            guard !key.isEmpty, r.qty > 0 else { return nil }
            return OwnedCard(cardId: r.cardId, equivalenceKey: key, qty: r.qty)
        }
    }

    // MARK: JSON (doGet shape, tolerant of qty as number-or-string)

    private static func parseJSON(_ text: String) throws -> [RawRow] {
        let data = Data(text.utf8)
        let obj = try JSONSerialization.jsonObject(with: data)
        let array: [Any]
        if let dict = obj as? [String: Any], let inv = dict["inventory"] as? [Any] {
            array = inv
        } else if let arr = obj as? [Any] {
            array = arr
        } else {
            throw CLIError.badInventory("JSON is not an inventory array or {inventory: [...]}")
        }
        return array.compactMap { item in
            guard let row = item as? [String: Any] else { return nil }
            let cardId = string(row["card_id"])
            guard !cardId.isEmpty else { return nil }
            return RawRow(cardId: cardId,
                          equivalenceKey: string(row["equivalence_key"]),
                          qty: intValue(row["qty"]))
        }
    }

    // MARK: CSV (the card_id/equivalence_key/qty columns never contain commas)

    private static func parseCSV(_ text: String) -> [RawRow] {
        var lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty else { return [] }
        let header = lines.removeFirst().split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard let idIdx = header.firstIndex(of: "card_id"),
              let qtyIdx = header.firstIndex(of: "qty") else { return [] }
        let keyIdx = header.firstIndex(of: "equivalence_key")

        return lines.compactMap { line in
            let cols = line.split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard idIdx < cols.count, qtyIdx < cols.count else { return nil }
            let cardId = cols[idIdx]
            guard !cardId.isEmpty else { return nil }
            let key = (keyIdx.flatMap { $0 < cols.count ? cols[$0] : nil }) ?? ""
            return RawRow(cardId: cardId, equivalenceKey: key, qty: Int(cols[qtyIdx]) ?? 0)
        }
    }

    // MARK: helpers

    private static func string(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }
    private static func intValue(_ v: Any?) -> Int {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) ?? 0 }
        return 0
    }
}
