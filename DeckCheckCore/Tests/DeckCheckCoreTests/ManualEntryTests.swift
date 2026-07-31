import XCTest
@testable import DeckCheckCore

final class ManualEntryTests: XCTestCase {
    func testBuildsPromoFromTypedFields() {
        // The flagship case: "MEP EN 075" Ampharos, a Mega Evolution promo the
        // pokemontcg.io source doesn't carry yet.
        let card = ManualEntry.promoCard(name: "Ampharos", code: "mep", number: "075")
        XCTAssertNotNil(card)
        XCTAssertEqual(card?.name, "Ampharos")
        XCTAssertEqual(card?.ptcgoCode, "MEP")           // upper-cased
        XCTAssertEqual(card?.number, "075")              // printed number kept verbatim
        XCTAssertEqual(card?.printedTotal, nil)          // promos have no "/total"
        XCTAssertEqual(card?.cardId, "manual:mep-075")
        XCTAssertFalse(card?.equivalenceKey.isEmpty ?? true)
    }

    func testIdentityIsStableAndSelfConsistent() {
        // Two entries of the same promo must land on the same id so a removal finds
        // the intake, and cardId == equivalenceKey (its own one-printing group).
        let a = ManualEntry.promoCard(name: "Ampharos", code: "MEP", number: "075")
        let b = ManualEntry.promoCard(name: " ampharos ", code: " mep ", number: " 075 ")
        XCTAssertEqual(a?.cardId, b?.cardId)
        XCTAssertEqual(a?.cardId, a?.equivalenceKey)
    }

    func testDifferentPromosGetDifferentIds() {
        let x = ManualEntry.promoCard(name: "Ampharos", code: "MEP", number: "075")
        let y = ManualEntry.promoCard(name: "Pikachu", code: "MEP", number: "076")
        XCTAssertNotEqual(x?.cardId, y?.cardId)
    }

    func testFallsBackToNameWhenCodeUnknown() {
        // No printed code — identity still has to be unique per card.
        let card = ManualEntry.promoCard(name: "Mega Ampharos ex", code: "", number: "75")
        XCTAssertEqual(card?.ptcgoCode, nil)
        XCTAssertEqual(card?.cardId, "manual:mega-ampharos-ex-75")
    }

    func testNilWhenNothingToIdentifyBy() {
        XCTAssertNil(ManualEntry.promoCard(name: "  ", code: "MEP", number: "  "))
    }

    func testAdoptsLinkedEquivalenceKeyAndFoldsItIntoId() {
        // Linked to the catalog card it plays as → adopts that functional group (so the
        // gap-check counts it). The id folds in the key so re-linking makes a distinct
        // row; it stays a stable "manual:" id.
        let card = ManualEntry.promoCard(name: "Ampharos", code: "MEP", number: "075",
                                         equivalenceKey: "ampharos-stage2")
        XCTAssertEqual(card?.equivalenceKey, "ampharos-stage2")
        XCTAssertEqual(card?.cardId, "manual:mep-075-ampharos-stage2")
        // A different link → a different id (re-link removes old, appends new).
        let other = ManualEntry.promoCard(name: "Ampharos", code: "MEP", number: "075",
                                          equivalenceKey: "ampharos-mega")
        XCTAssertNotEqual(card?.cardId, other?.cardId)
    }

    func testUnlinkedPromoIsItsOwnGroup() {
        let card = ManualEntry.promoCard(name: "Ampharos", code: "MEP", number: "075")
        XCTAssertEqual(card?.equivalenceKey, card?.cardId)   // isolated → won't count in gap-check
    }

    func testManualIdNeverCollidesWithCatalogIds() {
        // Real ids are "ptcg:…"; ours are "manual:…".
        let card = ManualEntry.promoCard(name: "Ampharos", code: "MEP", number: "075")
        XCTAssertTrue(card?.cardId.hasPrefix("manual:") ?? false)
    }

    func testIsManualDistinguishesPromosFromCatalogCards() {
        XCTAssertTrue(ManualEntry.isManual("manual:mep-075"))
        XCTAssertFalse(ManualEntry.isManual("ptcg:svp-109"))
    }
}
