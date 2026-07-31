import XCTest
@testable import DeckCheckCore

final class RecognizerTests: XCTestCase {
    let catalog = Fixture.catalog

    func testPrintedTotalPinsTheSet() {
        // The §3.2 "/197" trick: number 125 + printed total 197 → OBF Charizard ex,
        // WITHOUT any set code.
        let rec = RecognizedCard(numberTotals: [NumberTotal(number: "125", printedTotal: "197")])
        let r = PrintingResolver.resolve(rec, catalog: catalog)
        XCTAssertEqual(r.confidence, .confident)
        XCTAssertEqual(r.best?.cardId, "ptcg:obf-125")
    }

    func testPrintedTotalBeatsNoisySetCode() {
        // A bogus OCR set code is present, but the printed-total path resolves first.
        let rec = RecognizedCard(setCodes: ["HP", "GX"],
                                 numberTotals: [NumberTotal(number: "125", printedTotal: "197")])
        let r = PrintingResolver.resolve(rec, catalog: catalog)
        XCTAssertEqual(r.best?.equivalenceKey, "char")
    }

    func testSetCodeFallbackWhenNoTotal() {
        let rec = RecognizedCard(setCodes: ["OBF"], looseNumbers: ["125"])
        let r = PrintingResolver.resolve(rec, catalog: catalog)
        XCTAssertEqual(r.confidence, .confident)
        XCTAssertEqual(r.best?.cardId, "ptcg:obf-125")
    }

    func testNameNumberFallback() {
        let rec = RecognizedCard(nameGuess: "Charizard ex", looseNumbers: ["125"])
        let r = PrintingResolver.resolve(rec, catalog: catalog)
        XCTAssertEqual(r.best?.equivalenceKey, "char")
    }

    func testAmbiguousPrintedTotalFallsToUncertainCandidates() {
        // Two different-key cards share printed total 500 + number 100 → no confident
        // pick; the number-only path offers them as candidates for the picker.
        let rec = RecognizedCard(numberTotals: [NumberTotal(number: "100", printedTotal: "500")])
        let r = PrintingResolver.resolve(rec, catalog: catalog)
        XCTAssertNil(r.best)
        XCTAssertEqual(r.confidence, .uncertain)
        XCTAssertEqual(Set(r.candidates.map(\.cardId)), ["ptcg:aaa-100", "ptcg:bbb-100"])
    }

    func testNoReadIsUncertainEmpty() {
        let r = PrintingResolver.resolve(RecognizedCard(), catalog: catalog)
        XCTAssertNil(r.best)
        XCTAssertTrue(r.candidates.isEmpty)
        XCTAssertEqual(r.confidence, .uncertain)
    }

    func testHPBreaksASameNumberCollision() {
        // Number 100 alone is ambiguous (Dup Mon in Set A vs Set B). Reading the HP
        // (110 = Set A's) corroborates one and resolves it confidently.
        let rec = RecognizedCard(looseNumbers: ["100"], hp: "110")
        let r = PrintingResolver.resolve(rec, catalog: catalog)
        XCTAssertEqual(r.confidence, .confident)
        XCTAssertEqual(r.best?.cardId, "ptcg:aaa-100")
    }

    func testNumberOnlyCollisionStaysUncertain() {
        // No second signal → no confident pick, both offered to the picker.
        let rec = RecognizedCard(looseNumbers: ["100"])
        let r = PrintingResolver.resolve(rec, catalog: catalog)
        XCTAssertNil(r.best)
        XCTAssertEqual(Set(r.candidates.map(\.cardId)), ["ptcg:aaa-100", "ptcg:bbb-100"])
    }

    func testConflictingSignalsBelowMarginGoToPicker() {
        // A stray set code points at Set B while the HP points at Set A — neither clears
        // the margin, so it surfaces as candidates instead of a confident *wrong* pick.
        let rec = RecognizedCard(setCodes: ["BBB"], looseNumbers: ["100"], hp: "110")
        let r = PrintingResolver.resolve(rec, catalog: catalog)
        XCTAssertNil(r.best)
        XCTAssertEqual(r.confidence, .uncertain)
        XCTAssertEqual(Set(r.candidates.map(\.cardId)), ["ptcg:aaa-100", "ptcg:bbb-100"])
    }
}
