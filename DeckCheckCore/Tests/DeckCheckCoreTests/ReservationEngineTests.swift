import XCTest
@testable import DeckCheckCore

final class ReservationEngineTests: XCTestCase {
    let catalog = Fixture.catalog

    func testSingleDeckReservesPerEquivalenceGroup() {
        let deck = DeckList(name: "Zard", text: """
        4 Charizard ex OBF 125
        4 Iono PAL 185
        """)
        let r = ReservationEngine.compute(decks: [deck], catalog: catalog)
        XCTAssertEqual(r.reserved(forKey: "char"), 4)
        XCTAssertEqual(r.reserved(forKey: "iono"), 4)
        XCTAssertEqual(r.decks(forKey: "char"), ["Zard"])
    }

    func testTwoDecksSumAcrossGroups() {
        let zard = DeckList(name: "Zard", text: "4 Charizard ex OBF 125\n4 Iono PAL 185")
        // A different Charizard printing (PAF) — same functional group "char".
        let control = DeckList(name: "Control", text: "3 Charizard ex PAF 234\n2 Boss's Orders PAL 172")
        let r = ReservationEngine.compute(decks: [zard, control], catalog: catalog)

        XCTAssertEqual(r.reserved(forKey: "char"), 7)  // 4 + 3, across printings
        XCTAssertEqual(r.decks(forKey: "char"), ["Zard", "Control"])
        XCTAssertEqual(r.reserved(forKey: "iono"), 4)
        XCTAssertEqual(r.reserved(forKey: "boss"), 2)
    }

    func testBasicEnergyAndUnidentifiedReserveNothing() {
        let deck = DeckList(name: "E", text: """
        4 Charizard ex OBF 125
        10 Basic Fire Energy
        2 Totally Made Up Card ZZZ 999
        """)
        let r = ReservationEngine.compute(decks: [deck], catalog: catalog)
        XCTAssertEqual(r.reserved(forKey: "char"), 4)
        XCTAssertEqual(r.reservedByKey.count, 1) // only char; energy + unknown reserve nothing
    }

    func testSameGroupTwiceInOneDeckCountsDeckOnce() {
        let deck = DeckList(name: "Dupes", text: "2 Charizard ex OBF 125\n2 Charizard ex PAF 234")
        let r = ReservationEngine.compute(decks: [deck], catalog: catalog)
        XCTAssertEqual(r.reserved(forKey: "char"), 4)        // both lines sum
        XCTAssertEqual(r.decks(forKey: "char"), ["Dupes"])   // deck listed once
    }

    func testEmptyAndNoDecks() {
        XCTAssertTrue(ReservationEngine.compute(decks: [], catalog: catalog).isEmpty)
        XCTAssertTrue(ReservationEngine.compute(decks: [DeckList(name: "Blank", text: "")], catalog: catalog).isEmpty)
    }
}
