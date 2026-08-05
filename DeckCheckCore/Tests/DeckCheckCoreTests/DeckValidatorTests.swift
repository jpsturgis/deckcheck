import XCTest
@testable import DeckCheckCore

final class DeckValidatorTests: XCTestCase {
    private let catalog = Fixture.catalog

    private func validate(_ text: String, lens: LegalityFormat? = nil) -> [DeckViolation] {
        DeckValidator.validate(decklist: text, catalog: catalog, lens: lens)
    }

    /// A legal 60: 4 Charizard, 4 Iono, 4 Boss's Orders, 48 basic energy.
    private let legalSixty = """
    4 Charizard ex OBF 125
    4 Iono PAL 185
    4 Boss's Orders PAL 172
    48 Basic Fire Energy MEE 2
    """

    func testALegalDeckHasNoViolations() {
        XCTAssertTrue(validate(legalSixty).isEmpty)
    }

    func testDeckMustBeExactlySixty() {
        let short = validate("4 Charizard ex OBF 125\n50 Basic Fire Energy MEE 2")
        XCTAssertEqual(short.count, 1)
        XCTAssertEqual(short[0].kind, .cardCount(actual: 54))
        XCTAssertTrue(short[0].message.contains("6 short"), short[0].message)

        let over = validate("4 Charizard ex OBF 125\n60 Basic Fire Energy MEE 2")
        XCTAssertEqual(over[0].kind, .cardCount(actual: 64))
        XCTAssertTrue(over[0].message.contains("4 over"), over[0].message)
    }

    func testFourCopyLimit() {
        let text = """
        5 Iono PAL 185
        4 Charizard ex OBF 125
        51 Basic Fire Energy MEE 2
        """
        let v = validate(text)
        XCTAssertEqual(v.count, 1)
        XCTAssertEqual(v[0].kind, .copyLimit(name: "Iono", count: 5))
    }

    /// The rule is four cards **with the same name**, not four of a functional group.
    /// These two Iono printings have the same equivalence key *and* the same name, so
    /// they must add up — a per-line check would let this through.
    func testCopiesAcrossPrintingsOfTheSameNameAreAddedTogether() {
        let text = """
        3 Iono PAL 185
        2 Iono PAF 237
        4 Charizard ex OBF 125
        51 Basic Fire Energy MEE 2
        """
        let v = validate(text)
        XCTAssertEqual(v.map(\.kind), [.copyLimit(name: "Iono", count: 5)])
    }

    /// The inverse, and the reason the tally is keyed on name rather than equivalence
    /// key: these two share a *name* but have different keys — they play differently.
    /// The four-copy rule still caps them between them.
    func testSameNameDifferentEquivalenceKeysStillShareTheLimit() {
        XCTAssertNotEqual(Fixture.dupA.equivalenceKey, Fixture.dupB.equivalenceKey)
        XCTAssertEqual(Fixture.dupA.name, Fixture.dupB.name)

        let text = """
        3 Dup Mon AAA 100
        3 Dup Mon BBB 100
        54 Basic Fire Energy MEE 2
        """
        let v = validate(text)
        XCTAssertEqual(v.map(\.kind), [.copyLimit(name: "Dup Mon", count: 6)],
                       "grouping by equivalence key here would wave an illegal deck through")
    }

    func testBasicEnergyIsExemptFromTheCopyLimit() {
        // 48 basic Fire in the legal deck above, and no violation for it.
        XCTAssertTrue(validate(legalSixty).isEmpty)
    }

    /// Special energy is a real card with a real name — it is *not* exempt.
    func testSpecialEnergyIsNotExempt() {
        let text = """
        5 Reversal Energy PAR 192
        4 Charizard ex OBF 125
        51 Basic Fire Energy MEE 2
        """
        XCTAssertEqual(validate(text).map(\.kind), [.copyLimit(name: "Reversal Energy", count: 5)])
    }

    func testNameSpellingVariantsFoldTogether() {
        // Curly vs straight apostrophe — the same card, and the tally must say so.
        let text = """
        3 Boss's Orders PAL 172
        2 Boss\u{2019}s Orders PAL 172
        4 Charizard ex OBF 125
        51 Basic Fire Energy MEE 2
        """
        XCTAssertEqual(validate(text).map(\.kind), [.copyLimit(name: "Boss's Orders", count: 5)])
    }

    func testFormatLegalityOnlyWhenALensIsApplied() {
        // Air Balloon SSH 213 has no Standard-legal printing in its group.
        let text = """
        4 Air Balloon SSH 213
        4 Charizard ex OBF 125
        52 Basic Fire Energy MEE 2
        """
        XCTAssertTrue(validate(text).isEmpty, "no lens → legality isn't judged")

        let v = validate(text, lens: .standard)
        XCTAssertEqual(v.map(\.kind), [.notLegal(name: "Air Balloon", format: .standard)])
        XCTAssertTrue(validate(text, lens: .expanded).isEmpty, "the SSH printing is Expanded-legal")
    }

    /// Legality is a property of the *card*, not the printing the list names. An older
    /// printing is playable while the card has a legal reprint — so a deck listing the
    /// copy its owner actually has must not be flagged.
    ///
    /// Judging the named printing alone flagged most of a legal deck the moment a set
    /// rotated: Rare Candy, Ultra Ball, Boss's Orders and Judge all have printings on
    /// both sides of the line.
    func testAnOlderPrintingIsLegalWhenTheCardHasALegalReprint() {
        // Boss's Orders RCL 154 is not itself Standard-legal, but PAL 172 — same
        // equivalence group — is.
        XCTAssertFalse(Fixture.bossRCL.standardLegal)
        XCTAssertTrue(Fixture.bossPAL.standardLegal)
        XCTAssertEqual(Fixture.bossRCL.equivalenceKey, Fixture.bossPAL.equivalenceKey)

        let text = """
        4 Boss's Orders RCL 154
        4 Charizard ex OBF 125
        52 Basic Fire Energy MEE 2
        """
        XCTAssertTrue(validate(text, lens: .standard).isEmpty,
                      "the card is Standard-legal via its reprint, so the old print is playable")
    }

    /// The converse: a card with no legal printing anywhere in its group is a real
    /// violation, and must still be caught.
    func testACardWithNoLegalPrintingAnywhereIsStillFlagged() {
        let text = """
        4 Energy Retrieval AOR 99
        4 Charizard ex OBF 125
        52 Basic Fire Energy MEE 2
        """
        XCTAssertEqual(validate(text, lens: .standard).map(\.kind),
                       [.notLegal(name: "Energy Retrieval", format: .standard)])
    }

    func testAnIllegalCardIsReportedOncePerName() {
        let text = """
        2 Air Balloon SSH 213
        2 Air Balloon SSH 213
        4 Charizard ex OBF 125
        52 Basic Fire Energy MEE 2
        """
        XCTAssertEqual(validate(text, lens: .standard).filter {
            if case .notLegal = $0.kind { return true } else { return false }
        }.count, 1)
    }

    func testUnidentifiedLinesAreReportedButNotJudged() {
        let text = """
        4 Some Promo XYZ 999
        4 Charizard ex OBF 125
        52 Basic Fire Energy MEE 2
        """
        let v = validate(text)
        XCTAssertEqual(v.count, 1)
        guard case let .unidentified(raw) = v[0].kind else { return XCTFail("expected .unidentified") }
        XCTAssertEqual(raw, "4 Some Promo XYZ 999")
        // Unidentified copies still count toward the 60 — they're cards in the deck.
        XCTAssertFalse(v.contains { if case .cardCount = $0.kind { return true } else { return false } })
    }

    func testAnEmptyDeckIsJustUndersized() {
        XCTAssertEqual(validate("").map(\.kind), [.cardCount(actual: 0)])
        XCTAssertEqual(validate("#built: no\n\nPokémon: 0").map(\.kind), [.cardCount(actual: 0)])
    }

    func testViolationsAreOrderedSizeThenCopiesThenLegalityThenUnknown() {
        let text = """
        5 Iono PAL 185
        4 Air Balloon SSH 213
        4 Some Promo XYZ 999
        """
        let kinds = validate(text, lens: .standard).map(\.kind)
        XCTAssertEqual(kinds.count, 4)
        guard case .cardCount = kinds[0] else { return XCTFail("size first") }
        guard case .copyLimit = kinds[1] else { return XCTFail("copies second") }
        guard case .notLegal = kinds[2] else { return XCTFail("legality third") }
        guard case .unidentified = kinds[3] else { return XCTFail("unknown last") }
    }
}
