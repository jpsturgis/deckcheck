import XCTest
@testable import DeckCheckCore

final class DecklistDetectionTests: XCTestCase {

    func testAcceptsATCGLiveList() {
        let deck = """
        Pokémon: 3
        2 Charizard ex OBF 125
        1 Pidgeot ex OBF 164

        Trainer: 2
        4 Iono PAL 185

        Energy: 1
        5 Basic Fire Energy SVI 230
        Total Cards: 60
        """
        let s = DecklistDetection.summary(deck)
        XCTAssertTrue(s.looksLikeDecklist)
        XCTAssertEqual(s.lineCount, 4)
        XCTAssertEqual(s.cardCount, 12)
        XCTAssertEqual(s.linesWithSetCode, 4)
    }

    func testAcceptsASingleLineCarryingASetCode() {
        // A legitimate one-off check: "do I have these?"
        let s = DecklistDetection.summary("4 Iono PAL 185")
        XCTAssertTrue(s.looksLikeDecklist)
        XCTAssertEqual(s.lineCount, 1)
        XCTAssertEqual(s.linesWithSetCode, 1)
    }

    func testRejectsASentenceThatOpensWithANumber() {
        // The case that motivates this type: DecklistParser is tolerant enough to
        // parse this as one card line, so `!parse().isEmpty` would wave it through.
        let prose = "4 things I learned about Charizard ex in the new format"
        XCTAssertFalse(DecklistDetection.looksLikeDecklist(prose))
        XCTAssertEqual(DecklistParser.parse(prose).count, 1, "parser is tolerant by design")
    }

    func testRejectsProseAndURLs() {
        XCTAssertFalse(DecklistDetection.looksLikeDecklist(""))
        XCTAssertFalse(DecklistDetection.looksLikeDecklist("   \n  \n "))
        XCTAssertFalse(DecklistDetection.looksLikeDecklist("https://limitlesstcg.com/decks/list/12345"))
        XCTAssertFalse(DecklistDetection.looksLikeDecklist(
            "Charizard ex is the best deck in the format right now, and here's why."))
    }

    func testAcceptsABareTwoLineListWithoutSetCodes() {
        // Name-only pastes are a real shape (hand-typed, or a basic-energy tail).
        let s = DecklistDetection.summary("4 Iono\n3 Rare Candy")
        XCTAssertTrue(s.looksLikeDecklist)
        XCTAssertEqual(s.linesWithSetCode, 0)
        XCTAssertEqual(s.cardCount, 7)
    }

    func testCardCountSumsQuantitiesNotLines() {
        let s = DecklistDetection.summary("4 Iono PAL 185\n2 Rare Candy SVI 191\n1 Boss's Orders PAL 172")
        XCTAssertEqual(s.lineCount, 3)
        XCTAssertEqual(s.cardCount, 7)
    }

    func testHeadersAloneAreNotADecklist() {
        // Section headers don't start with a quantity, so nothing parses.
        let s = DecklistDetection.summary("Pokémon: 6\nTrainer: 30\nEnergy: 24")
        XCTAssertEqual(s.lineCount, 0)
        XCTAssertFalse(s.looksLikeDecklist)
    }
}
