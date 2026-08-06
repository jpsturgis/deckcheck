import XCTest
@testable import DeckCheckCore

final class OwnedGroupsTests: XCTestCase {
    let catalog = Fixture.catalog

    private func row(name: String, set: String = "", code: String? = nil, number: String = "",
                     qty: Int, location: String? = nil, cardId: String, equivalenceKey: String) -> InventoryRow {
        InventoryRow(name: name, set: set, code: code, number: number, qty: qty, location: location,
                    cardId: cardId, equivalenceKey: equivalenceKey, normVersion: "v1")
    }

    func testGroupsRowsByEquivalenceKey() {
        let rows = [
            row(name: "Iono", set: "Paldea Evolved", number: "185", qty: 2,
                cardId: Fixture.ionoPAL.cardId, equivalenceKey: "iono"),
            row(name: "Iono", set: "Paldean Fates", number: "237", qty: 1,
                cardId: Fixture.ionoPAF.cardId, equivalenceKey: "iono"),
        ]
        let resolved = [Fixture.ionoPAL.cardId: Fixture.ionoPAL, Fixture.ionoPAF.cardId: Fixture.ionoPAF]
        let groups = SearchService.ownedGroups(query: "", rows: rows, resolved: resolved, catalog: catalog)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].equivalenceKey, "iono")
        XCTAssertEqual(groups[0].ownedCount, 3)          // 2 + 1 across printings
        XCTAssertEqual(groups[0].printings.count, 2)
    }

    func testPrintingsOrderedNewestFirst() {
        // PAF (2024/01/26) is newer than PAL (2023/06/09).
        let rows = [
            row(name: "Iono", set: "Paldea Evolved", number: "185", qty: 1,
                cardId: Fixture.ionoPAL.cardId, equivalenceKey: "iono"),
            row(name: "Iono", set: "Paldean Fates", number: "237", qty: 1,
                cardId: Fixture.ionoPAF.cardId, equivalenceKey: "iono"),
        ]
        let resolved = [Fixture.ionoPAL.cardId: Fixture.ionoPAL, Fixture.ionoPAF.cardId: Fixture.ionoPAF]
        let groups = SearchService.ownedGroups(query: "", rows: rows, resolved: resolved, catalog: catalog)
        XCTAssertEqual(groups[0].printings.map(\.row.cardId), [Fixture.ionoPAF.cardId, Fixture.ionoPAL.cardId])
    }

    func testUncatalogedPromoStillAppearsGroupedByEquivalenceKey() {
        // A hand-entered promo has no CatalogCard of its own — `resolved` has nothing
        // for its cardId — but it must still show up, grouped with the real printing
        // it plays as.
        let promoId = "manual:mep-en-075"
        let rows = [
            row(name: "Iono", set: "Paldea Evolved", number: "185", qty: 1,
                cardId: Fixture.ionoPAL.cardId, equivalenceKey: "iono"),
            row(name: "Iono", set: "", code: "MEP", number: "075", qty: 1,
                cardId: promoId, equivalenceKey: "iono"),
        ]
        let resolved = [Fixture.ionoPAL.cardId: Fixture.ionoPAL] // promo intentionally unresolved
        let groups = SearchService.ownedGroups(query: "", rows: rows, resolved: resolved, catalog: catalog)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].ownedCount, 2)
        // Undated (no resolved card) sorts behind the dated PAL printing.
        XCTAssertEqual(groups[0].printings.map(\.row.cardId), [Fixture.ionoPAL.cardId, promoId])
        XCTAssertNil(groups[0].printings[1].card)
    }

    func testLensSurvivesViaEquivalenceGroupWhenPromoHasNoOwnCard() {
        // The promo's own card is unresolved, so its legality can't be read directly —
        // it must be judged by whether *any* printing in its equivalence group is legal.
        let promoId = "manual:mep-en-075"
        let rows = [row(name: "Iono", qty: 1, cardId: promoId, equivalenceKey: "iono")]
        let groups = SearchService.ownedGroups(query: "", rows: rows, resolved: [:],
                                               catalog: catalog, lens: .standard)
        XCTAssertEqual(groups.count, 1) // iono's PAL/PAF printings are standard-legal
    }

    func testLensDropsGroupWithNoLegalPrinting() {
        // Boss's Orders RCL alone (not PAL) is not standard-legal, and there's no other
        // printing in the group to fall back to.
        let rows = [row(name: "Boss's Orders", qty: 1, cardId: Fixture.bossRCL.cardId, equivalenceKey: "boss")]
        let resolved = [Fixture.bossRCL.cardId: Fixture.bossRCL]
        let groups = SearchService.ownedGroups(query: "", rows: rows, resolved: resolved,
                                               catalog: catalog, lens: .standard)
        XCTAssertTrue(groups.isEmpty)
    }

    func testNilCatalogWithLensFiltersEverything() {
        // Pre-existing edge case, pinned: no catalog + a lens active means legality
        // can't be established for anything, so every group is dropped. `resolved` is
        // empty too — the caller always derives it from the same catalog it passes
        // here, so a nil catalog means an empty resolution as well.
        let rows = [row(name: "Iono", qty: 1, cardId: Fixture.ionoPAL.cardId, equivalenceKey: "iono")]
        let groups = SearchService.ownedGroups(query: "", rows: rows, resolved: [:],
                                               catalog: nil, lens: .standard)
        XCTAssertTrue(groups.isEmpty)
    }

    func testQueryFiltersByRowName() {
        let rows = [
            row(name: "Iono", qty: 1, cardId: Fixture.ionoPAL.cardId, equivalenceKey: "iono"),
            row(name: "Charizard ex", qty: 1, cardId: Fixture.charOBF.cardId, equivalenceKey: "char"),
        ]
        let resolved = [Fixture.ionoPAL.cardId: Fixture.ionoPAL, Fixture.charOBF.cardId: Fixture.charOBF]
        let groups = SearchService.ownedGroups(query: "char", rows: rows, resolved: resolved, catalog: catalog)
        XCTAssertEqual(groups.map(\.name), ["Charizard ex"])
    }

    func testGroupsSortAlphabetically() {
        let rows = [
            row(name: "Iono", qty: 1, cardId: Fixture.ionoPAL.cardId, equivalenceKey: "iono"),
            row(name: "Charizard ex", qty: 1, cardId: Fixture.charOBF.cardId, equivalenceKey: "char"),
        ]
        let resolved = [Fixture.ionoPAL.cardId: Fixture.ionoPAL, Fixture.charOBF.cardId: Fixture.charOBF]
        let groups = SearchService.ownedGroups(query: "", rows: rows, resolved: resolved, catalog: catalog)
        XCTAssertEqual(groups.map(\.name), ["Charizard ex", "Iono"])
    }

    func testZeroQtyRowsAreExcluded() {
        let rows = [row(name: "Iono", qty: 0, cardId: Fixture.ionoPAL.cardId, equivalenceKey: "iono")]
        let groups = SearchService.ownedGroups(query: "", rows: rows, resolved: [:], catalog: catalog)
        XCTAssertTrue(groups.isEmpty)
    }
}
