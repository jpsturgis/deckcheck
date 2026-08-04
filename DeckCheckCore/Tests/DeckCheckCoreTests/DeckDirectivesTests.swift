import XCTest
@testable import DeckCheckCore

final class DeckDirectivesTests: XCTestCase {
    private let list = """
    Pokémon: 1
    4 Charizard ex OBF 125
    """

    func testAbsentDirectiveMeansBuilt() {
        // Every deck tab that predates this feature must keep reserving as before.
        XCTAssertTrue(DeckDirectives.isBuilt(list))
        XCTAssertTrue(DeckDirectives.isBuilt(""))
    }

    func testReadsBuiltDirective() {
        XCTAssertFalse(DeckDirectives.isBuilt("#built: no\n" + list))
        XCTAssertTrue(DeckDirectives.isBuilt("#built: yes\n" + list))
    }

    func testDirectiveIsToleratedAnywhereAndInAnyCase() {
        XCTAssertFalse(DeckDirectives.isBuilt(list + "\n#BUILT:NO"))
        XCTAssertFalse(DeckDirectives.isBuilt(list + "\n  # Built :  No  "))
        XCTAssertFalse(DeckDirectives.isBuilt("// built: off\n" + list))
    }

    func testFalseyAndTruthySpellings() {
        for no in ["no", "n", "false", "0", "off", "unbuilt"] {
            XCTAssertFalse(DeckDirectives.isBuilt("#built: \(no)"), "\(no) should read as not built")
        }
        for yes in ["yes", "y", "true", "1", "on", "built"] {
            XCTAssertTrue(DeckDirectives.isBuilt("#built: \(yes)"), "\(yes) should read as built")
        }
    }

    func testUnrecognisedValueAssumesBuilt() {
        // Failing toward "built" is the safe direction: it never makes cards you're
        // using look free.
        XCTAssertTrue(DeckDirectives.isBuilt("#built: maybe\n" + list))
    }

    func testSettingAppendsWhenAbsent() {
        let out = DeckDirectives.settingBuilt(false, in: list)
        XCTAssertTrue(out.hasSuffix("#built: no"))
        XCTAssertFalse(DeckDirectives.isBuilt(out))
        XCTAssertTrue(out.hasPrefix(list))   // decklist untouched
    }

    func testSettingReplacesInPlace() {
        let once = DeckDirectives.settingBuilt(false, in: list)
        let twice = DeckDirectives.settingBuilt(true, in: once)
        XCTAssertEqual(twice.components(separatedBy: "\n").filter { $0.contains("built") }.count, 1)
        XCTAssertTrue(DeckDirectives.isBuilt(twice))
    }

    func testLineIndexFindsTheDirectiveRow() {
        // The app writes one cell rather than rewriting the tab, so the row matters.
        let lines = ["Pokémon: 1", "4 Charizard ex OBF 125", "#built: no"]
        XCTAssertEqual(DeckDirectives.lineIndex(of: "built", in: lines), 2)
        XCTAssertNil(DeckDirectives.lineIndex(of: "built", in: ["4 Iono PAL 185"]))
    }

    func testDeckListReadsAndOverridesTheFlag() {
        let deck = DeckList(name: "Someday", text: "#built: no\n" + list)
        XCTAssertFalse(deck.isBuilt)
        XCTAssertEqual(deck.tabTitle, "Deck: Someday")
        XCTAssertTrue(deck.setting(isBuilt: true).isBuilt)
        XCTAssertEqual(deck.setting(isBuilt: true).text, deck.text)   // text is untouched
    }

    func testDeckListKeepsTheTabTitleVerbatim() {
        // Round-tripping through "Deck: " + name would lose unusual spacing, and the
        // title is what the write targets.
        let deck = DeckList(name: "Zard", text: list, tabTitle: "Deck:Zard")
        XCTAssertEqual(deck.tabTitle, "Deck:Zard")
    }
}
