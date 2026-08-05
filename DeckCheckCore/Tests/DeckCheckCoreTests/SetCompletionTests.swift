import XCTest
@testable import DeckCheckCore

final class SetCompletionTests: XCTestCase {

    // A four-card set, plus a two-card set released earlier, plus a rotated set.
    private enum Sets {
        static func card(_ setId: String, _ n: String, key: String, standard: Bool = true,
                         released: String? = "2024/11/08", name: String? = nil) -> CatalogCard {
            CatalogCard(cardId: "ptcg:\(setId)-\(n)", setId: setId, setName: setId.uppercased(),
                        ptcgoCode: setId.uppercased(), number: n, name: name ?? "Card \(n)",
                        supertype: .pokemon, equivalenceKey: key,
                        standardLegal: standard, expandedLegal: true,
                        printedTotal: 4, releaseDate: released)
        }

        // "ssp" — 4 cards, current.
        static let ssp1 = card("ssp", "1", key: "k-pikachu")
        static let ssp2 = card("ssp", "2", key: "k-iono")
        static let ssp3 = card("ssp", "3", key: "k-boss")
        static let ssp4 = card("ssp", "4", key: "k-candy")

        // "scr" — 2 cards, older. ONE of them is a reprint of ssp2 (same key).
        static let scr1 = card("scr", "1", key: "k-iono", released: "2024/09/13")
        static let scr2 = card("scr", "2", key: "k-rare", released: "2024/09/13")

        // "old" — rotated out of Standard.
        static let old1 = card("old", "1", key: "k-old", standard: false, released: "2019/01/01")

        static let catalog = FakeCatalog(all: [ssp1, ssp2, ssp3, ssp4, scr1, scr2, old1])
    }

    private func owned(_ cards: [CatalogCard], qty: Int = 1) -> [OwnedCard] {
        cards.map { OwnedCard(cardId: $0.cardId, equivalenceKey: $0.equivalenceKey, qty: qty) }
    }

    func testCountsDistinctPrintingsOwnedPerSet() {
        let progress = SetCompletion.progress(
            owned: owned([Sets.ssp1, Sets.ssp3]), catalog: Sets.catalog)

        let ssp = try! XCTUnwrap(progress.first { $0.setId == "ssp" })
        XCTAssertEqual(ssp.ownedCount, 2)
        XCTAssertEqual(ssp.totalCount, 4)
        XCTAssertEqual(ssp.missingCount, 2)
        XCTAssertEqual(ssp.fraction, 0.5, accuracy: 0.0001)
        XCTAssertFalse(ssp.isComplete)
    }

    /// The point of the whole type: everywhere else in the app a reprint counts as the
    /// card it plays as. A binder page does not work that way.
    func testAReprintDoesNotCompleteTheOtherSet() {
        // Own only the SCR printing of Iono. It shares an equivalence key with SSP 2.
        let progress = SetCompletion.progress(owned: owned([Sets.scr1]), catalog: Sets.catalog)

        let ssp = try! XCTUnwrap(progress.first { $0.setId == "ssp" })
        XCTAssertEqual(ssp.ownedCount, 0, "owning the SCR reprint must not fill the SSP slot")

        let scr = try! XCTUnwrap(progress.first { $0.setId == "scr" })
        XCTAssertEqual(scr.ownedCount, 1)
    }

    func testQuantityZeroDoesNotCountAsOwned() {
        // A row that fell to zero stays in the Sheet; it isn't a card you have.
        let rows = owned([Sets.ssp1, Sets.ssp2], qty: 0)
        let progress = SetCompletion.progress(owned: rows, catalog: Sets.catalog)
        XCTAssertEqual(progress.first { $0.setId == "ssp" }?.ownedCount, 0)
    }

    func testDuplicateCopiesOfOnePrintingCountOnce() {
        let rows = [OwnedCard(cardId: Sets.ssp1.cardId, equivalenceKey: "k-pikachu", qty: 4)]
        let progress = SetCompletion.progress(owned: rows, catalog: Sets.catalog)
        XCTAssertEqual(progress.first { $0.setId == "ssp" }?.ownedCount, 1)
    }

    func testCompleteSetReportsComplete() {
        let all = owned([Sets.ssp1, Sets.ssp2, Sets.ssp3, Sets.ssp4])
        let ssp = try! XCTUnwrap(
            SetCompletion.progress(owned: all, catalog: Sets.catalog).first { $0.setId == "ssp" })
        XCTAssertTrue(ssp.isComplete)
        XCTAssertEqual(ssp.missingCount, 0)
        XCTAssertEqual(ssp.fraction, 1.0, accuracy: 0.0001)
    }

    func testMissingListsUnownedPrintingsInNumberOrder() {
        let missing = SetCompletion.missing(
            inSet: "ssp", owned: owned([Sets.ssp2]), catalog: Sets.catalog)
        XCTAssertEqual(missing.map(\.number), ["1", "3", "4"])
    }

    func testMissingIsEmptyForACompleteSet() {
        let all = owned([Sets.ssp1, Sets.ssp2, Sets.ssp3, Sets.ssp4])
        XCTAssertTrue(SetCompletion.missing(inSet: "ssp", owned: all, catalog: Sets.catalog).isEmpty)
    }

    func testSetsSortNewestFirst() {
        let progress = SetCompletion.progress(owned: [], catalog: Sets.catalog)
        XCTAssertEqual(progress.map(\.setId), ["ssp", "scr", "old"])
    }

    func testStandardLensHidesRotatedSetsButNotCountsWithinASet() {
        let all = SetCompletion.progress(owned: owned([Sets.ssp1]), catalog: Sets.catalog)
        XCTAssertTrue(all.contains { $0.setId == "old" })

        let standard = SetCompletion.progress(
            owned: owned([Sets.ssp1]), catalog: Sets.catalog, lens: .standard)
        XCTAssertFalse(standard.contains { $0.setId == "old" })
        // The lens filters sets, not the cards inside one.
        XCTAssertEqual(standard.first { $0.setId == "ssp" }?.totalCount, 4)
    }

    func testProgressForASingleSet() {
        let one = SetCompletion.progress(
            forSet: "scr", owned: owned([Sets.scr2]), catalog: Sets.catalog)
        XCTAssertEqual(one?.ownedCount, 1)
        XCTAssertEqual(one?.totalCount, 2)
        XCTAssertNil(SetCompletion.progress(forSet: "nope", owned: [], catalog: Sets.catalog))
    }

    func testEmptyCollectionIsZeroEverywhereNotADivideByZero() {
        for p in SetCompletion.progress(owned: [], catalog: Sets.catalog) {
            XCTAssertEqual(p.ownedCount, 0)
            XCTAssertEqual(p.fraction, 0)
            XCTAssertFalse(p.isComplete)
        }
    }

    /// A promo row carries a `manual:` card id that's in nobody's set. It must be
    /// ignored rather than counted against some set's total.
    func testManualPromoRowsAreIgnored() {
        let promo = OwnedCard(cardId: "manual:whatever", equivalenceKey: "k-iono", qty: 2)
        let progress = SetCompletion.progress(owned: [promo], catalog: Sets.catalog)
        XCTAssertTrue(progress.allSatisfy { $0.ownedCount == 0 })
    }
}
