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
