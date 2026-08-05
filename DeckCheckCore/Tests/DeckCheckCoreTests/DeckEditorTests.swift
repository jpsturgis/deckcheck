import XCTest
@testable import DeckCheckCore

final class DeckEditorTests: XCTestCase {
    private let catalog = Fixture.catalog

    /// A tab as someone actually keeps it: headers, a blank line, a directive, and a
    /// hand-written note. All of it has to survive an edit.
    private let messyTab = """
    Pokémon: 4
    4 Charizard ex OBF 125

    Trainer: 7
    4 Iono PAL 185
    3 Boss's Orders PAL 172

    #built: no
    Total Cards: 11
    """

    func testEntriesAddressCardLinesAndSkipEverythingElse() {
        let entries = DeckEditor.entries(messyTab)
        XCTAssertEqual(entries.map(\.lineIndex), [1, 4, 5])
        XCTAssertEqual(entries.map(\.name), ["Charizard ex", "Iono", "Boss's Orders"])
        XCTAssertEqual(entries.map(\.quantity), [4, 4, 3])
    }

    func testSetQuantityTouchesOnlyThatLine() {
        let out = DeckEditor.setQuantity(2, atLine: 4, in: messyTab)
        XCTAssertEqual(out, """
        Pokémon: 4
        4 Charizard ex OBF 125

        Trainer: 7
        2 Iono PAL 185
        3 Boss's Orders PAL 172

        #built: no
        Total Cards: 11
        """)
    }

    /// The whole reason these operate on text: a directive, a blank line and a comment
    /// have to come back out byte for byte.
    func testSetQuantityPreservesTrailingCommentsAndOddSpacing() {
        let text = "4 Iono PAL 185   # my last copies"
        XCTAssertEqual(DeckEditor.setQuantity(1, atLine: 0, in: text),
                       "1 Iono PAL 185   # my last copies")
    }

    func testSetQuantityPreservesLeadingIndentation() {
        let text = "  4 Iono PAL 185"
        XCTAssertEqual(DeckEditor.setQuantity(2, atLine: 0, in: text), "  2 Iono PAL 185")
    }

    func testSetQuantityToZeroRemovesTheLine() {
        let out = DeckEditor.setQuantity(0, atLine: 5, in: messyTab)
        XCTAssertFalse(out.contains("Boss's Orders"))
        XCTAssertTrue(out.contains("#built: no"), "the directive must survive")
        XCTAssertTrue(out.contains("4 Iono PAL 185"))
    }

    func testSetQuantityOnAnOutOfRangeLineIsANoOp() {
        XCTAssertEqual(DeckEditor.setQuantity(2, atLine: 99, in: messyTab), messyTab)
        XCTAssertEqual(DeckEditor.setQuantity(2, atLine: -1, in: messyTab), messyTab)
    }

    func testSetQuantityRefusesToMangleALineWithNoSeparator() {
        // Not a card-line shape; better to do nothing than to produce "2ono".
        XCTAssertEqual(DeckEditor.setQuantity(2, atLine: 0, in: "Iono"), "Iono")
    }

    func testRemoveDeletesExactlyOneLine() {
        let out = DeckEditor.remove(atLine: 1, in: messyTab)
        XCTAssertFalse(out.contains("Charizard"))
        XCTAssertEqual(DeckEditor.lines(out).count, DeckEditor.lines(messyTab).count - 1)
    }

    func testRemoveOutOfRangeIsANoOp() {
        XCTAssertEqual(DeckEditor.remove(atLine: 99, in: messyTab), messyTab)
    }

    func testAddInsertsAfterTheLastCardOfTheSameSupertype() {
        // Boss's Orders is a Trainer; it should land after the last Trainer line (5),
        // not at the bottom past the directive.
        let out = DeckEditor.add(Fixture.energyRetrievalSVI, quantity: 2,
                                 to: messyTab, catalog: catalog)
        let lines = DeckEditor.lines(out)
        XCTAssertEqual(lines[6], "2 Energy Retrieval SVI 171")
        XCTAssertEqual(lines[8], "#built: no", "the directive stays below the cards")
    }

    func testAddPutsAPokemonWithThePokemon() {
        let out = DeckEditor.add(Fixture.ralts, quantity: 1, to: messyTab, catalog: catalog)
        XCTAssertEqual(DeckEditor.lines(out)[2], "1 Ralts MEG 5")
    }

    /// Two lines naming the same printing is something TCG Live won't import and a
    /// person wouldn't write, so a repeat add tops up the existing line.
    func testAddingACardAlreadyOnTheListIncrementsIt() {
        let out = DeckEditor.add(Fixture.ionoPAL, quantity: 2, to: messyTab, catalog: catalog)
        XCTAssertTrue(out.contains("6 Iono PAL 185"))
        XCTAssertEqual(DeckEditor.entries(out).count, 3, "no new line")
    }

    func testAddingADifferentPrintingOfTheSameCardMakesItsOwnLine() {
        // Same equivalence group, different printing — a legitimate thing to list.
        let out = DeckEditor.add(Fixture.ionoPAF, quantity: 1, to: messyTab, catalog: catalog)
        XCTAssertTrue(out.contains("4 Iono PAL 185"))
        XCTAssertTrue(out.contains("1 Iono PAF 237"))
        XCTAssertEqual(DeckEditor.entries(out).count, 4)
    }

    func testAddToAnEmptyDeckAppends() {
        let out = DeckEditor.add(Fixture.ionoPAL, quantity: 4, to: "", catalog: catalog)
        XCTAssertTrue(out.contains("4 Iono PAL 185"))
    }

    func testAddToADeckOfOnlyDirectivesKeepsThem() {
        let out = DeckEditor.add(Fixture.ionoPAL, quantity: 4, to: "#built: no", catalog: catalog)
        XCTAssertTrue(out.contains("#built: no"))
        XCTAssertTrue(out.contains("4 Iono PAL 185"))
    }

    func testAddOfNonPositiveQuantityIsANoOp() {
        XCTAssertEqual(DeckEditor.add(Fixture.ionoPAL, quantity: 0, to: messyTab, catalog: catalog),
                       messyTab)
    }

    func testLineForCardFallsBackWhenThereIsNoSetCode() {
        let noCode = CatalogCard(cardId: "x", setId: "x", setName: "X", ptcgoCode: nil,
                                 number: "1", name: "Mystery", supertype: .trainer,
                                 equivalenceKey: "m", standardLegal: true, expandedLegal: true)
        XCTAssertEqual(DeckEditor.line(for: noCode, quantity: 3), "3 Mystery")
    }

    /// An edit must round-trip through the parser: whatever we write has to be
    /// something we can read back.
    func testEditedTextStillParses() {
        var text = messyTab
        text = DeckEditor.setQuantity(2, atLine: 4, in: text)
        text = DeckEditor.add(Fixture.ralts, quantity: 1, to: text, catalog: catalog)
        let parsed = DecklistParser.parse(text)
        XCTAssertEqual(parsed.reduce(0) { $0 + $1.quantity }, 4 + 2 + 3 + 1)
    }
}
