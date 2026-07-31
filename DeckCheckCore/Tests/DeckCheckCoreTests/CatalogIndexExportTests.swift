import XCTest
@testable import DeckCheckCore

final class CatalogIndexExportTests: XCTestCase {
    func card(_ id: String, _ name: String, set: String, code: String?, number: String,
              printedTotal: Int?, key: String) -> CatalogCard {
        CatalogCard(cardId: id, setId: "s", setName: set, ptcgoCode: code, number: number,
                    name: name, supertype: .pokemon, equivalenceKey: key,
                    standardLegal: true, expandedLegal: true, printedTotal: printedTotal)
    }

    func testHeaderMatchesEngineSchema() {
        // MUST equal gapcheck.gs buildCatalogIndex's row shape / Code.gs CATALOG_COLUMNS.
        XCTAssertEqual(CatalogIndexExport.header,
                       ["card_id", "name", "set_name", "code", "number", "printed_total", "equivalence_key"])
    }

    func testRowMapsFieldsInColumnOrder() {
        let rows = CatalogIndexExport.rows([
            card("ptcg:obf-125", "Charizard ex", set: "Obsidian Flames", code: "OBF",
                 number: "125", printedTotal: 197, key: "char"),
        ])
        XCTAssertEqual(rows, [["ptcg:obf-125", "Charizard ex", "Obsidian Flames", "OBF", "125", "197", "char"]])
    }

    func testNilCodeAndPrintedTotalBecomeEmptyStrings() {
        let rows = CatalogIndexExport.rows([
            card("manual:promo", "Pikachu", set: "", code: nil, number: "1", printedTotal: nil, key: "pika"),
        ])
        XCTAssertEqual(rows, [["manual:promo", "Pikachu", "", "", "1", "", "pika"]])
    }

    func testRowsWithEmptyEquivalenceKeyAreDropped() {
        let rows = CatalogIndexExport.rows([
            card("a", "A", set: "S", code: "S", number: "1", printedTotal: 10, key: ""),
            card("b", "B", set: "S", code: "S", number: "2", printedTotal: 10, key: "k"),
        ])
        XCTAssertEqual(rows.map { $0[0] }, ["b"])
    }

    func testValueBlockPrependsHeader() {
        let block = CatalogIndexExport.valueBlock([
            card("b", "B", set: "S", code: "S", number: "2", printedTotal: 10, key: "k"),
        ])
        XCTAssertEqual(block.first, CatalogIndexExport.header)
        XCTAssertEqual(block.count, 2)
    }
}
