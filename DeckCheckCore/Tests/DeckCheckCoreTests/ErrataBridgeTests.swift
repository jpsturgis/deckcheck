import XCTest
@testable import DeckCheckCore

/// The grouping rule itself. The gap-check behaviour it produces is covered in
/// GapCheckerTests.
final class ErrataBridgeTests: XCTestCase {
    private func trainer(_ name: String, subtypes: [String], key: String) -> CatalogCard {
        CatalogCard(cardId: "id-\(key)", setId: "s", setName: "Set", ptcgoCode: "SET",
                    number: "1", name: name, supertype: .trainer, equivalenceKey: key,
                    standardLegal: true, expandedLegal: true, subtypes: subtypes)
    }

    func testSameNameAndTypeBridgeAcrossKeys() {
        let a = trainer("Energy Retrieval", subtypes: ["Item"], key: "old")
        let b = trainer("Energy Retrieval", subtypes: ["Item"], key: "new")
        XCTAssertNotNil(ErrataBridge.groupKey(a))
        XCTAssertEqual(ErrataBridge.groupKey(a), ErrataBridge.groupKey(b))
    }

    func testCardTypeSeparatesSameNamedTrainers() {
        // An Item and a Tool that share a name are different cards, errata or not.
        let item = trainer("Ambiguous", subtypes: ["Item"], key: "a")
        let tool = trainer("Ambiguous", subtypes: ["Tool"], key: "b")
        XCTAssertNotEqual(ErrataBridge.groupKey(item), ErrataBridge.groupKey(tool))
    }

    func testNameMatchIsApostropheAndCaseInsensitive() {
        // Same folding the rest of the app uses, so a curly apostrophe doesn't split.
        let a = trainer("Boss\u{2019}s Orders", subtypes: ["Supporter"], key: "a")
        let b = trainer("boss's orders", subtypes: ["Supporter"], key: "b")
        XCTAssertEqual(ErrataBridge.groupKey(a), ErrataBridge.groupKey(b))
    }

    func testPokemonAreNeverBridged() {
        // Two Pokémon sharing a name are routinely different cards — bridging them
        // would turn every reprinted name into a false "you already own this".
        XCTAssertNil(ErrataBridge.groupKey(Fixture.dupA))
        XCTAssertNil(ErrataBridge.groupKey(Fixture.dupB))
    }

    func testManualPromosAreNeverBridged() {
        // A promo has supertype .unknown and its own explicit "plays as" link.
        let promo = ManualEntry.promoCard(name: "Iono", code: "MEP", number: "075")!
        XCTAssertNil(ErrataBridge.groupKey(promo))
    }

    func testSpecialAndBasicEnergyBridgeSeparately() {
        let special = CatalogCard(cardId: "e1", setId: "s", setName: "Set", ptcgoCode: "SET",
                                  number: "1", name: "Reversal Energy", supertype: .energy,
                                  equivalenceKey: "k1", standardLegal: true, expandedLegal: true,
                                  subtypes: ["Special"])
        let basic = CatalogCard(cardId: "e2", setId: "s", setName: "Set", ptcgoCode: "SET",
                                number: "2", name: "Reversal Energy", supertype: .energy,
                                equivalenceKey: "k2", standardLegal: true, expandedLegal: true,
                                subtypes: ["Normal"])
        XCTAssertNotEqual(ErrataBridge.groupKey(special), ErrataBridge.groupKey(basic))
    }
}
