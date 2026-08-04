import XCTest
import SQLite3
@testable import DeckCheckSQLite
import DeckCheckCore

final class SQLiteCatalogTests: XCTestCase {
    var path: String!

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "gapcheck-\(UUID().uuidString).sqlite"
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let ddl = """
        CREATE TABLE sets(id TEXT PRIMARY KEY, name TEXT, ptcgo_code TEXT, printed_total INTEGER, release_date TEXT);
        CREATE TABLE cards(card_id TEXT, set_id TEXT, number TEXT, name TEXT, supertype TEXT,
          subtypes TEXT, equivalence_key TEXT, standard_legal INTEGER, expanded_legal INTEGER,
          regulation_mark TEXT, image_small TEXT, image_large TEXT, attributes TEXT);
        INSERT INTO sets VALUES ('obf','Obsidian Flames','OBF',197,'2023/08/11'), ('paf','Paldean Fates','PAF',91,'2024/01/26');
        INSERT INTO cards VALUES
          ('ptcg:obf-125','obf','125','Charizard ex','Pokémon','["Stage 2","ex"]','char',1,1,'G','http://img/obf125.png','http://img/obf125_lg.png','{"hp":"330"}'),
          ('ptcg:paf-234','paf','234','Charizard ex','Pokémon','["Stage 2","ex"]','char',1,1,'H',NULL,NULL,'{"hp":"330"}'),
          ('ptcg:obf-197','obf','197','Pidgeot ex','Pokémon','["Stage 2","ex"]','pidgeot',1,1,'G',NULL,NULL,'{"hp":"280"}'),
          ('ptcg:paf-233','paf','233','Arven''s Mabosstiff ex','Pokémon','[]','arvenmabo',1,1,'H',NULL,NULL,'{}');
        """
        XCTAssertEqual(sqlite3_exec(db, ddl, nil, nil, nil), SQLITE_OK)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: path)
    }

    func testSetCodePlusNumber() throws {
        let cat = try SQLiteCatalog(path: path)
        let hits = cat.cards(setCode: "OBF", number: "125")
        XCTAssertEqual(hits.count, 1)
        let c = hits[0]
        XCTAssertEqual(c.cardId, "ptcg:obf-125")
        XCTAssertEqual(c.setName, "Obsidian Flames")
        XCTAssertEqual(c.equivalenceKey, "char")
        XCTAssertEqual(c.supertype, .pokemon)
        XCTAssertTrue(c.standardLegal)
        XCTAssertEqual(c.regulationMark, "G")
    }

    func testSetCodeIsCaseInsensitive() throws {
        let cat = try SQLiteCatalog(path: path)
        XCTAssertEqual(cat.cards(setCode: "obf", number: "125").count, 1)
    }

    func testNumberOnlySpansSets() throws {
        let cat = try SQLiteCatalog(path: path)
        XCTAssertEqual(cat.cards(number: "234").first?.cardId, "ptcg:paf-234")
    }

    func testCardById() throws {
        let cat = try SQLiteCatalog(path: path)
        let c = try XCTUnwrap(cat.card(byId: "ptcg:paf-234"))
        XCTAssertEqual(c.ptcgoCode, "PAF")
        XCTAssertEqual(c.equivalenceKey, "char") // same functional key as the OBF printing
    }

    func testMissWhenNoMatch() throws {
        let cat = try SQLiteCatalog(path: path)
        XCTAssertTrue(cat.cards(setCode: "ZZZ", number: "999").isEmpty)
        XCTAssertNil(cat.card(byId: "ptcg:nope-1"))
    }

    func testOpenNonexistentFileThrows() {
        XCTAssertThrowsError(try SQLiteCatalog(path: "/no/such/catalog.sqlite"))
    }

    func testSearchByNameIsCaseInsensitiveSubstring() throws {
        let cat = try SQLiteCatalog(path: path)
        let charizards = cat.searchByName("char", rowLimit: 100)
        XCTAssertEqual(charizards.count, 2)                       // both Charizard ex printings
        XCTAssertEqual(Set(charizards.map(\.equivalenceKey)), ["char"])
        XCTAssertEqual(cat.searchByName("PIDGEOT", rowLimit: 100).count, 1)
        XCTAssertTrue(cat.searchByName("nothing", rowLimit: 100).isEmpty)
    }

    func testSearchRowLimitCaps() throws {
        let cat = try SQLiteCatalog(path: path)
        XCTAssertEqual(cat.searchByName("char", rowLimit: 1).count, 1)
    }

    func testSearchIgnoresApostropheStyle() throws {
        // Stored with a straight apostrophe; all three query forms must find it.
        let cat = try SQLiteCatalog(path: path)
        XCTAssertEqual(cat.searchByName("Arven\u{2019}s Mabosstiff", rowLimit: 100).count, 1) // curly (iOS smart-quote)
        XCTAssertEqual(cat.searchByName("Arven's Mabosstiff", rowLimit: 100).count, 1)          // straight
        XCTAssertEqual(cat.searchByName("Arvens Mabosstiff", rowLimit: 100).count, 1)           // none
    }

    func testSearchMatchesSetNameSetCodeAndNumber() throws {
        let cat = try SQLiteCatalog(path: path)
        // Set name → every card in the set.
        XCTAssertEqual(cat.searchByName("Obsidian Flames", rowLimit: 100).map(\.cardId).sorted(),
                       ["ptcg:obf-125", "ptcg:obf-197"])
        // Set code + number narrows to the one printing.
        XCTAssertEqual(cat.searchByName("OBF 125", rowLimit: 100).map(\.cardId), ["ptcg:obf-125"])
        // Name + set code picks the specific printing out of the equivalence group.
        XCTAssertEqual(cat.searchByName("Charizard PAF", rowLimit: 100).map(\.cardId), ["ptcg:paf-234"])
        // Full number/printedTotal.
        XCTAssertEqual(cat.searchByName("125/197", rowLimit: 100).map(\.cardId), ["ptcg:obf-125"])
    }

    func testSearchAllTermsMustMatch() throws {
        let cat = try SQLiteCatalog(path: path)
        XCTAssertTrue(cat.searchByName("Charizard ZZZ", rowLimit: 100).isEmpty)
    }

    func testHPSurfacedFromAttributesJSON() throws {
        // hp lives in the attributes JSON, pulled out via json_extract.
        let cat = try SQLiteCatalog(path: path)
        XCTAssertEqual(cat.card(byId: "ptcg:obf-125")?.hp, "330")
        XCTAssertNil(cat.card(byId: "ptcg:paf-233")?.hp)   // no hp key → nil
    }

    func testSubtypesParsedFromJSONArray() throws {
        // subtypes is a JSON array column; it feeds ErrataBridge's grouping.
        let cat = try SQLiteCatalog(path: path)
        XCTAssertEqual(cat.card(byId: "ptcg:obf-125")?.subtypes, ["Stage 2", "ex"])
        XCTAssertEqual(cat.card(byId: "ptcg:paf-233")?.subtypes, [])   // empty array → []
    }

    func testPrintedTotalLookupAndNewColumns() throws {
        let cat = try SQLiteCatalog(path: path)
        let hits = cat.cards(printedTotal: 197, number: "125")   // the "/197" set-pin
        XCTAssertEqual(hits.first?.cardId, "ptcg:obf-125")
        XCTAssertEqual(hits.first?.printedTotal, 197)
        XCTAssertEqual(hits.first?.imageSmall, "http://img/obf125.png")
        XCTAssertEqual(hits.first?.imageLarge, "http://img/obf125_lg.png")
        XCTAssertNil(cat.card(byId: "ptcg:paf-234")?.imageSmall) // NULL image → nil
        XCTAssertTrue(cat.cards(printedTotal: 999, number: "125").isEmpty)
    }

    func testCardsByEquivalenceKey() throws {
        let cat = try SQLiteCatalog(path: path)
        let group = cat.cards(equivalenceKey: "char")
        XCTAssertEqual(group.count, 2)                       // both Charizard ex printings
        // Newest set first: PAF (2024/01/26) ahead of OBF (2023/08/11).
        XCTAssertEqual(group.map(\.cardId), ["ptcg:paf-234", "ptcg:obf-125"])
        XCTAssertEqual(group.first?.releaseDate, "2024/01/26")
        XCTAssertTrue(cat.cards(equivalenceKey: "nope").isEmpty)
    }

    func testAllCardsEnumeratesEveryPrinting() throws {
        let cat = try SQLiteCatalog(path: path)
        let all = cat.allCards()
        XCTAssertEqual(all.count, 4)
        XCTAssertEqual(Set(all.map(\.cardId)),
                       ["ptcg:obf-125", "ptcg:paf-234", "ptcg:obf-197", "ptcg:paf-233"])
        // Feeds the resolution index: the seven slim columns line up.
        let index = CatalogIndexExport.rows(all)
        XCTAssertEqual(index.count, 4)
        let charOBF = try XCTUnwrap(index.first { $0[0] == "ptcg:obf-125" })
        XCTAssertEqual(charOBF, ["ptcg:obf-125", "Charizard ex", "Obsidian Flames", "OBF", "125", "197", "char"])
    }
}
