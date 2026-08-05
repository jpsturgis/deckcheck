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

    /// The set-completion buy list goes through the same formatter as the gap report,
    /// so the padding rules can't drift between the two.
    func testMassEntryFromACardListPadsTheSameWayAsAReport() {
        let out = TCGplayerExport.massEntry([
            (quantity: 1, card: Fixture.ralts),      // number 5, printed total 132
            (quantity: 2, card: Fixture.ionoPAL),    // number 185, printed total 193
        ])
        XCTAssertEqual(out, """
        1 Ralts [MEG] 005/132
        2 Iono [PAL] 185/193
        """)
    }

    func testMassEntryFromACardListDropsNonPositiveQuantities() {
        let out = TCGplayerExport.massEntry([
            (quantity: 0, card: Fixture.ralts),
            (quantity: 1, card: Fixture.ionoPAL),
        ])
        XCTAssertEqual(out, "1 Iono [PAL] 185/193")
    }

    func testMassEntryFromAnEmptyListIsEmpty() {
        XCTAssertEqual(TCGplayerExport.massEntry([]), "")
    }

    /// Promo sets carry `printed_total = 0` — a black star promo prints its number with
    /// no "/total" at all. Treating that as a real total emitted "5/0", which Mass Entry
    /// can't match against anything.
    func testAZeroPrintedTotalIsTreatedAsNoTotal() {
        let promo = CatalogCard(cardId: "mep-5", setId: "mep", setName: "MEP Black Star Promos",
                                ptcgoCode: "MEP", number: "5", name: "Pikachu", supertype: .pokemon,
                                equivalenceKey: "pika", standardLegal: true, expandedLegal: true,
                                printedTotal: 0)
        XCTAssertEqual(TCGplayerExport.massEntry([(quantity: 1, card: promo)]),
                       "1 Pikachu [MEP] 5")
    }

    func testANilPrintedTotalIsAlsoTreatedAsNoTotal() {
        let noTotal = CatalogCard(cardId: "x-5", setId: "x", setName: "X", ptcgoCode: "XXX",
                                  number: "5", name: "Mystery", supertype: .pokemon,
                                  equivalenceKey: "m", standardLegal: true, expandedLegal: true,
                                  printedTotal: nil)
        XCTAssertEqual(TCGplayerExport.massEntry([(quantity: 1, card: noTotal)]),
                       "1 Mystery [XXX] 5")
    }
}
