import XCTest
@testable import DeckCheckCore

final class TCGplayerExportTests: XCTestCase {
    let catalog = Fixture.catalog

    func testExportHasMissingFullAndShortDeltaOnly() {
        let deck = """
        4 Charizard ex OBF 125
        4 Iono PAL 185
        3 Boss's Orders PAL 172
        """
        let owned = [
            OwnedCard(cardId: "ptcg:obf-125", equivalenceKey: "char", qty: 4), // have → excluded
            OwnedCard(cardId: "ptcg:pal-185", equivalenceKey: "iono", qty: 1), // short 3
            // Boss's Orders missing → full 3
        ]
        let r = GapChecker.check(decklist: deck, owned: owned, catalog: catalog)
        let text = TCGplayerExport.massEntry(r)
        let lines = text.split(separator: "\n").map(String.init)

        // <qty> <name> [<code>] <number>/<total>
        XCTAssertTrue(lines.contains("3 Boss's Orders [PAL] 172/193")) // missing, full qty
        XCTAssertTrue(lines.contains("3 Iono [PAL] 185/193"))          // short, delta only
        XCTAssertFalse(text.contains("Charizard"))                     // have → not in buy list
        XCTAssertEqual(lines.count, 2)
    }

    func testMassEntryPadsNumberToPrintedTotalWidth() {
        // Ralts: stored number "5", printed total 132 → "005/132" (the accepted format).
        let r = GapChecker.check(decklist: "1 Ralts MEG 5", owned: [], catalog: catalog)
        XCTAssertEqual(TCGplayerExport.massEntry(r), "1 Ralts [MEG] 005/132")
    }

    func testDifferentPrintingSatisfiedIsExcludedFromBuyList() {
        // Deck wants OBF Charizard; we own the PAF printing (same key) → already owned.
        let deck = "2 Charizard ex OBF 125"
        let owned = [OwnedCard(cardId: "ptcg:paf-234", equivalenceKey: "char", qty: 2)]
        let r = GapChecker.check(decklist: deck, owned: owned, catalog: catalog)
        XCTAssertEqual(TCGplayerExport.massEntry(r), "") // nothing to buy
    }

    func testSearchURLForCardName() {
        let url = try! XCTUnwrap(TCGplayerExport.searchURL(cardName: "Charizard ex"))
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(comps.host, "www.tcgplayer.com")
        let items = Dictionary(uniqueKeysWithValues: comps.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["q"], "Charizard ex")
        XCTAssertNil(TCGplayerExport.searchURL(cardName: "   "))
    }

    func testSearchURLNarrowsToSpecificPrinting() {
        // Set name + number make it a specific-printing lookup, not a name search.
        let url = try! XCTUnwrap(TCGplayerExport.searchURL(
            cardName: "Charizard ex", setName: "Obsidian Flames", number: "125"))
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let q = comps.queryItems!.first { $0.name == "q" }?.value
        XCTAssertEqual(q, "Charizard ex Obsidian Flames 125")
    }

    func testSearchURLSkipsEmptyDesignationTerms() {
        // A promo with no set name still narrows by whatever's present (code + number).
        let url = try! XCTUnwrap(TCGplayerExport.searchURL(
            cardName: "Ampharos", setName: "  ", number: "075"))
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.first { $0.name == "q" }?.value
        XCTAssertEqual(q, "Ampharos 075")
    }
}
