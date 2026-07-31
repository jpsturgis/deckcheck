import XCTest
@testable import DeckCheckCore

final class DecklistParserTests: XCTestCase {
    func testParsesTCGLiveBlockAndSkipsHeaders() {
        let deck = """
        Pokémon: 3
        2 Charizard ex OBF 125
        1 Pidgeot ex OBF 164

        Trainer: 2
        4 Iono PAL 185
        3 Boss's Orders PAL 172

        Energy: 1
        5 Basic Fire Energy SVI 230
        Total Cards: 60
        """
        let lines = DecklistParser.parse(deck)
        // headers + "Total Cards" skipped; 5 card lines remain
        XCTAssertEqual(lines.count, 5)

        let char = lines[0]
        XCTAssertEqual(char.quantity, 2)
        XCTAssertEqual(char.name, "Charizard ex")
        XCTAssertEqual(char.setCode, "OBF")
        XCTAssertEqual(char.number, "125")

        let boss = lines[3]
        XCTAssertEqual(boss.quantity, 3)
        XCTAssertEqual(boss.name, "Boss's Orders") // apostrophe + space preserved
        XCTAssertEqual(boss.setCode, "PAL")
        XCTAssertEqual(boss.number, "172")

        let energy = lines[4]
        XCTAssertEqual(energy.quantity, 5)
        XCTAssertEqual(energy.name, "Basic Fire Energy")
        XCTAssertEqual(energy.setCode, "SVI")
        XCTAssertEqual(energy.number, "230")
    }

    func testAcceptsQuantitySuffixX() {
        let lines = DecklistParser.parse("4x Iono PAL 185")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].quantity, 4)
        XCTAssertEqual(lines[0].name, "Iono")
    }

    func testNameOnlyLineHasNilSetAndNumber() {
        let lines = DecklistParser.parse("2 Iono")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].name, "Iono")
        XCTAssertNil(lines[0].setCode)
        XCTAssertNil(lines[0].number)
    }

    func testAlnumGalleryNumberPeeled() {
        let lines = DecklistParser.parse("1 Rayquaza VMAX CRZ GG69")
        XCTAssertEqual(lines[0].name, "Rayquaza VMAX")
        XCTAssertEqual(lines[0].setCode, "CRZ")
        XCTAssertEqual(lines[0].number, "GG69")
    }

    func testLineWithoutLeadingQuantityIsSkipped() {
        XCTAssertTrue(DecklistParser.parse("Deck built by Someone").isEmpty)
        XCTAssertTrue(DecklistParser.parse("Pokémon: 12").isEmpty)
    }
}
