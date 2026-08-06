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

    func testMinWidthFloorsBothNumberAndTotalForASmallTotal() {
        // Carnivine, real card: number "4", total 86 — the on-card corner reads
        // "004/086", not "004/86". minWidth: 3 floors both to match.
        let carnivine = CatalogCard(cardId: "x-4", setId: "x", setName: "Small Set", ptcgoCode: "SML",
                                    number: "4", name: "Carnivine", supertype: .pokemon, equivalenceKey: "t",
                                    standardLegal: true, expandedLegal: true, printedTotal: 86)
        XCTAssertEqual(carnivine.designation(), "04/86")          // Mass Entry: total's own width
        XCTAssertEqual(carnivine.designation(minWidth: 3), "004/086") // on-card: floor of 3, both sides
    }

    func testNumberWiderThanTotalPadsTheTotalToMatch() {
        // A number with more digits than the total (a secret rare beyond the printed
        // count) pads the total up to the number's width too.
        let secret = CatalogCard(cardId: "x-150", setId: "x", setName: "Small Set", ptcgoCode: "SML",
                                 number: "150", name: "Test", supertype: .pokemon, equivalenceKey: "t",
                                 standardLegal: true, expandedLegal: true, printedTotal: 99)
        XCTAssertEqual(secret.designation(), "150/099")
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
