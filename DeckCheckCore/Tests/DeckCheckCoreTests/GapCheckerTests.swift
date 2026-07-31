import XCTest
@testable import DeckCheckCore

final class GapCheckerTests: XCTestCase {
    let catalog = Fixture.catalog

    func testMissingShortHaveClassification() {
        let deck = """
        4 Charizard ex OBF 125
        4 Iono PAL 185
        3 Boss's Orders PAL 172
        """
        let owned = [
            OwnedCard(cardId: "ptcg:obf-125", equivalenceKey: "char", qty: 4), // have (4/4)
            OwnedCard(cardId: "ptcg:pal-185", equivalenceKey: "iono", qty: 1), // short (1/4)
            // Boss's Orders: none owned → missing
        ]
        let r = GapChecker.check(decklist: deck, owned: owned, catalog: catalog)

        XCTAssertEqual(r.have.map(\.name), ["Charizard ex"])
        XCTAssertEqual(r.short.first?.name, "Iono")
        XCTAssertEqual(r.short.first?.shortQty, 3)
        XCTAssertEqual(r.missing.first?.name, "Boss's Orders")
        // gap-first ordering: missing before short before have
        XCTAssertEqual(r.entries.map(\.status), [.missing, .short, .have])
    }

    func testFunctionalOwnershipViaDifferentPrinting() {
        // Deck lists the OBF Charizard; we own the PAF one (same key "char").
        let deck = "2 Charizard ex OBF 125"
        let owned = [OwnedCard(cardId: "ptcg:paf-234", equivalenceKey: "char", qty: 2)]
        let r = GapChecker.check(decklist: deck, owned: owned, catalog: catalog)

        let entry = try! XCTUnwrap(r.entries.first)
        XCTAssertEqual(entry.status, .have)          // counts as owned
        XCTAssertTrue(entry.differentPrinting)       // ...but flagged 🔁
        XCTAssertEqual(r.shortTotal, 0)
    }

    func testLinkedPromoCountsAsFunctionalCopy() {
        // #48: a hand-entered promo linked to the catalog card it plays as adopts that
        // functional key, so it satisfies a deck line for the reprint — while keeping
        // its own manual id.
        let promo = ManualEntry.promoCard(name: "Charizard ex", code: "MEP", number: "075",
                                          equivalenceKey: "char")!
        let owned = [OwnedCard(cardId: promo.cardId, equivalenceKey: promo.equivalenceKey, qty: 2)]
        let r = GapChecker.check(decklist: "2 Charizard ex OBF 125", owned: owned, catalog: catalog)

        XCTAssertEqual(r.entries.first?.status, .have)
        XCTAssertEqual(r.shortTotal, 0)
        XCTAssertTrue(owned[0].cardId.hasPrefix("manual:"))   // identity stays the promo's
    }

    func testUnlinkedPromoDoesNotCount() {
        // No link → its own isolated key → the deck line stays missing.
        let promo = ManualEntry.promoCard(name: "Charizard ex", code: "MEP", number: "075")!
        let owned = [OwnedCard(cardId: promo.cardId, equivalenceKey: promo.equivalenceKey, qty: 2)]
        let r = GapChecker.check(decklist: "2 Charizard ex OBF 125", owned: owned, catalog: catalog)
        XCTAssertEqual(r.entries.first?.status, .missing)
    }

    func testBasicEnergyAutoSatisfiedAndCounted() {
        let deck = """
        4 Charizard ex OBF 125
        8 Basic Fire Energy SVI 230
        """
        let r = GapChecker.check(decklist: deck, owned: [], catalog: catalog)
        XCTAssertEqual(r.basicEnergyQty, 8)
        // energy never appears as a gap entry
        XCTAssertFalse(r.entries.contains { $0.name.contains("Energy") })
        // buildable includes the 8 auto-satisfied energy even with zero owned cards
        XCTAssertEqual(r.buildableQty, 8)
        XCTAssertEqual(r.deckTotal, 12)
    }

    func testUnidentifiedBucketedAndExcludedFromBuildable() {
        let deck = """
        4 Charizard ex OBF 125
        2 Dup Mon ZZZ 100
        """
        let owned = [OwnedCard(cardId: "ptcg:obf-125", equivalenceKey: "char", qty: 4)]
        let r = GapChecker.check(decklist: deck, owned: owned, catalog: catalog)
        XCTAssertEqual(r.unidentified.count, 1)
        XCTAssertEqual(r.unidentified.first?.name, "Dup Mon")
        XCTAssertEqual(r.deckTotal, 6)
        XCTAssertEqual(r.buildableQty, 4) // the 2 unidentified are NOT counted buildable
    }

    func testBuildableAndShortTotals() {
        let deck = """
        4 Charizard ex OBF 125
        4 Iono PAL 185
        """
        let owned = [
            OwnedCard(cardId: "ptcg:obf-125", equivalenceKey: "char", qty: 2),
            OwnedCard(cardId: "ptcg:pal-185", equivalenceKey: "iono", qty: 4),
        ]
        let r = GapChecker.check(decklist: deck, owned: owned, catalog: catalog)
        XCTAssertEqual(r.buildableQty, 6) // 2 char + 4 iono
        XCTAssertEqual(r.shortTotal, 2)   // need 2 more char
        XCTAssertEqual(r.deckTotal, 8)
    }

    func testLegalityLensFlagsRotatedOnlyPrintings() {
        // Own only the rotated Boss's Orders (RCL, not standard-legal).
        let deck = "2 Boss's Orders PAL 172"
        let owned = [OwnedCard(cardId: "ptcg:rcl-154", equivalenceKey: "boss", qty: 2)]

        let noLens = GapChecker.check(decklist: deck, owned: owned, catalog: catalog)
        XCTAssertFalse(noLens.entries.first!.ownedNoLegalPrinting) // off by default

        let std = GapChecker.check(decklist: deck, owned: owned, catalog: catalog, lens: .standard)
        let entry = std.entries.first!
        XCTAssertEqual(entry.status, .have)             // functionally owned
        XCTAssertTrue(entry.ownedNoLegalPrinting)       // ...but no Standard-legal printing
    }

    func testLegalityLensClearWhenALegalPrintingIsOwned() {
        let deck = "2 Boss's Orders PAL 172"
        let owned = [OwnedCard(cardId: "ptcg:pal-172", equivalenceKey: "boss", qty: 2)] // std legal
        let std = GapChecker.check(decklist: deck, owned: owned, catalog: catalog, lens: .standard)
        XCTAssertFalse(std.entries.first!.ownedNoLegalPrinting)
        XCTAssertFalse(std.entries.first!.differentPrinting) // owns the exact listed printing
    }
}
