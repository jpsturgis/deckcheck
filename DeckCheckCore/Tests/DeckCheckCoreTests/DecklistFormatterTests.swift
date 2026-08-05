import XCTest
@testable import DeckCheckCore

final class DecklistFormatterTests: XCTestCase {
    private let catalog = Fixture.catalog

    func testGroupsIntoSectionsWithCountsAndATotal() {
        let messy = """
        #built: yes
        4 Iono PAL 185
        4 Charizard ex OBF 125
        2 Reversal Energy PAR 192
        """
        XCTAssertEqual(DecklistFormatter.tcgLive(decklist: messy, catalog: catalog), """
        Pokémon: 4
        4 Charizard ex OBF 125

        Trainer: 4
        4 Iono PAL 185

        Energy: 2
        2 Reversal Energy PAR 192

        Total Cards: 10
        """)
    }

    func testDropsDirectivesCommentsAndStaleHeaders() {
        let messy = """
        Pokémon: 99
        4 Charizard ex OBF 125
        #built: no
        // a note
        Total Cards: 3
        """
        let out = DecklistFormatter.tcgLive(decklist: messy, catalog: catalog)
        XCTAssertFalse(out.contains("#built"))
        XCTAssertFalse(out.contains("a note"))
        XCTAssertFalse(out.contains("99"), "the stale header must not survive")
        XCTAssertTrue(out.contains("Pokémon: 4"))
        XCTAssertTrue(out.hasSuffix("Total Cards: 4"))
    }

    func testBasicEnergyKeepsItsOriginalLine() {
        // Any basic Fire is any other, so there's nothing to normalize — and rewriting
        // it could name a printing the user doesn't have.
        let out = DecklistFormatter.tcgLive(decklist: "8 Basic Fire Energy MEE 2", catalog: catalog)
        XCTAssertTrue(out.contains("8 Basic Fire Energy MEE 2"))
        XCTAssertTrue(out.contains("Energy: 8"))
    }

    /// Losing a card from an exported list would be the worst failure this type could
    /// have, so an unresolvable line is carried through rather than dropped.
    func testUnidentifiedLinesArePassedThroughNotDropped() {
        let out = DecklistFormatter.tcgLive(decklist: "3 Some Promo XYZ 999", catalog: catalog)
        XCTAssertTrue(out.contains("3 Some Promo XYZ 999"))
        XCTAssertTrue(out.contains("Other: 3"))
        XCTAssertTrue(out.hasSuffix("Total Cards: 3"))
    }

    func testEmptySectionsAreOmitted() {
        let out = DecklistFormatter.tcgLive(decklist: "4 Charizard ex OBF 125", catalog: catalog)
        XCTAssertFalse(out.contains("Trainer:"))
        XCTAssertFalse(out.contains("Energy:"))
        XCTAssertFalse(out.contains("Other:"))
    }

    func testAnEmptyDecklistIsJustATotal() {
        XCTAssertEqual(DecklistFormatter.tcgLive(decklist: "", catalog: catalog), "Total Cards: 0")
    }

    /// The formatter's output has to be readable by the parser it came from.
    func testOutputRoundTripsThroughTheParser() {
        let source = """
        4 Iono PAL 185
        4 Charizard ex OBF 125
        8 Basic Fire Energy MEE 2
        """
        let formatted = DecklistFormatter.tcgLive(decklist: source, catalog: catalog)
        let reparsed = DecklistParser.parse(formatted)
        XCTAssertEqual(reparsed.reduce(0) { $0 + $1.quantity }, 16)
        // And formatting is idempotent.
        XCTAssertEqual(DecklistFormatter.tcgLive(decklist: formatted, catalog: catalog), formatted)
    }
}
