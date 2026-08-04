import XCTest
@testable import DeckCheckCore

final class LineResolverTests: XCTestCase {
    let catalog = Fixture.catalog

    private func resolve(_ line: String) -> LineResolution {
        let parsed = DecklistParser.parse(line).first!
        return LineResolver.resolve(parsed, catalog: catalog).resolution
    }

    func testSetCodePlusNumberResolves() {
        guard case .resolved(let c) = resolve("2 Charizard ex OBF 125") else { return XCTFail() }
        XCTAssertEqual(c.cardId, "ptcg:obf-125")
        XCTAssertEqual(c.equivalenceKey, "char")
    }

    func testBasicEnergyIsAutoSatisfiedRegardlessOfSet() {
        guard case .basicEnergy(let name) = resolve("5 Basic Fire Energy SVI 230") else { return XCTFail() }
        XCTAssertEqual(name, "Fire Energy")
    }

    /// TCG Live exports basic energy with the type *symbol* as well as the type name.
    /// This used to fall through to set-code resolution, land on the real "Fire Energy"
    /// printing, and be reported as a gap for a card the app deliberately never tracks.
    func testBasicEnergySymbolFormIsAutoSatisfied() {
        guard case .basicEnergy(let name) = resolve("5 Basic {R} Energy MEE 2") else {
            return XCTFail("energy-symbol line should auto-satisfy")
        }
        XCTAssertEqual(name, "Fire Energy")
    }

    func testBasicEnergySymbolFormWithoutBasicPrefix() {
        guard case .basicEnergy(let name) = resolve("4 {W} Energy MEE 3") else { return XCTFail() }
        XCTAssertEqual(name, "Water Energy")
    }

    func testBracketEnergySymbolFormIsAutoSatisfied() {
        guard case .basicEnergy(let name) = resolve("2 Basic [L] Energy MEE 4") else { return XCTFail() }
        XCTAssertEqual(name, "Lightning Energy")
    }

    /// Belt and braces: whatever the line called it, a line that resolves to a basic
    /// energy *printing* still auto-satisfies.
    func testLineResolvingToABasicEnergyPrintingAutoSatisfies() {
        guard case .basicEnergy(let name) = resolve("5 Fyre Enrgy MEE 2") else {
            return XCTFail("a line landing on a basic-energy printing should auto-satisfy")
        }
        XCTAssertEqual(name, "Fire Energy")
    }

    /// Special energy is tracked like any other card — it must not auto-satisfy.
    func testSpecialEnergyStillResolvesAsATrackedCard() {
        guard case .resolved(let c) = resolve("4 Reversal Energy PAR 192") else { return XCTFail() }
        XCTAssertEqual(c.equivalenceKey, "energy-reversal")
    }

    func testNameNumberFallbackWhenCodeUnknown() {
        // "XYZ" isn't a real code, but name + number 125 uniquely hits Charizard ex.
        guard case .resolved(let c) = resolve("1 Charizard ex XYZ 125") else { return XCTFail() }
        XCTAssertEqual(c.equivalenceKey, "char")
    }

    func testAmbiguousNameNumberIsUnidentified() {
        // "Dup Mon" #100 exists in two sets with DIFFERENT keys → not resolvable.
        guard case .unidentified = resolve("1 Dup Mon ZZZ 100") else {
            return XCTFail("expected unidentified for cross-key ambiguity")
        }
    }

    func testUnknownCardIsUnidentifiedNotDropped() {
        guard case .unidentified = resolve("1 Nonexistent Card QQQ 999") else { return XCTFail() }
    }
}
