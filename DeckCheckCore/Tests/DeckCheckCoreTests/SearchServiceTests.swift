import XCTest
@testable import DeckCheckCore

final class SearchServiceTests: XCTestCase {
    let catalog = Fixture.catalog

    func testGroupsPrintingsByEquivalence() {
        let groups = SearchService.search(query: "Charizard", owned: [], catalog: catalog)
        XCTAssertEqual(groups.count, 1)
        let g = groups[0]
        XCTAssertEqual(g.name, "Charizard ex")
        XCTAssertEqual(g.equivalenceKey, "char")
        XCTAssertEqual(g.printings.count, 2)      // OBF + PAF, same key
    }

    func testPrintingsOrderedNewestFirst() {
        // Charizard ex: OBF (2023/08/11) + PAF (2024/01/26). The newer PAF printing
        // should lead the group and be the representative.
        let g = SearchService.search(query: "Charizard", owned: [], catalog: catalog)[0]
        XCTAssertEqual(g.printings.map(\.cardId), ["ptcg:paf-234", "ptcg:obf-125"])
        XCTAssertEqual(g.representative.cardId, "ptcg:paf-234")
    }

    func testUndatedPrintingSortsLast() {
        // A printing whose set carries no release date is treated as oldest.
        let dated = Fixture.charPAF
        let undated = CatalogCard(cardId: "ptcg:xxx-1", setId: "xxx", setName: "No Date",
            ptcgoCode: "XXX", number: "1", name: "Charizard ex", supertype: .pokemon,
            equivalenceKey: "char", standardLegal: true, expandedLegal: true)
        XCTAssertEqual([undated, dated].orderedNewestFirst().map(\.cardId),
                       [dated.cardId, undated.cardId])
    }

    func testUnownedShowsZeroNotEmpty() {
        // "do I have X" is answerable for cards you don't own — a definitive 0.
        let groups = SearchService.search(query: "Iono", owned: [], catalog: catalog)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].ownedCount, 0)
        XCTAssertTrue(groups[0].ownedPrintings.isEmpty)
    }

    func testOwnedCountAggregatesAcrossPrintings() {
        let owned = [
            OwnedCard(cardId: "ptcg:pal-185", equivalenceKey: "iono", qty: 2),
            OwnedCard(cardId: "ptcg:paf-237", equivalenceKey: "iono", qty: 1), // different printing, same key
        ]
        let g = SearchService.search(query: "Iono", owned: owned, catalog: catalog)[0]
        XCTAssertEqual(g.ownedCount, 3)                 // 2 + 1 across printings
        XCTAssertEqual(g.ownedPrintings.count, 2)
    }

    func testOwnedGroupsSurfaceFirst() {
        // Own Iono but not Charizard; search matches both by the "a" substring... use a
        // query that hits both names: search each and check ordering via a combined query.
        let owned = [OwnedCard(cardId: "ptcg:pal-185", equivalenceKey: "iono", qty: 1)]
        // "o" matches Iono and Boss's Orders (and Dup Mon has no 'o'? it does: "Dup Mon")
        let groups = SearchService.search(query: "o", owned: owned, catalog: catalog)
        XCTAssertGreaterThan(groups.count, 1)
        XCTAssertEqual(groups.first?.name, "Iono")      // the owned one is first
        XCTAssertGreaterThan(groups.first!.ownedCount, 0)
    }

    func testLegalityLensAnnotatesFormatLegal() {
        // Boss's Orders group: RCL not standard-legal, PAL is → group has a legal printing.
        let std = SearchService.search(query: "Boss", owned: [], catalog: catalog, lens: .standard)
        XCTAssertEqual(std[0].formatLegal, true)
        let none = SearchService.search(query: "Boss", owned: [], catalog: catalog)
        XCTAssertNil(none[0].formatLegal)               // no lens → nil
    }

    func testMatchesBySetCode() {
        // "MEE" is the energy set's code — no name term at all.
        XCTAssertEqual(SearchService.search(query: "MEE", owned: [], catalog: catalog).map(\.name),
                       ["Fire Energy"])
    }

    func testMatchesBySetName() {
        // "mega evolution" — two tokens, both matching the set name. The fixture holds
        // two sets that start that way ("Mega Evolution" / "Mega Evolution Energy",
        // which is the real-world pairing), and tokens match as substrings, so both
        // come back — ordered by card name.
        XCTAssertEqual(SearchService.search(query: "mega evolution", owned: [], catalog: catalog).map(\.name),
                       ["Fire Energy", "Ralts"])
    }

    func testExtraTokenNarrowsAcrossSimilarSetNames() {
        // ...and one more token narrows it: only Ralts is #5.
        XCTAssertEqual(SearchService.search(query: "mega evolution 5", owned: [], catalog: catalog).map(\.name),
                       ["Ralts"])
    }

    func testNamePlusNumberNarrowsToPrinting() {
        // "Charizard 125" → only the OBF printing, not PAF.
        let g = SearchService.search(query: "Charizard 125", owned: [], catalog: catalog)
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g[0].printings.map(\.cardId), ["ptcg:obf-125"])
    }

    func testNamePlusSetCodeNarrowsToPrinting() {
        let g = SearchService.search(query: "charizard paf", owned: [], catalog: catalog)
        XCTAssertEqual(g[0].printings.map(\.cardId), ["ptcg:paf-234"])
    }

    func testFullNumberSlashTotal() {
        // "125/197" matches the combined number/printedTotal field.
        let g = SearchService.search(query: "125/197", owned: [], catalog: catalog)
        XCTAssertEqual(g.flatMap { $0.printings.map(\.cardId) }, ["ptcg:obf-125"])
    }

    func testAllTokensMustMatch() {
        // A term that matches nothing on the card kills the match.
        XCTAssertTrue(SearchService.search(query: "charizard zzzz", owned: [], catalog: catalog).isEmpty)
    }

    func testGroupOrderNewestFirst() {
        // The scan picker order: groups sort by their (newest) representative's release
        // date, descending — Charizard (Jan 2024) before Boss's Orders (Jun 2023)
        // before Ralts (undated, last). "r" matches all three by name.
        let names = SearchService.search(query: "r", owned: [], catalog: catalog,
                                         order: .ownedThenNewest).map(\.name)
        XCTAssertLessThan(names.firstIndex(of: "Charizard ex")!, names.firstIndex(of: "Boss's Orders")!)
        XCTAssertLessThan(names.firstIndex(of: "Boss's Orders")!, names.firstIndex(of: "Ralts")!)
    }

    func testDefaultGroupOrderStaysAlphabetical() {
        // Cards-tab default is unchanged: A→Z (Boss's Orders before Charizard).
        let names = SearchService.search(query: "r", owned: [], catalog: catalog).map(\.name)
        XCTAssertLessThan(names.firstIndex(of: "Boss's Orders")!, names.firstIndex(of: "Charizard ex")!)
    }

    func testEmptyQueryReturnsNothing() {
        XCTAssertTrue(SearchService.search(query: "   ", owned: [], catalog: catalog).isEmpty)
    }

    func testMaxGroupsCap() {
        let groups = SearchService.search(query: "", owned: [], catalog: catalog, maxGroups: 1)
        XCTAssertTrue(groups.isEmpty) // empty query short-circuits before the cap
        let capped = SearchService.search(query: "o", owned: [], catalog: catalog, maxGroups: 1)
        XCTAssertLessThanOrEqual(capped.count, 1)
    }
}
