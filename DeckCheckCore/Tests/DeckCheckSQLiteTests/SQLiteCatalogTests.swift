import XCTest
import SQLite3
@testable import DeckCheckSQLite
import DeckCheckCore

/// Builds the shared test snapshot. `withSearchIndex` mirrors what
/// `tools/build-catalog` writes: the contentless trigram `cards_fts` table, populated
/// with the same apostrophe-folded, lowercased text the builder stamps in.
enum CatalogFixture {
    static func make(withSearchIndex: Bool) throws -> String {
        let path = NSTemporaryDirectory() + "gapcheck-\(UUID().uuidString).sqlite"
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw SQLiteCatalogError.cannotOpen(path: path, message: "open failed")
        }
        defer { sqlite3_close(db) }

        var ddl = """
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

        if withSearchIndex {
            // Same shape and same folding as tools/build-catalog/src/build-catalog.ts:
            // every apostrophe variant dropped, lowercased, one field per line.
            ddl += """
            \nCREATE VIRTUAL TABLE cards_fts USING fts5(text, content='', tokenize='trigram case_sensitive 0');
            INSERT INTO cards_fts(rowid, text)
            SELECT c.rowid,
                   lower(replace(replace(replace(replace(c.name, char(8217), ''), char(8216), ''),
                                         char(700), ''), char(39), ''))
                   || char(10) || lower(s.name)
                   || char(10) || lower(coalesce(s.ptcgo_code, ''))
                   || char(10) || lower(c.number)
                   || char(10) || lower(c.number || '/' || coalesce(s.printed_total, ''))
              FROM cards c JOIN sets s ON c.set_id = s.id;
            """
        }
        guard sqlite3_exec(db, ddl, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteCatalogError.cannotOpen(path: path, message: String(cString: sqlite3_errmsg(db)))
        }
        return path
    }
}

final class SQLiteCatalogTests: XCTestCase {
    var path: String!

    override func setUpWithError() throws {
        path = try CatalogFixture.make(withSearchIndex: false)
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

    func testUnindexedSnapshotReportsNoSearchIndex() throws {
        XCTAssertFalse(try SQLiteCatalog(path: path).hasSearchIndex)
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

/// The FTS5 search index (docs/performance.md). The contract is that it changes only
/// how fast search is, never what it returns — so most of this is a parity check
/// against the same fixture without the index.
final class SQLiteCatalogSearchIndexTests: XCTestCase {
    private var indexedPath: String!
    private var plainPath: String!
    private var indexed: SQLiteCatalog!
    private var plain: SQLiteCatalog!

    override func setUpWithError() throws {
        indexedPath = try CatalogFixture.make(withSearchIndex: true)
        plainPath = try CatalogFixture.make(withSearchIndex: false)
        indexed = try SQLiteCatalog(path: indexedPath)
        plain = try SQLiteCatalog(path: plainPath)
    }

    override func tearDownWithError() throws {
        indexed = nil
        plain = nil
        try? FileManager.default.removeItem(atPath: indexedPath)
        try? FileManager.default.removeItem(atPath: plainPath)
    }

    func testIndexIsDetected() {
        XCTAssertTrue(indexed.hasSearchIndex)
        XCTAssertFalse(plain.hasSearchIndex)
    }

    /// Every query the unindexed path is tested with, plus the awkward ones, must give
    /// the same answer through the index. This is the whole safety argument for the
    /// change: if a query ever diverges, the index is wrong, not just slow.
    func testIndexedResultsMatchTheScanExactly() {
        let queries = [
            "char", "charizard", "CHARIZARD", "PIDGEOT", "nothing",
            "zard",                       // infix — a prefix tokenizer would miss this
            "Arven\u{2019}s Mabosstiff",  // curly (iOS smart quote)
            "Arven's Mabosstiff",         // straight
            "Arvens Mabosstiff",          // none
            "Obsidian Flames", "OBF 125", "Charizard PAF", "125/197",
            "Charizard ZZZ",              // all terms must match → empty
            "ex",                         // shorter than a trigram → scan fallback
            "Charizard ex",               // mixed: one indexed token, one scanned
            "125", "obf", "  char  ",
        ]
        for q in queries {
            let a = indexed.searchByName(q, rowLimit: 100).map(\.cardId).sorted()
            let b = plain.searchByName(q, rowLimit: 100).map(\.cardId).sorted()
            XCTAssertEqual(a, b, "search diverged for \(q.debugDescription)")
        }
    }

    func testInfixSubstringMatches() {
        // The reason the index uses the trigram tokenizer: "zard" has to find
        // "Charizard". `unicode61` (the FTS5 default) returns nothing here.
        XCTAssertEqual(indexed.searchByName("zard", rowLimit: 100).count, 2)
    }

    func testTokensTooShortToIndexStillMatch() {
        // "ex" is two characters — below the trigram minimum, so it falls back to the
        // scan rather than silently matching nothing.
        XCTAssertEqual(indexed.searchByName("ex", rowLimit: 100).count, 4)
    }

    func testMixedShortAndIndexedTokensAreAnded() {
        // "charizard" narrows via the index, "ex" is ANDed on as a LIKE over what's left.
        XCTAssertEqual(indexed.searchByName("charizard ex", rowLimit: 100).map(\.cardId).sorted(),
                       ["ptcg:obf-125", "ptcg:paf-234"])
        XCTAssertTrue(indexed.searchByName("charizard zz", rowLimit: 100).isEmpty)
    }

    func testRowLimitCapsTheIndexedPath() {
        XCTAssertEqual(indexed.searchByName("char", rowLimit: 1).count, 1)
    }

    func testQuoteInQueryDoesNotBreakTheMatchExpression() {
        // A stray double quote would end the FTS5 string literal early if unescaped,
        // turning the rest of the query into syntax. Escaped, a quote is just another
        // character to match on — and no card name contains one, so both paths agree
        // on "nothing", which is the point: no crash, no divergence.
        for q in ["chari\"zard", "\"charizard\"", "\""] {
            XCTAssertEqual(indexed.searchByName(q, rowLimit: 100).map(\.cardId),
                           plain.searchByName(q, rowLimit: 100).map(\.cardId),
                           "search diverged for \(q.debugDescription)")
        }
    }
}

/// Set browsing — the backing for Cards → Sets. The fixture has two sets (OBF with two
/// printings, PAF with two) and its `sets` table predates the per-set legality columns,
/// which is deliberately left alone here: reading legality off the *cards* is what lets
/// an older snapshot keep working.
final class SQLiteCatalogSetBrowsingTests: XCTestCase {
    private var path: String!

    override func setUpWithError() throws { path = try CatalogFixture.make(withSearchIndex: false) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: path) }

    func testSetsCarryCountsAndMetadata() throws {
        let sets = try SQLiteCatalog(path: path).sets()
        XCTAssertEqual(Set(sets.map(\.setId)), ["obf", "paf"])

        let obf = try XCTUnwrap(sets.first { $0.setId == "obf" })
        XCTAssertEqual(obf.name, "Obsidian Flames")
        XCTAssertEqual(obf.ptcgoCode, "OBF")
        XCTAssertEqual(obf.releaseDate, "2023/08/11")
        XCTAssertEqual(obf.printedTotal, 197)
        XCTAssertEqual(obf.catalogCount, 2, "the two OBF printings in the snapshot")
        XCTAssertTrue(obf.standardLegal)
        XCTAssertTrue(obf.expandedLegal)
    }

    /// `catalogCount` is what the progress bar divides by, so it must be the number of
    /// rows actually present — not the printed "/197", which the snapshot can't fill.
    func testCatalogCountIsRowsPresentNotPrintedTotal() throws {
        let obf = try XCTUnwrap(try SQLiteCatalog(path: path).sets().first { $0.setId == "obf" })
        XCTAssertNotEqual(obf.catalogCount, obf.printedTotal)
        XCTAssertEqual(obf.catalogCount, 2)
    }

    func testCardsInSet() throws {
        let cat = try SQLiteCatalog(path: path)
        XCTAssertEqual(cat.cards(setId: "obf").map(\.cardId), ["ptcg:obf-125", "ptcg:obf-197"])
        XCTAssertEqual(cat.cards(setId: "paf").map(\.cardId), ["ptcg:paf-233", "ptcg:paf-234"])
        XCTAssertTrue(cat.cards(setId: "nope").isEmpty)
    }

    /// Collector numbers sort numerically, not as text — otherwise "125" would follow
    /// "9" and a set list would read out of order everywhere past card 9.
    func testCardsInSetSortNumericallyNotLexically() throws {
        let cat = try SQLiteCatalog(path: path)
        XCTAssertEqual(cat.cards(setId: "obf").map(\.number), ["125", "197"])
    }

    func testEndToEndProgressAgainstARealSnapshot() throws {
        let cat = try SQLiteCatalog(path: path)
        let owned = [OwnedCard(cardId: "ptcg:obf-125", equivalenceKey: "char", qty: 3)]

        let obf = try XCTUnwrap(SetCompletion.progress(owned: owned, catalog: cat)
            .first { $0.setId == "obf" })
        XCTAssertEqual(obf.ownedCount, 1)
        XCTAssertEqual(obf.totalCount, 2)

        // The PAF Charizard shares "char" with the OBF one — and still doesn't count.
        let paf = try XCTUnwrap(SetCompletion.progress(owned: owned, catalog: cat)
            .first { $0.setId == "paf" })
        XCTAssertEqual(paf.ownedCount, 0)

        XCTAssertEqual(SetCompletion.missing(inSet: "obf", owned: owned, catalog: cat).map(\.cardId),
                       ["ptcg:obf-197"])
    }
}
