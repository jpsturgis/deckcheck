import XCTest
@testable import DeckCheckCore

final class GoogleSheetsTests: XCTestCase {
    let token = "at-123"
    let ref = SheetRef(spreadsheetId: "SS1", sheetId: 42, title: "Inventory")
    let layout = SheetLayout.canonical

    func json(_ spec: HTTPRequestSpec) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: spec.body ?? Data())) as? [String: Any] ?? [:]
    }

    // ── A1 helpers ────────────────────────────────────────────────────────────

    func testColumnLetter() {
        XCTAssertEqual(GoogleSheets.columnLetter(0), "A")
        XCTAssertEqual(GoogleSheets.columnLetter(4), "E")   // qty in canonical layout
        XCTAssertEqual(GoogleSheets.columnLetter(25), "Z")
        XCTAssertEqual(GoogleSheets.columnLetter(26), "AA")
        XCTAssertEqual(GoogleSheets.columnLetter(51), "AZ")
    }

    // ── onboarding ────────────────────────────────────────────────────────────

    func testCreateSpreadsheetRequestMakesAnInventoryTab() {
        let req = GoogleSheets.createSpreadsheetRequest(accessToken: token)
        XCTAssertEqual(req.method, .post)
        XCTAssertEqual(req.url.absoluteString, "https://sheets.googleapis.com/v4/spreadsheets")
        XCTAssertEqual(req.headers["Authorization"], "Bearer at-123")
        let body = json(req)
        let sheets = body["sheets"] as? [[String: Any]]
        let title = (sheets?.first?["properties"] as? [String: Any])?["title"] as? String
        XCTAssertEqual(title, "Inventory")
    }

    func testParseSpreadsheetFindsInventorySheetId() throws {
        let data = Data(#"""
        {"spreadsheetId":"SS9","sheets":[
          {"properties":{"sheetId":0,"title":"Sheet1"}},
          {"properties":{"sheetId":77,"title":"Inventory"}}
        ]}
        """#.utf8)
        let r = try GoogleSheets.parseSpreadsheet(data)
        XCTAssertEqual(r, SheetRef(spreadsheetId: "SS9", sheetId: 77, title: "Inventory"))
    }

    func testParseSpreadsheetThrowsWhenNoInventoryTab() {
        let data = Data(#"{"spreadsheetId":"SS9","sheets":[{"properties":{"sheetId":0,"title":"Sheet1"}}]}"#.utf8)
        XCTAssertThrowsError(try GoogleSheets.parseSpreadsheet(data)) {
            XCTAssertEqual($0 as? SheetsError, .inventoryTabMissing)
        }
    }

    func testWriteHeaderRequestWritesCanonicalHeaderToA1() {
        let req = GoogleSheets.writeHeaderRequest(ref: ref, accessToken: token)
        XCTAssertEqual(req.method, .put)
        XCTAssertTrue(req.url.absoluteString.contains("/values/Inventory!A1?valueInputOption=RAW"))
        let values = json(req)["values"] as? [[String]]
        XCTAssertEqual(values?.first, InventoryRow.canonicalHeader)
    }

    // ── read ──────────────────────────────────────────────────────────────────

    func testReadRequestGetsTheWholeTabUnformatted() {
        let req = GoogleSheets.readRequest(ref: ref, accessToken: token)
        XCTAssertEqual(req.method, .get)
        XCTAssertEqual(req.url.absoluteString,
            "https://sheets.googleapis.com/v4/spreadsheets/SS1/values/Inventory?valueRenderOption=UNFORMATTED_VALUE")
        XCTAssertEqual(req.headers["Authorization"], "Bearer at-123")
    }

    func testParseValuesCoercesCellsAndRoundTripsThroughSheetTable() throws {
        // qty comes back as a JSON number under UNFORMATTED_VALUE.
        let data = Data(#"""
        {"range":"Inventory","values":[
          ["name","set","code","number","qty","location","card_id","equivalence_key","norm_version"],
          ["Charizard ex","Obsidian Flames","OBF","125",2,"Binder A","sv3-125","char","v1"]
        ]}
        """#.utf8)
        let grid = try GoogleSheets.parseValues(data)
        XCTAssertEqual(grid[1][4], "2") // number 2 → "2", not "2.0"
        let table = SheetTable.parse(values: grid)!
        XCTAssertEqual(table.rows.first?.row.qty, 2)
        XCTAssertEqual(table.rows.first?.row.cardId, "sv3-125")
    }

    func testParseValuesToleratesMissingValues() throws {
        XCTAssertEqual(try GoogleSheets.parseValues(Data(#"{"range":"Inventory"}"#.utf8)), [])
    }

    func testParseValuesTreatsNumericZeroAndOneAsNumbersNotBooleans() throws {
        // Regression: JSONSerialization bridges numbers AND booleans to NSNumber, and
        // NSNumber(1) as? Bool succeeds — so a qty cell of 1 (from an UNFORMATTED_VALUE
        // read of a CSV-imported number) must parse as "1", never "TRUE".
        let data = Data(#"{"values":[["card_id","qty"],["sv7-65",1],["z",0],["y",4]]}"#.utf8)
        let grid = try GoogleSheets.parseValues(data)
        XCTAssertEqual(grid[1][1], "1")   // was "TRUE" → Int 0 before the fix
        XCTAssertEqual(grid[2][1], "0")   // was "FALSE"
        XCTAssertEqual(grid[3][1], "4")
    }

    func testParseSheetTitlesAndDeckFilter() throws {
        let data = Data(#"""
        {"sheets":[
          {"properties":{"title":"Inventory"}},
          {"properties":{"title":"Deck: Zard"}},
          {"properties":{"title":"Gap Check"}},
          {"properties":{"title":"Deck: Control"}}
        ]}
        """#.utf8)
        let titles = try GoogleSheets.parseSheetTitles(data)
        XCTAssertEqual(titles, ["Inventory", "Deck: Zard", "Gap Check", "Deck: Control"])
        XCTAssertEqual(titles.filter { $0.hasPrefix(GoogleSheets.deckTabPrefix) }, ["Deck: Zard", "Deck: Control"])
    }

    func testReadTabRequestSingleQuotesTheTitle() {
        let req = GoogleSheets.readTabRequest(spreadsheetId: "SS1", title: "Deck: Zard", accessToken: "t")
        XCTAssertEqual(req.method, .get)
        XCTAssertEqual(req.headers["Authorization"], "Bearer t")
        // A1 sheet name single-quoted (literal), special chars percent-encoded — Google
        // decodes them back. Quotes stay literal so it reads as an A1 sheet reference.
        XCTAssertTrue(req.url.absoluteString.contains("/values/'Deck%3A%20Zard'"),
                      req.url.absoluteString)
        XCTAssertTrue(req.url.absoluteString.contains("valueRenderOption=UNFORMATTED_VALUE"))
    }

    func testGapCheckReportRowsHasBucketsAndBuyLinks() {
        let deck = "4 Charizard ex OBF 125\n4 Iono PAL 185"
        let owned = [OwnedCard(cardId: "ptcg:obf-125", equivalenceKey: "char", qty: 4)] // have char, missing iono
        let rows = GoogleSheets.gapCheckReportRows(
            GapChecker.check(decklist: deck, owned: owned, catalog: Fixture.catalog))
        XCTAssertTrue(rows.first?.first?.hasPrefix("Buildable") ?? false)
        XCTAssertTrue(rows.contains { $0[0] == "❌ Missing" })
        let iono = rows.first { $0[0].contains("Iono") }
        XCTAssertNotNil(iono)
        XCTAssertTrue(iono?[1].hasPrefix("=HYPERLINK(") ?? false) // TCGplayer link in the 2nd column
        XCTAssertTrue(rows.contains { $0[0].contains("Charizard") })  // have bucket
    }

    func testGapCheckTabRequests() throws {
        let write = GoogleSheets.writeRangeRequest(spreadsheetId: "SS1", range: "'Gap Check'!C1",
                                                   values: [["x", "y"]], accessToken: "t", userEntered: true)
        XCTAssertEqual(write.method, .put)
        XCTAssertTrue(write.url.absoluteString.contains("valueInputOption=USER_ENTERED"))

        let clear = GoogleSheets.clearRangeRequest(spreadsheetId: "SS1", range: "'Gap Check'!C:D", accessToken: "t")
        XCTAssertEqual(clear.method, .post)
        XCTAssertTrue(clear.url.absoluteString.hasSuffix(":clear"))

        let add = GoogleSheets.addSheetRequest(spreadsheetId: "SS1", title: "Gap Check", accessToken: "t")
        XCTAssertTrue(add.url.absoluteString.hasSuffix("/SS1:batchUpdate"))
        let body = (try? JSONSerialization.jsonObject(with: add.body ?? Data())) as? [String: Any]
        let requests = body?["requests"] as? [[String: Any]]
        let title = ((requests?.first?["addSheet"] as? [String: Any])?["properties"] as? [String: Any])?["title"] as? String
        XCTAssertEqual(title, "Gap Check")
    }

    func testCreateSpreadsheetIncludesGapCheckTab() {
        let body = json(GoogleSheets.createSpreadsheetRequest(accessToken: "t"))
        let titles = (body["sheets"] as? [[String: Any]])?.compactMap { ($0["properties"] as? [String: Any])?["title"] as? String }
        XCTAssertEqual(titles, ["Inventory", "Gap Check"])
    }

    func testGenuineBooleanCellsStillRenderTrueFalse() throws {
        let data = Data(#"{"values":[["a","b"],[true,false]]}"#.utf8)
        let grid = try GoogleSheets.parseValues(data)
        XCTAssertEqual(grid[1], ["TRUE", "FALSE"])
    }

    func testQtyOfOneSurvivesReadIntoSheetTable() throws {
        // End-to-end of the actual bug: Alcremie qty 1 must land as qty 1 (owned), so
        // the Cards view's `qty > 0` filter keeps it instead of dropping it.
        let data = Data(#"""
        {"values":[
          ["name","set","code","number","qty","location","card_id","equivalence_key","norm_version"],
          ["Alcremie","Stellar Crown","SCR",65,1,"","sv7-65","a3f3165d79d3a4fa","v1"]
        ]}
        """#.utf8)
        let table = SheetTable.parse(values: try GoogleSheets.parseValues(data))!
        XCTAssertEqual(table.rows.first?.row.qty, 1)
        XCTAssertEqual(table.rows.first?.row.owned?.qty, 1)
    }

    // ── write: plan → requests ─────────────────────────────────────────────────

    func makeRow(_ cardId: String, qty: Int) -> InventoryRow {
        InventoryRow(name: "N", set: "S", code: "C", number: "1", qty: qty,
                     location: nil, cardId: cardId, equivalenceKey: "k", normVersion: "v1")
    }

    func testEmptyPlanYieldsNoRequests() {
        let plan = SyncPlanner.Plan(ops: [], skippedRemovals: [], unappendable: [])
        XCTAssertTrue(GoogleSheets.applyRequests(plan: plan, ref: ref, layout: layout, accessToken: token).isEmpty)
    }

    func testSetQtyBecomesValuesBatchUpdateAtTheQtyColumn() {
        let plan = SyncPlanner.Plan(ops: [.setQty(sheetRowNumber: 5, cardId: "x", qty: 3)],
                                    skippedRemovals: [], unappendable: [])
        let reqs = GoogleSheets.applyRequests(plan: plan, ref: ref, layout: layout, accessToken: token)
        XCTAssertEqual(reqs.count, 1)
        XCTAssertTrue(reqs[0].url.absoluteString.hasSuffix("/SS1/values:batchUpdate"))
        let data = (json(reqs[0])["data"] as? [[String: Any]]) ?? []
        XCTAssertEqual(data.first?["range"] as? String, "Inventory!E5") // qty is column E
        // qty is written as a NUMBER (so Google's SUM works), not the string "3"
        XCTAssertEqual((data.first?["values"] as? [[Int]])?.first, [3])
        XCTAssertEqual(json(reqs[0])["valueInputOption"] as? String, "RAW")
    }

    func testAppendBecomesValuesAppendWithNumericQty() {
        let plan = SyncPlanner.Plan(ops: [.appendRow(makeRow("new-1", qty: 2))],
                                    skippedRemovals: [], unappendable: [])
        let reqs = GoogleSheets.applyRequests(plan: plan, ref: ref, layout: layout, accessToken: token)
        XCTAssertEqual(reqs.count, 1)
        XCTAssertTrue(reqs[0].url.absoluteString.contains("/values/Inventory!A1:append"))
        XCTAssertTrue(reqs[0].url.absoluteString.contains("insertDataOption=INSERT_ROWS"))
        // canonical order: name,set,code,number,qty,location,card_id,equivalence_key,norm_version
        let row = (json(reqs[0])["values"] as? [[Any]])?.first
        XCTAssertEqual(row?.count, 9)
        XCTAssertEqual(row?[0] as? String, "N")
        XCTAssertEqual(row?[3] as? String, "1")     // collector number stays text
        XCTAssertEqual(row?[4] as? Int, 2)          // qty is a number → sums natively
        XCTAssertEqual(row?[6] as? String, "new-1") // card_id stays text
    }

    func testFormatInventoryColumnsRequestSetsTextExceptNumericQty() {
        let req = GoogleSheets.formatInventoryColumnsRequest(ref: ref, accessToken: token)
        XCTAssertTrue(req.url.absoluteString.hasSuffix("/SS1:batchUpdate"))
        let requests = (json(req)["requests"] as? [[String: Any]]) ?? []
        func format(_ r: [String: Any]) -> (start: Int?, end: Int?, type: String?) {
            let rc = r["repeatCell"] as? [String: Any]
            let range = rc?["range"] as? [String: Any]
            let nf = ((rc?["cell"] as? [String: Any])?["userEnteredFormat"] as? [String: Any])?["numberFormat"] as? [String: Any]
            return (range?["startColumnIndex"] as? Int, range?["endColumnIndex"] as? Int, nf?["type"] as? String)
        }
        let all = requests.map(format)
        XCTAssertTrue(all.contains { $0.start == 0 && $0.end == 9 && $0.type == "TEXT" })  // everything text
        XCTAssertTrue(all.contains { $0.start == 4 && $0.end == 5 && $0.type == "NUMBER" }) // qty number
    }

    func testDeleteBecomesSpreadsheetBatchUpdateWithZeroBasedRange() {
        let plan = SyncPlanner.Plan(ops: [.deleteRow(sheetRowNumber: 3, cardId: "y")],
                                    skippedRemovals: [], unappendable: [])
        let reqs = GoogleSheets.applyRequests(plan: plan, ref: ref, layout: layout, accessToken: token)
        XCTAssertEqual(reqs.count, 1)
        XCTAssertTrue(reqs[0].url.absoluteString.hasSuffix("/SS1:batchUpdate"))
        let requests = json(reqs[0])["requests"] as? [[String: Any]]
        let range = ((requests?.first?["deleteDimension"] as? [String: Any])?["range"]) as? [String: Any]
        XCTAssertEqual(range?["sheetId"] as? Int, 42)
        XCTAssertEqual(range?["dimension"] as? String, "ROWS")
        XCTAssertEqual(range?["startIndex"] as? Int, 2) // A1 row 3 → zero-based index 2
        XCTAssertEqual(range?["endIndex"] as? Int, 3)
    }

    func testFullPlanEmitsUpdatesThenAppendsThenDeletesInThatOrder() {
        // Mirrors SyncPlanner's write-safe ordering (deletes last, descending).
        let plan = SyncPlanner.Plan(ops: [
            .setQty(sheetRowNumber: 4, cardId: "c", qty: 3),
            .appendRow(makeRow("d", qty: 1)),
            .deleteRow(sheetRowNumber: 3, cardId: "b"),
            .deleteRow(sheetRowNumber: 2, cardId: "a"),
        ], skippedRemovals: [], unappendable: [])
        let reqs = GoogleSheets.applyRequests(plan: plan, ref: ref, layout: layout, accessToken: token)
        XCTAssertEqual(reqs.count, 3)
        XCTAssertTrue(reqs[0].url.absoluteString.hasSuffix("values:batchUpdate")) // updates
        XCTAssertTrue(reqs[1].url.absoluteString.contains(":append"))             // appends
        XCTAssertTrue(reqs[2].url.absoluteString.hasSuffix("/SS1:batchUpdate"))   // deletes
        // both deletes bundled into the one structural batchUpdate, bottom-up
        let requests = json(reqs[2])["requests"] as? [[String: Any]]
        let starts = requests?.compactMap {
            (($0["deleteDimension"] as? [String: Any])?["range"] as? [String: Any])?["startIndex"] as? Int
        }
        XCTAssertEqual(starts, [2, 1]) // row 3 then row 2 → indexes 2, 1
    }

    // ── Catalog resolution index (in-browser gap-check) ────────────

    func testParseAddedSheetId() throws {
        let data = Data(#"{"replies":[{"addSheet":{"properties":{"sheetId":555,"title":"Catalog"}}}]}"#.utf8)
        XCTAssertEqual(try GoogleSheets.parseAddedSheetId(data), 555)
    }

    func testHideSheetRequestSetsHidden() {
        let req = GoogleSheets.hideSheetRequest(spreadsheetId: "SS1", sheetId: 555, accessToken: token)
        let reqs = json(req)["requests"] as? [[String: Any]]
        let props = (reqs?.first?["updateSheetProperties"] as? [String: Any])?["properties"] as? [String: Any]
        XCTAssertEqual(props?["sheetId"] as? Int, 555)
        XCTAssertEqual(props?["hidden"] as? Bool, true)
    }

    func testResizeSheetSetsGridRowAndColumnCount() {
        let req = GoogleSheets.resizeSheetRequest(spreadsheetId: "SS1", sheetId: 555, rows: 23001, accessToken: token)
        let reqs = json(req)["requests"] as? [[String: Any]]
        let props = (reqs?.first?["updateSheetProperties"] as? [String: Any])?["properties"] as? [String: Any]
        let grid = props?["gridProperties"] as? [String: Any]
        XCTAssertEqual(props?["sheetId"] as? Int, 555)
        XCTAssertEqual(grid?["rowCount"] as? Int, 23001)
        XCTAssertEqual(grid?["columnCount"] as? Int, 26)
    }

    func testWriteCatalogIndexClearsThenChunks() {
        // 12 value rows, chunk of 5 → clear + ceil(12/5)=3 writes.
        let values = (0..<12).map { ["id\($0)", "n", "s", "C", "\($0)", "10", "k\($0)"] }
        let reqs = GoogleSheets.writeCatalogIndexRequests(spreadsheetId: "SS1", values: values,
                                                          accessToken: token, chunkRows: 5)
        XCTAssertEqual(reqs.count, 4)
        XCTAssertTrue(reqs[0].url.absoluteString.contains(":clear"))
        // chunk start rows are 1, 6, 11 (RAW, not USER_ENTERED)
        XCTAssertTrue(reqs[1].url.absoluteString.contains("!A1"))
        XCTAssertTrue(reqs[2].url.absoluteString.contains("!A6"))
        XCTAssertTrue(reqs[3].url.absoluteString.contains("!A11"))
        XCTAssertTrue(reqs[1].url.absoluteString.contains("valueInputOption=RAW"))
        // last chunk carries the final 2 rows
        let last = json(reqs[3])["values"] as? [[String]]
        XCTAssertEqual(last?.count, 2)
    }
}
