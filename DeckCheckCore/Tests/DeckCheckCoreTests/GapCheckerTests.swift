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

    /// Regression: a real decklist line. The symbol spelling meant the line resolved
    /// to the MEE 2 Fire Energy printing and came back as "5 missing" — a buy-list
    /// entry for basic energy, which is never tracked.
    func testEnergySymbolLineIsAutoSatisfiedNotMissing() {
        let deck = """
        4 Charizard ex OBF 125
        5 Basic {R} Energy MEE 2
        """
        let owned = [OwnedCard(cardId: "ptcg:obf-125", equivalenceKey: "char", qty: 4)]
        let r = GapChecker.check(decklist: deck, owned: owned, catalog: catalog)

        XCTAssertEqual(r.basicEnergyQty, 5)
        XCTAssertTrue(r.missing.isEmpty)
        XCTAssertFalse(r.entries.contains { $0.name.contains("Energy") })
        XCTAssertEqual(r.buildableQty, 9)   // 4 owned + 5 auto-satisfied
        XCTAssertEqual(r.shortTotal, 0)
        XCTAssertEqual(TCGplayerExport.massEntry(r), "")
    }

    // MARK: - errata bridge

    /// Regression: the deck cites the old Energy Retrieval wording, the binder has the
    /// new one. Previously "1 missing" plus a buy-list line for a card already owned.
    func testRewordedReprintCountsAndIsReportedSeparately() {
        let deck = "1 Energy Retrieval AOR 99"
        let owned = [OwnedCard(cardId: "ptcg:svi-171", equivalenceKey: "eretr-new", qty: 4)]
        let r = GapChecker.check(decklist: deck, owned: owned, catalog: catalog)

        let entry = try! XCTUnwrap(r.entries.first)
        XCTAssertEqual(entry.status, .have)
        XCTAssertEqual(entry.ownedQty, 0)           // nothing in the exact group…
        XCTAssertEqual(entry.errataOwnedQty, 4)     // …but four of the reworded printing
        XCTAssertEqual(entry.shortQty, 0)
        // The printing in the binder, not the newest in its group (CRI 108 is newer).
        XCTAssertEqual(entry.errataPrintings.map(\.cardId), ["ptcg:svi-171"])

        // Its own bucket, not folded into have — the wording really does differ.
        XCTAssertEqual(r.differentWording.map(\.name), ["Energy Retrieval"])
        XCTAssertTrue(r.missing.isEmpty)
        XCTAssertTrue(r.have.isEmpty)

        XCTAssertEqual(r.shortTotal, 0)
        XCTAssertEqual(r.buildableQty, 1)
        XCTAssertEqual(TCGplayerExport.massEntry(r), "")   // nothing to buy
    }

    /// The other half of the report: Air Balloon SSH 213 vs the modern reprint, where
    /// the split is only how the source spells the energy symbol.
    func testBridgedButStillShortStillBuysTheDifference() {
        let deck = "4 Air Balloon SSH 213"
        let owned = [OwnedCard(cardId: "ptcg:meg-166", equivalenceKey: "balloon-new", qty: 1)]
        let r = GapChecker.check(decklist: deck, owned: owned, catalog: catalog)

        let entry = try! XCTUnwrap(r.entries.first)
        XCTAssertEqual(entry.status, .short)
        XCTAssertEqual(entry.errataOwnedQty, 1)
        XCTAssertEqual(entry.shortQty, 3)           // you own one; buy the other three
        XCTAssertEqual(r.differentWording.map(\.name), ["Air Balloon"])
        XCTAssertTrue(r.short.isEmpty)              // reported under differentWording
        XCTAssertEqual(TCGplayerExport.massEntry(r), "3 Air Balloon [SSH] 213/202")
    }

    /// Exact-group copies are used first; the bridge only makes up the difference.
    func testExactCopiesPreferredOverBridged() {
        let deck = "4 Energy Retrieval AOR 99"
        let owned = [
            OwnedCard(cardId: "ptcg:aor-99", equivalenceKey: "eretr-old", qty: 3),
            OwnedCard(cardId: "ptcg:svi-171", equivalenceKey: "eretr-new", qty: 2),
        ]
        let r = GapChecker.check(decklist: deck, owned: owned, catalog: catalog)
        let entry = try! XCTUnwrap(r.entries.first)
        XCTAssertEqual(entry.ownedQty, 3)
        XCTAssertEqual(entry.errataOwnedQty, 2)
        XCTAssertEqual(entry.status, .have)
        XCTAssertEqual(entry.shortQty, 0)
    }

    /// A fully-covered line never consults the bridge, so an exactly-owned card is
    /// still plain "have" even when a reworded printing sits in the collection.
    func testNoBridgeWhenTheExactGroupAlreadyCovers() {
        let deck = "1 Energy Retrieval AOR 99"
        let owned = [
            OwnedCard(cardId: "ptcg:aor-99", equivalenceKey: "eretr-old", qty: 2),
            OwnedCard(cardId: "ptcg:svi-171", equivalenceKey: "eretr-new", qty: 4),
        ]
        let r = GapChecker.check(decklist: deck, owned: owned, catalog: catalog)
        XCTAssertEqual(r.have.map(\.name), ["Energy Retrieval"])
        XCTAssertTrue(r.differentWording.isEmpty)
        XCTAssertEqual(r.entries.first?.errataOwnedQty, 0)
    }

    /// Pokémon are excluded on purpose: same name, different card.
    func testPokemonAreNotBridgedByName() {
        // Own Dup Mon "B"; the deck wants Dup Mon "A". Different attacks, not a swap.
        let owned = [OwnedCard(cardId: "ptcg:bbb-100", equivalenceKey: "dupB", qty: 4)]
        let r = GapChecker.check(decklist: "1 Dup Mon AAA 100", owned: owned, catalog: catalog)
        XCTAssertEqual(r.missing.map(\.name), ["Dup Mon"])
        XCTAssertTrue(r.differentWording.isEmpty)
    }

    /// With the lens on, a bridged printing that *is* legal clears the warning.
    func testLegalityLensConsidersBridgedPrintings() {
        // Deck cites AOR 99 (not Standard-legal); you own SVI 171, which is.
        let owned = [OwnedCard(cardId: "ptcg:svi-171", equivalenceKey: "eretr-new", qty: 4)]
        let r = GapChecker.check(decklist: "1 Energy Retrieval AOR 99", owned: owned,
                                 catalog: catalog, lens: .standard)
        XCTAssertFalse(try! XCTUnwrap(r.entries.first).ownedNoLegalPrinting)
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

    // MARK: - deck order

    /// Pokémon in evolution order, then Item → Tool → Supporter → Stadium, then
    /// Special Energy — with the ace spec sorting first within its own Item tier.
    func testDeckOrderSequencesByCategoryThenEvolution() {
        let deck = """
        1 Blastoise TST 3
        1 Prime Catcher TST 4
        1 Squirtle TST 1
        1 Test Stadium TST 5
        1 Wartortle TST 2
        1 Reversal Energy PAR 192
        1 Air Balloon SSH 213
        1 Iono PAL 185
        1 Energy Retrieval AOR 99
        """
        let r = GapChecker.check(decklist: deck, owned: [], catalog: catalog)
        XCTAssertEqual(r.missing.map(\.name), [
            "Squirtle", "Wartortle", "Blastoise",     // Pokémon, evolution order
            "Prime Catcher", "Energy Retrieval",      // Item, ace spec first
            "Air Balloon",                            // Tool
            "Iono",                                   // Supporter
            "Test Stadium",                           // Stadium
            "Reversal Energy",                        // Special Energy
        ])
    }

    /// Status still wins over the deck-order comparator — gap-first grouping isn't
    /// disturbed by the new within-status ordering.
    func testDeckOrderIsSecondaryToGapStatus() {
        let deck = """
        1 Blastoise TST 3
        1 Squirtle TST 1
        """
        let owned = [OwnedCard(cardId: "ptcg:tst-1", equivalenceKey: "squirtle", qty: 1)] // Squirtle: have
        let r = GapChecker.check(decklist: deck, owned: owned, catalog: catalog)
        XCTAssertEqual(r.entries.map(\.status), [.missing, .have])
        XCTAssertEqual(r.missing.map(\.name), ["Blastoise"])
        XCTAssertEqual(r.have.map(\.name), ["Squirtle"])
    }

    /// A Stage 2 whose `evolvesFrom` chain is missing (a real gap in some
    /// legacy-format printings) can't cluster with its family, but it still lands in
    /// the Pokémon tier rather than crashing or sorting somewhere nonsensical.
    func testEvolutionChainGapDoesNotBreakSorting() {
        let deck = """
        1 Legacy Stage 2 TST 9
        1 Squirtle TST 1
        1 Prime Catcher TST 4
        """
        let r = GapChecker.check(decklist: deck, owned: [], catalog: catalog)
        // Both Pokémon sort ahead of the Trainer, regardless of their relative order.
        XCTAssertEqual(Set(r.missing.prefix(2).map(\.name)), ["Legacy Stage 2", "Squirtle"])
        XCTAssertEqual(r.missing.last?.name, "Prime Catcher")
    }
}
