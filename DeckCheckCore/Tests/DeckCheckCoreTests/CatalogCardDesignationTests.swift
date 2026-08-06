import XCTest
@testable import DeckCheckCore

/// `CatalogCard.designation(minWidth:)` — the shared zero-pad rule behind both
/// `TCGplayerExport`'s Mass Entry format (`minWidth: 0`, the default) and the
/// printed-card display convention CardsView/SetDetailView use (`minWidth: 3`).
final class CatalogCardDesignationTests: XCTestCase {
    func testDefaultMinWidthMatchesPrintedTotalWidth() {
        // Ralts: number "5", total 132 → padded to the total's own width (3).
        XCTAssertEqual(Fixture.ralts.designation(), "005/132")
    }

    func testMinWidthFloorsTheNumberEvenForASmallTotal() {
        let small = CatalogCard(cardId: "x-5", setId: "x", setName: "Small Set", ptcgoCode: "SML",
                                number: "5", name: "Test", supertype: .pokemon, equivalenceKey: "t",
                                standardLegal: true, expandedLegal: true, printedTotal: 25)
        XCTAssertEqual(small.designation(), "05/25")          // Mass Entry: total's own width
        XCTAssertEqual(small.designation(minWidth: 3), "005/25") // on-card: floor of 3
    }

    func testTotalIsNeverPaddedOnlyTheNumberIs() {
        // A number with more digits than the total (a secret rare beyond the printed
        // count) pads to the number's width — the total prints exactly as stored.
        let secret = CatalogCard(cardId: "x-150", setId: "x", setName: "Small Set", ptcgoCode: "SML",
                                 number: "150", name: "Test", supertype: .pokemon, equivalenceKey: "t",
                                 standardLegal: true, expandedLegal: true, printedTotal: 99)
        XCTAssertEqual(secret.designation(), "150/99")
    }

    func testZeroTotalPassesNumberThroughUnchanged() {
        let promo = CatalogCard(cardId: "mep-5", setId: "mep", setName: "Promos", ptcgoCode: "MEP",
                                number: "5", name: "Test", supertype: .pokemon, equivalenceKey: "t",
                                standardLegal: true, expandedLegal: true, printedTotal: 0)
        XCTAssertEqual(promo.designation(), "5")
        XCTAssertEqual(promo.designation(minWidth: 3), "5") // no total → minWidth doesn't apply
    }

    func testNonNumericNumberPassesThroughUnchanged() {
        let gallery = CatalogCard(cardId: "x-tg01", setId: "x", setName: "Trainer Gallery",
                                  ptcgoCode: "TG", number: "TG01", name: "Test", supertype: .pokemon,
                                  equivalenceKey: "t", standardLegal: true, expandedLegal: true,
                                  printedTotal: 30)
        XCTAssertEqual(gallery.designation(minWidth: 3), "TG01")
    }
}
