import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// Google Sheets API translation layer (spec v2 §5). The pure, testable half of the
// 2c Sheets client: turn the app's intents — read the inventory, apply a
// SyncPlanner.Plan, create/seed the Inventory sheet at onboarding — into concrete
// HTTPRequestSpecs against the Sheets v4 REST API, and parse the responses. The
// iOS shell (URLSession) just fires these; keeping the request/response mapping
// here means the "SyncOps → real API calls" step is unit-tested off-device.
//
// A Plan (from SyncPlanner, §5.2) maps to at most three calls, in the plan's
// write-safe order: one values:batchUpdate for all setQty edits, one values:append
// for all new rows, one spreadsheet :batchUpdate of deleteDimension for the rows
// that hit qty 0 (bottom-up — the plan already sorts them descending).
// ─────────────────────────────────────────────────────────────────────────────

/// A connected inventory sheet: the spreadsheet file, the numeric id of its
/// "Inventory" tab (deleteDimension needs the numeric sheetId, not the title), and
/// the tab title used to build A1 ranges.
public struct SheetRef: Equatable {
    public let spreadsheetId: String
    public let sheetId: Int
    public let title: String

    public init(spreadsheetId: String, sheetId: Int, title: String = "Inventory") {
        self.spreadsheetId = spreadsheetId; self.sheetId = sheetId; self.title = title
    }
}

public enum SheetsError: Error, Equatable {
    case malformedResponse
    case inventoryTabMissing
}

public enum GoogleSheets {
    static let base = "https://sheets.googleapis.com/v4/spreadsheets"
    public static let inventoryTitle = "Inventory"
    static let spreadsheetTitle = "DeckCheck Inventory"

    // ── onboarding: create + seed the Inventory sheet (§8.2) ─────────────────

    /// Create a new spreadsheet with a single "Inventory" tab. `drive.file` lets the
    /// app create this file; nothing else in the user's Drive is touched.
    /// The prepackaged decklist gap-check tab (spec §7.4). Paste a decklist in column
    /// A; the app writes the report into column C on sync.
    public static let gapCheckTitle = "Gap Check"

    public static func createSpreadsheetRequest(accessToken: String) -> HTTPRequestSpec {
        let body: [String: Any] = [
            "properties": ["title": spreadsheetTitle],
            "sheets": [
                ["properties": ["title": inventoryTitle]],
                ["properties": ["title": gapCheckTitle]],
            ],
        ]
        return jsonRequest(.post, url(base), accessToken: accessToken, json: body)
    }

    // ── sheet gap-check: prepackaged "Gap Check" tab (app-driven, spec §7.4) ──────

    /// Add a tab (used to backfill the Gap Check tab on sheets made before it existed).
    public static func addSheetRequest(spreadsheetId: String, title: String, accessToken: String) -> HTTPRequestSpec {
        jsonRequest(.post, url("\(base)/\(spreadsheetId):batchUpdate"), accessToken: accessToken,
                    json: ["requests": [["addSheet": ["properties": ["title": title]]]]])
    }

    /// Seed the Gap Check tab with a one-line instruction in A1.
    public static func seedGapCheckRequest(spreadsheetId: String, accessToken: String) -> HTTPRequestSpec {
        writeRangeRequest(spreadsheetId: spreadsheetId, range: "'\(gapCheckTitle)'!A1",
                          values: [["Paste a TCG Live decklist below ↓  — the gap report appears in column C after you Sync in the app."]],
                          accessToken: accessToken)
    }

    /// Write a value block to a range. USER_ENTERED so HYPERLINK() formulas parse.
    public static func writeRangeRequest(spreadsheetId: String, range: String, values: [[String]],
                                         accessToken: String, userEntered: Bool = false) -> HTTPRequestSpec {
        let opt = userEntered ? "USER_ENTERED" : "RAW"
        return jsonRequest(.put, url("\(base)/\(spreadsheetId)/values/\(encode(range))?valueInputOption=\(opt)"),
                           accessToken: accessToken, json: ["values": values])
    }

    /// Clear a range (used to wipe the old report before writing a fresh one).
    public static func clearRangeRequest(spreadsheetId: String, range: String, accessToken: String) -> HTTPRequestSpec {
        jsonRequest(.post, url("\(base)/\(spreadsheetId)/values/\(encode(range)):clear"),
                    accessToken: accessToken, json: [:])
    }

    /// Format a GapReport into `[textColumn, linkColumn]` rows for the Gap Check tab:
    /// gap-first buckets, with a TCGplayer HYPERLINK for missing/short cards.
    public static func gapCheckReportRows(_ report: GapReport) -> [[String]] {
        var rows: [[String]] = [
            ["Buildable \(report.buildableQty)/\(report.deckTotal) · short \(report.shortTotal)", ""],
            ["", ""],
        ]
        func section(_ title: String, _ entries: [GapEntry], link: Bool) {
            guard !entries.isEmpty else { return }
            rows.append([title, ""])
            for e in entries {
                let text = "  \(e.requiredQty)× \(e.name) (own \(e.ownedQty))\(e.differentPrinting ? " 🔁" : "")"
                var linkCell = ""
                if link, let u = TCGplayerExport.searchURL(cardName: e.name) {
                    linkCell = "=HYPERLINK(\"\(u.absoluteString)\",\"TCGplayer\")"
                }
                rows.append([text, linkCell])
            }
        }
        section("❌ Missing", report.missing, link: true)
        section("⚠️ Short", report.short, link: true)
        section("✅ Have", report.have, link: false)
        if report.basicEnergyQty > 0 { rows.append(["🔋 Basic Energy: \(report.basicEnergyQty) (auto-satisfied)", ""]) }
        if !report.unidentified.isEmpty { rows.append(["❓ Couldn't identify (\(report.unidentified.count))", ""]) }
        return rows
    }

    // ── in-browser gap-check: the hidden "Catalog" resolution index (§7.4 PART 2) ─

    /// The hidden tab the app pushes the slim resolution index into so a bound Apps
    /// Script can resolve decklist lines with the app closed (CatalogIndexExport).
    public static let catalogTitle = "Catalog"

    /// Parse the numeric sheetId of the tab added by an `addSheet` batchUpdate reply —
    /// so the app can then hide it.
    public static func parseAddedSheetId(_ data: Data) throws -> Int {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let replies = obj["replies"] as? [[String: Any]],
              let props = (replies.first?["addSheet"] as? [String: Any])?["properties"] as? [String: Any],
              let sheetId = (props["sheetId"] as? NSNumber)?.intValue else {
            throw SheetsError.malformedResponse
        }
        return sheetId
    }

    /// Hide a tab (the Catalog index is machine scaffolding, not for the human).
    public static func hideSheetRequest(spreadsheetId: String, sheetId: Int, accessToken: String) -> HTTPRequestSpec {
        jsonRequest(.post, url("\(base)/\(spreadsheetId):batchUpdate"), accessToken: accessToken,
                    json: ["requests": [["updateSheetProperties": [
                        "properties": ["sheetId": sheetId, "hidden": true],
                        "fields": "hidden",
                    ]]]])
    }

    /// Grow (or shrink) a tab's grid to `rows` × `columns`. Required before writing the
    /// Catalog index in chunks: `values.update` only auto-extends the grid when the
    /// range's *start* cell is in-bounds, so a chunk starting at e.g. `A5001` on a
    /// 5000-row grid is rejected ("exceeds grid limits"). Pre-sizing to the full row
    /// count keeps every chunk in-bounds.
    public static func resizeSheetRequest(spreadsheetId: String, sheetId: Int, rows: Int,
                                          columns: Int = 26, accessToken: String) -> HTTPRequestSpec {
        jsonRequest(.post, url("\(base)/\(spreadsheetId):batchUpdate"), accessToken: accessToken,
                    json: ["requests": [["updateSheetProperties": [
                        "properties": ["sheetId": sheetId,
                                       "gridProperties": ["rowCount": max(1, rows), "columnCount": max(1, columns)]],
                        "fields": "gridProperties.rowCount,gridProperties.columnCount",
                    ]]]])
    }

    /// (Re)write the whole Catalog tab: clear it, then write the value block (header +
    /// index rows) in row-bounded chunks so no single request carries the full ~23k
    /// rows. RAW so a card name starting with `=`/`+`/`-` isn't read as a formula.
    /// Caller executes the returned requests in order, AFTER `resizeSheetRequest` has
    /// sized the grid to at least `values.count` rows (the tab must already exist).
    public static func writeCatalogIndexRequests(spreadsheetId: String, values: [[String]],
                                                 accessToken: String, chunkRows: Int = 5000) -> [HTTPRequestSpec] {
        var out: [HTTPRequestSpec] = [
            clearRangeRequest(spreadsheetId: spreadsheetId, range: "'\(catalogTitle)'", accessToken: accessToken),
        ]
        var i = 0, startRow = 1
        let step = max(1, chunkRows)
        while i < values.count {
            let chunk = Array(values[i..<min(i + step, values.count)])
            out.append(writeRangeRequest(spreadsheetId: spreadsheetId,
                                         range: "'\(catalogTitle)'!A\(startRow)",
                                         values: chunk, accessToken: accessToken, userEntered: false))
            i += chunk.count
            startRow += chunk.count
        }
        return out
    }

    /// Parse a spreadsheets.create / .get response into a SheetRef, locating the
    /// "Inventory" tab's numeric sheetId.
    public static func parseSpreadsheet(_ data: Data) throws -> SheetRef {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let spreadsheetId = obj["spreadsheetId"] as? String,
              let sheets = obj["sheets"] as? [[String: Any]] else {
            throw SheetsError.malformedResponse
        }
        for s in sheets {
            guard let props = s["properties"] as? [String: Any],
                  let title = props["title"] as? String, title == inventoryTitle,
                  let sheetId = (props["sheetId"] as? NSNumber)?.intValue else { continue }
            return SheetRef(spreadsheetId: spreadsheetId, sheetId: sheetId, title: title)
        }
        throw SheetsError.inventoryTabMissing
    }

    /// Set column types on the Inventory tab so the sheet is human-friendly and sums
    /// natively: everything is plain **text** (protects leading zeros on collector
    /// numbers, hex equivalence keys, and card_ids from being coerced), except **qty**
    /// which is a **number** (so a browser `=SUM(qty)` works). Applied at creation.
    public static func formatInventoryColumnsRequest(ref: SheetRef, accessToken: String) -> HTTPRequestSpec {
        func fmt(_ start: Int, _ end: Int, _ numberFormat: [String: Any]) -> [String: Any] {
            ["repeatCell": [
                "range": ["sheetId": ref.sheetId, "startColumnIndex": start, "endColumnIndex": end],
                "cell": ["userEnteredFormat": ["numberFormat": numberFormat]],
                "fields": "userEnteredFormat.numberFormat",
            ]]
        }
        // columns (§5.1 order): 0 name,1 set,2 code,3 number,4 qty,5 location,6 card_id,
        // 7 equivalence_key,8 norm_version.
        let requests: [[String: Any]] = [
            fmt(0, 9, ["type": "TEXT"]),
            fmt(4, 5, ["type": "NUMBER", "pattern": "0"]),
        ]
        return jsonRequest(.post, url("\(base)/\(ref.spreadsheetId):batchUpdate"),
                           accessToken: accessToken, json: ["requests": requests])
    }

    /// Write the canonical header row into a freshly-created Inventory tab (§5.1).
    public static func writeHeaderRequest(ref: SheetRef, accessToken: String) -> HTTPRequestSpec {
        let range = "\(ref.title)!A1"
        return jsonRequest(.put,
                           url("\(base)/\(ref.spreadsheetId)/values/\(encode(range))?valueInputOption=RAW"),
                           accessToken: accessToken,
                           json: ["values": [InventoryRow.canonicalHeader]])
    }

    // ── read: hydrate the local read-cache (§5.3) ────────────────────────────

    /// Read the whole Inventory tab. The response parses to `[[String]]` → feed
    /// `SheetTable.parse` → the gap-check/search read-cache.
    public static func readRequest(ref: SheetRef, accessToken: String) -> HTTPRequestSpec {
        // UNFORMATTED_VALUE so qty comes back as a number we stringify (not "1.00").
        let range = "\(ref.title)"
        return HTTPRequestSpec(
            method: .get,
            url: url("\(base)/\(ref.spreadsheetId)/values/\(encode(range))?valueRenderOption=UNFORMATTED_VALUE"),
            headers: ["Authorization": "Bearer \(accessToken)"]
        )
    }

    /// Parse a values.get response `{ values: [[...]] }` into a string grid,
    /// coercing numeric/bool cells to their string form. Missing `values` → empty.
    public static func parseValues(_ data: Data) throws -> [[String]] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SheetsError.malformedResponse
        }
        let rows = obj["values"] as? [[Any]] ?? []
        return rows.map { $0.map(cellString) }
    }

    // ── decks: read the hand-maintained "Deck: <name>" tabs (in-use feature) ─────

    /// Tabs whose title starts with this are treated as decks (their content is a
    /// pasted TCG Live decklist).
    public static let deckTabPrefix = "Deck:"

    /// List the spreadsheet's tab titles — to discover Deck: tabs.
    public static func sheetTitlesRequest(ref: SheetRef, accessToken: String) -> HTTPRequestSpec {
        HTTPRequestSpec(
            method: .get,
            url: url("\(base)/\(ref.spreadsheetId)?fields=\(encode("sheets.properties.title"))"),
            headers: ["Authorization": "Bearer \(accessToken)"]
        )
    }

    public static func parseSheetTitles(_ data: Data) throws -> [String] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sheets = obj["sheets"] as? [[String: Any]] else { throw SheetsError.malformedResponse }
        return sheets.compactMap { ($0["properties"] as? [String: Any])?["title"] as? String }
    }

    /// Fetch each tab's title + numeric sheetId — needed to hide/delete a tab by id.
    public static func sheetPropertiesRequest(spreadsheetId: String, accessToken: String) -> HTTPRequestSpec {
        HTTPRequestSpec(
            method: .get,
            url: url("\(base)/\(spreadsheetId)?fields=\(encode("sheets.properties(sheetId,title)"))"),
            headers: ["Authorization": "Bearer \(accessToken)"]
        )
    }

    /// Parse `sheets.properties(sheetId,title)` into a title → sheetId map.
    public static func parseSheetIds(_ data: Data) throws -> [String: Int] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sheets = obj["sheets"] as? [[String: Any]] else { throw SheetsError.malformedResponse }
        var out: [String: Int] = [:]
        for s in sheets {
            if let p = s["properties"] as? [String: Any],
               let t = p["title"] as? String, let id = (p["sheetId"] as? NSNumber)?.intValue {
                out[t] = id
            }
        }
        return out
    }

    /// Delete a tab by numeric sheetId (used to remove the hidden Catalog tab when the
    /// user turns in-browser gap-check off).
    public static func deleteSheetRequest(spreadsheetId: String, sheetId: Int, accessToken: String) -> HTTPRequestSpec {
        jsonRequest(.post, url("\(base)/\(spreadsheetId):batchUpdate"), accessToken: accessToken,
                    json: ["requests": [["deleteSheet": ["sheetId": sheetId]]]])
    }

    /// Read a specific tab's values (whole tab). A1 sheet names with spaces/`:` must be
    /// single-quoted, so deck tab titles are wrapped before encoding.
    public static func readTabRequest(spreadsheetId: String, title: String, accessToken: String) -> HTTPRequestSpec {
        let range = "'\(title.replacingOccurrences(of: "'", with: "''"))'"
        return HTTPRequestSpec(
            method: .get,
            url: url("\(base)/\(spreadsheetId)/values/\(encode(range))?valueRenderOption=UNFORMATTED_VALUE"),
            headers: ["Authorization": "Bearer \(accessToken)"]
        )
    }

    // ── write: execute a reconciliation plan (§5.2) ──────────────────────────

    /// Translate a SyncPlanner.Plan into ordered Sheets API requests: value updates,
    /// then appends, then row deletes (bottom-up). At most one request per kind; an
    /// empty plan yields no requests.
    public static func applyRequests(plan: SyncPlanner.Plan, ref: SheetRef,
                                     layout: SheetLayout, accessToken: String) -> [HTTPRequestSpec] {
        var out: [HTTPRequestSpec] = []

        // 1) setQty → one values:batchUpdate targeting each qty cell. qty is written as
        //    a NUMBER (RAW + numeric value) so it stores as a numeric cell — otherwise a
        //    RAW string "4" is text, which Google's SUM silently skips (§5.1).
        let qtyCol = layout.index(of: .qty).map(columnLetter)
        let updates: [[String: Any]] = plan.ops.compactMap { op in
            guard case let .setQty(rowNumber, _, qty) = op, let col = qtyCol else { return nil }
            return ["range": "\(ref.title)!\(col)\(rowNumber)", "values": [[qty]]]
        }
        if !updates.isEmpty {
            out.append(jsonRequest(.post, url("\(base)/\(ref.spreadsheetId)/values:batchUpdate"),
                                   accessToken: accessToken,
                                   json: ["valueInputOption": "RAW", "data": updates]))
        }

        // 2) appendRow → one values:append with the new rows in layout order. The qty
        //    cell is a number (see above); the rest stay strings (ids/keys are text).
        let appends: [[Any]] = plan.ops.compactMap { op -> [Any]? in
            guard case let .appendRow(row) = op else { return nil }
            var cells: [Any] = layout.serialize(row)
            if let qi = layout.index(of: .qty) { cells[qi] = row.qty }
            return cells
        }
        if !appends.isEmpty {
            let range = "\(ref.title)!A1"
            out.append(jsonRequest(.post,
                url("\(base)/\(ref.spreadsheetId)/values/\(encode(range)):append?valueInputOption=RAW&insertDataOption=INSERT_ROWS"),
                accessToken: accessToken,
                json: ["values": appends]))
        }

        // 3) deleteRow → one spreadsheet :batchUpdate of deleteDimension requests,
        //    in the plan's descending row order (bottom-up, so indexes stay valid).
        let deletes: [[String: Any]] = plan.ops.compactMap { op in
            guard case let .deleteRow(rowNumber, _) = op else { return nil }
            return ["deleteDimension": ["range": [
                "sheetId": ref.sheetId, "dimension": "ROWS",
                "startIndex": rowNumber - 1, "endIndex": rowNumber, // zero-based, half-open
            ]]]
        }
        if !deletes.isEmpty {
            out.append(jsonRequest(.post, url("\(base)/\(ref.spreadsheetId):batchUpdate"),
                                   accessToken: accessToken, json: ["requests": deletes]))
        }

        return out
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    /// 0-based column index → A1 letters (0→A, 25→Z, 26→AA).
    public static func columnLetter(_ index: Int) -> String {
        var n = index, s = ""
        repeat {
            s = String(UnicodeScalar(UInt8(65 + n % 26))) + s
            n = n / 26 - 1
        } while n >= 0
        return s
    }

    private static func cellString(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber {
            // JSONSerialization bridges BOTH JSON booleans and JSON numbers to
            // NSNumber, and `NSNumber(1) as? Bool` succeeds — so a standalone
            // `as? Bool` check turns a numeric cell of 0 or 1 into "FALSE"/"TRUE",
            // which then parses to Int 0 (e.g. a qty of 1 silently becomes 0).
            // Distinguish a genuine boolean from a number via CFBoolean instead.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "TRUE" : "FALSE" }
            // integers without a trailing ".0"
            if n.doubleValue == n.doubleValue.rounded() { return String(n.intValue) }
            return n.stringValue
        }
        return ""
    }

    private static func url(_ s: String) -> URL { URL(string: s)! }
    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }
    private static func jsonRequest(_ method: HTTPRequestSpec.Method, _ url: URL,
                                    accessToken: String, json: [String: Any]) -> HTTPRequestSpec {
        HTTPRequestSpec(
            method: method,
            url: url,
            headers: ["Authorization": "Bearer \(accessToken)", "Content-Type": "application/json"],
            body: try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        )
    }
}
