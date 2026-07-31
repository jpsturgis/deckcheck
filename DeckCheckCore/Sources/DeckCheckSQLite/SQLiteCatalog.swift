import Foundation
import SQLite3
import DeckCheckCore

/// A `CatalogLookup` backed by the bundled read-only SQLite snapshot built by
/// `tools/build-catalog`. Read-only; safe to share. The SwiftUI app can reuse
/// this verbatim over the app-bundled snapshot; the `gapcheck` CLI uses it over a
/// file path.
public final class SQLiteCatalog: CatalogLookup, CatalogSearching {
    private let db: OpaquePointer

    public init(path: String) throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            if let handle { sqlite3_close(handle) }
            throw SQLiteCatalogError.cannotOpen(path: path, message: message)
        }
        db = handle
    }

    deinit { sqlite3_close(db) }

    // MARK: CatalogLookup

    public func cards(setCode: String, number: String) -> [CatalogCard] {
        query("s.ptcgo_code = ?1 COLLATE NOCASE AND c.number = ?2", [setCode, number])
    }

    public func cards(number: String) -> [CatalogCard] {
        query("c.number = ?1", [number])
    }

    public func cards(printedTotal: Int, number: String) -> [CatalogCard] {
        let sql = Self.selectPrefix + " s.printed_total = ?1 AND c.number = ?2"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(printedTotal))
        sqlite3_bind_text(stmt, 2, number, -1, SQLITE_TRANSIENT)
        var rows: [CatalogCard] = []
        while sqlite3_step(stmt) == SQLITE_ROW { rows.append(Self.row(stmt)) }
        return rows
    }

    public func card(byId cardId: String) -> CatalogCard? {
        query("c.card_id = ?1", [cardId]).first
    }

    public func cards(equivalenceKey: String) -> [CatalogCard] {
        // Newest printing first: most-recent set release, then collector number.
        query("c.equivalence_key = ?1 ORDER BY s.release_date DESC, c.number", [equivalenceKey])
    }

    // MARK: CatalogSearching

    public func searchByName(_ query: String, rowLimit: Int) -> [CatalogCard] {
        // Multi-term match (SearchMatch): each whitespace token must match at least one
        // field — name / set name / set code / number / number-slash-total — and all
        // tokens must match, so terms are optional and narrow progressively. The name
        // column is apostrophe-folded to line up with the folded tokens (curly U+2019 /
        // straight U+0027, which is what iOS smart punctuation and hand typing produce).
        let tokens = SearchMatch.tokens(query)
        guard !tokens.isEmpty else { return [] }
        let name = "REPLACE(REPLACE(c.name, char(8217), ''), char(39), '')"
        let perToken = "(\(name) LIKE ? COLLATE NOCASE"
            + " OR s.name LIKE ? COLLATE NOCASE"
            + " OR s.ptcgo_code LIKE ? COLLATE NOCASE"
            + " OR c.number LIKE ? COLLATE NOCASE"
            + " OR (c.number || '/' || s.printed_total) LIKE ? COLLATE NOCASE)"
        let whereClause = Array(repeating: perToken, count: tokens.count).joined(separator: " AND ")
        let sql = Self.selectPrefix + " " + whereClause + " ORDER BY c.name LIMIT ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var idx: Int32 = 1
        for t in tokens {
            let like = "%\(t)%"
            for _ in 0..<5 { sqlite3_bind_text(stmt, idx, like, -1, SQLITE_TRANSIENT); idx += 1 }
        }
        sqlite3_bind_int(stmt, idx, Int32(rowLimit))
        var rows: [CatalogCard] = []
        while sqlite3_step(stmt) == SQLITE_ROW { rows.append(Self.row(stmt)) }
        return rows
    }

    // MARK: Full enumeration

    /// Every card in the snapshot — used to push the slim resolution index into the
    /// user's sheet for in-browser gap-check. One-shot on
    /// enable/refresh, not a hot path; feed the result to `CatalogIndexExport`.
    public func allCards() -> [CatalogCard] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, Self.selectPrefix + " 1=1", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [CatalogCard] = []
        while sqlite3_step(stmt) == SQLITE_ROW { rows.append(Self.row(stmt)) }
        return rows
    }

    // MARK: - SQL

    // `hp` lives inside the per-card `attributes` JSON (no dedicated column) — pull just
    // that scalar out with json_extract so the recognizer can use it without
    // transferring the whole blob or a catalog rebuild.
    private static let selectPrefix = """
    SELECT c.card_id, c.set_id, s.name, s.ptcgo_code, c.number, c.name, c.supertype,
           c.equivalence_key, c.standard_legal, c.expanded_legal, c.regulation_mark,
           c.image_small, s.printed_total, c.image_large, s.release_date,
           json_extract(c.attributes, '$.hp')
    FROM cards c JOIN sets s ON c.set_id = s.id
    WHERE
    """

    private func query(_ whereClause: String, _ binds: [String]) -> [CatalogCard] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, Self.selectPrefix + " " + whereClause, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in binds.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), value, -1, SQLITE_TRANSIENT)
        }
        var rows: [CatalogCard] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(Self.row(stmt))
        }
        return rows
    }

    private static func row(_ stmt: OpaquePointer?) -> CatalogCard {
        func text(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        func flag(_ i: Int32) -> Bool { sqlite3_column_int64(stmt, i) == 1 }
        func intOrNil(_ i: Int32) -> Int? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, i))
        }

        return CatalogCard(
            cardId: text(0) ?? "",
            setId: text(1) ?? "",
            setName: text(2) ?? "",
            ptcgoCode: text(3),
            number: text(4) ?? "",
            name: text(5) ?? "",
            supertype: Supertype(rawValue: text(6) ?? "") ?? .unknown,
            equivalenceKey: text(7) ?? "",
            standardLegal: flag(8),
            expandedLegal: flag(9),
            regulationMark: text(10),
            printedTotal: intOrNil(12),
            imageSmall: text(11),
            imageLarge: text(13),
            releaseDate: text(14),
            hp: text(15)
        )
    }
}

public enum SQLiteCatalogError: Error, CustomStringConvertible {
    case cannotOpen(path: String, message: String)
    public var description: String {
        switch self {
        case let .cannotOpen(path, message):
            return "cannot open SQLite catalog at \(path): \(message)"
        }
    }
}

// sqlite wants to know whether the bound bytes persist; SQLITE_TRANSIENT tells it to
// copy them, so passing a Swift String's transient C-string is safe.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
