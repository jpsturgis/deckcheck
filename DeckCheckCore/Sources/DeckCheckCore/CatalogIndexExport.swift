import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// The slim catalog "resolution index" for in-browser/app-closed gap-check
// When the user opts in, the app pushes this narrow table into
// a hidden `Catalog` tab in *their own* sheet so a container-bound Apps Script can
// resolve decklist lines with the app closed. It is a resolution index, NOT the
// catalog: only the seven columns the gap-check engine reads (gapcheck.gs
// `buildCatalogIndex`) — no HP, attacks, images, printed metadata. Same row set as
// the local catalog (you must resolve cards you don't own, to show them as gaps),
// just far fewer columns, which keeps the browser onEdit read fast and the sheet lean.
//
// The seven columns and their order MUST stay in lockstep with `CATALOG_COLUMNS`
// in the bundled bound script (Resources/Code.gs) and Code.gs.
// ─────────────────────────────────────────────────────────────────────────────

public enum CatalogIndexExport {
    /// The `Catalog` tab header, in column order — matches gapcheck.js's row shape
    /// `{ card_id, name, set_name, code, number, printed_total, equivalence_key }`.
    public static let header = [
        "card_id", "name", "set_name", "code", "number", "printed_total", "equivalence_key",
    ]

    /// One index row per catalog card, in `header` column order. All cells are plain
    /// strings; a nil `printedTotal`/`ptcgoCode` becomes "". Cards with an empty
    /// `equivalenceKey` are skipped — the engine can't resolve against them and would
    /// drop them anyway (readCatalogRows filters empty keys).
    public static func rows(_ cards: [CatalogCard]) -> [[String]] {
        cards.compactMap { c in
            guard !c.equivalenceKey.isEmpty else { return nil }
            return [
                c.cardId,
                c.name,
                c.setName,
                c.ptcgoCode ?? "",
                c.number,
                c.printedTotal.map(String.init) ?? "",
                c.equivalenceKey,
            ]
        }
    }

    /// Header row followed by every index row — the full value block for the tab.
    public static func valueBlock(_ cards: [CatalogCard]) -> [[String]] {
        [header] + rows(cards)
    }
}
