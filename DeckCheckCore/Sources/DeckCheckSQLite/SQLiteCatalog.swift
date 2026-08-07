import Foundation
import SQLite3
import DeckCheckCore

/// A `CatalogLookup` backed by the bundled read-only SQLite snapshot built by
/// `tools/build-catalog`. Read-only; safe to share. The SwiftUI app can reuse
/// this verbatim over the app-bundled snapshot; the `gapcheck` CLI uses it over a
/// file path.
///
/// **Concurrency.** This is already reached from more than one thread — Scan resolves
/// OCR results on a background task while views query the same connection on the main
/// thread — so the sharing is stated here rather than left accidental. It's safe
/// because the connection is opened read-only, both stored properties are immutable,
/// and Apple's SQLite is built in serialized mode, which mutexes a connection
/// internally. `@unchecked` because none of that is something the compiler can see.
public final class SQLiteCatalog: CatalogLookup, CatalogSearching, CatalogSetBrowsing, @unchecked Sendable {
    private let db: OpaquePointer

    /// Whether this snapshot carries the `cards_fts` search index. Detected rather
    /// than assumed: the catalog is built separately from the app, so a snapshot
    /// predating the index is a normal thing to be handed. Without it, search falls
    /// back to the LIKE scan — same answers, just slower.
    public let hasSearchIndex: Bool

    public init(path: String) throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            if let handle { sqlite3_close(handle) }
            throw SQLiteCatalogError.cannotOpen(path: path, message: message)
        }
        db = handle
        hasSearchIndex = Self.tableExists("cards_fts", in: handle)
    }

    private static func tableExists(_ name: String, in db: OpaquePointer) -> Bool {
        var stmt: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW
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

    /// Same apostrophe-folding `likePerToken` uses for name search — an evolution
    /// chain's `evolvesFrom` text and the ancestor's own `c.name` come from the same
    /// TCGdex source but aren't guaranteed to be typed identically byte-for-byte.
    public func cards(name: String) -> [CatalogCard] {
        query("REPLACE(REPLACE(c.name, char(8217), ''), char(39), '')"
              + " = REPLACE(REPLACE(?1, char(8217), ''), char(39), '') COLLATE NOCASE", [name])
    }

    // MARK: CatalogSearching

    /// The shortest pattern the `trigram` tokenizer can match. A shorter token isn't an
    /// error — FTS5 just returns nothing for it, which would be a silently wrong
    /// answer, so those tokens go through LIKE instead.
    private static let minIndexedToken = 3

    public func searchByName(_ query: String, rowLimit: Int) -> [CatalogCard] {
        // Multi-term match (SearchMatch): each whitespace token must match at least one
        // field — name / set name / set code / number / number-slash-total — and all
        // tokens must match, so terms are optional and narrow progressively.
        let tokens = SearchMatch.tokens(query)
        guard !tokens.isEmpty else { return [] }

        // Tokens of 3+ characters go to the trigram index; anything shorter keeps the
        // scan. A mixed query still wins: the index narrows the rows first, so the LIKE
        // for the short token runs over what survived rather than the whole table.
        let indexed = tokens.filter { $0.count >= Self.minIndexedToken }
        guard hasSearchIndex, !indexed.isEmpty else {
            return likeSearch(tokens, rowLimit: rowLimit)
        }
        return indexedSearch(indexed: indexed,
                             scanned: tokens.filter { $0.count < Self.minIndexedToken },
                             rowLimit: rowLimit)
    }

    /// Search via the `cards_fts` trigram index. `indexed` tokens are matched by the
    /// index; `scanned` tokens (too short to index) are ANDed on as LIKE predicates.
    private func indexedSearch(indexed: [String], scanned: [String], rowLimit: Int) -> [CatalogCard] {
        // Each token is one FTS5 string literal — with trigram, a quoted string matches
        // as a substring, which is exactly the LIKE '%token%' semantics being replaced.
        // `"` is the only character needing escaping inside one, by doubling it.
        let match = indexed
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: " AND ")

        // Unaliased on purpose: some SQLite builds reject `alias MATCH ?`.
        var clauses = ["cards_fts MATCH ?1"]
        clauses.append(contentsOf: Array(repeating: Self.likePerToken, count: scanned.count))
        let sql = Self.selectColumns + Self.searchFrom + clauses.joined(separator: " AND ")
            + " ORDER BY c.name LIMIT ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            // A malformed MATCH or a snapshot whose index is unreadable must not mean
            // "no results" — fall back rather than silently answer wrong.
            return likeSearch(indexed + scanned, rowLimit: rowLimit)
        }
        defer { sqlite3_finalize(stmt) }
        var idx: Int32 = 1
        sqlite3_bind_text(stmt, idx, match, -1, SQLITE_TRANSIENT); idx += 1
        for t in scanned {
            let like = "%\(t)%"
            for _ in 0..<5 { sqlite3_bind_text(stmt, idx, like, -1, SQLITE_TRANSIENT); idx += 1 }
        }
        sqlite3_bind_int(stmt, idx, Int32(rowLimit))
        var rows: [CatalogCard] = []
        while sqlite3_step(stmt) == SQLITE_ROW { rows.append(Self.row(stmt)) }
        return rows
    }

    /// The unindexed path: a full-table LIKE scan across the five searchable
    /// expressions. Correct but slow (~22 ms against a 23k-card snapshot) — kept as the
    /// fallback for snapshots without `cards_fts` and for sub-trigram-length tokens.
    private func likeSearch(_ tokens: [String], rowLimit: Int) -> [CatalogCard] {
        guard !tokens.isEmpty else { return [] }
        let whereClause = Array(repeating: Self.likePerToken, count: tokens.count)
            .joined(separator: " AND ")
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

    /// One token against the five searchable expressions. The name column is
    /// apostrophe-folded to line up with the folded tokens (curly U+2019 / straight
    /// U+0027, which is what iOS smart punctuation and hand typing produce).
    private static let likePerToken =
        "(REPLACE(REPLACE(c.name, char(8217), ''), char(39), '') LIKE ? COLLATE NOCASE"
        + " OR s.name LIKE ? COLLATE NOCASE"
        + " OR s.ptcgo_code LIKE ? COLLATE NOCASE"
        + " OR c.number LIKE ? COLLATE NOCASE"
        + " OR (c.number || '/' || s.printed_total) LIKE ? COLLATE NOCASE)"

    // MARK: CatalogSetBrowsing

    /// Every set that has at least one printing in this snapshot.
    ///
    /// An **INNER** join, so a set the builder recorded but shipped no cards for never
    /// appears — a completion goal of 0/0 is noise. The count is `COUNT(c.card_id)`
    /// rather than the `sets.total` column for the reason `CatalogSet.catalogCount`
    /// documents: the denominator has to be reachable.
    ///
    /// Set legality is `MAX()`ed up from the cards rather than read from
    /// `sets.standard_legal`. Two reasons: it stays true to the printings actually
    /// present, and it works against snapshots built before those columns existed
    /// (including this package's own test fixture) instead of failing to prepare.
    public func sets() -> [CatalogSet] {
        let sql = """
        SELECT s.id, s.name, s.ptcgo_code, s.release_date, s.printed_total,
               COUNT(c.card_id), MAX(c.standard_legal), MAX(c.expanded_legal)
        FROM sets s JOIN cards c ON c.set_id = s.id
        GROUP BY s.id, s.name, s.ptcgo_code, s.release_date, s.printed_total
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        func text(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        func intOrNil(_ i: Int32) -> Int? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, i))
        }

        var out: [CatalogSet] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(CatalogSet(
                setId: text(0) ?? "",
                name: text(1) ?? "",
                ptcgoCode: text(2),
                releaseDate: text(3),
                printedTotal: intOrNil(4),
                catalogCount: Int(sqlite3_column_int64(stmt, 5)),
                standardLegal: sqlite3_column_int64(stmt, 6) == 1,
                expandedLegal: sqlite3_column_int64(stmt, 7) == 1
            ))
        }
        return out
    }

    /// A set's printings in collector-number order. Numeric numbers sort numerically
    /// (so 9 precedes 10, which a plain text sort gets wrong); gallery/trainer-gallery
    /// numbers like "TG12" have no numeric position, so they sort as text after them.
    public func cards(setId: String) -> [CatalogCard] {
        query(Self.setIdWhereOrdered, [setId])
    }

    /// The counting path — see `CatalogSetBrowsing.cardIds(setId:)`. One indexed
    /// column, no JSON parsing, no row construction. `idx_cards_set_number` covers it.
    public func cardIds(setId: String) -> [String] {
        var stmt: OpaquePointer?
        let sql = "SELECT card_id FROM cards WHERE set_id = ?1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, setId, -1, SQLITE_TRANSIENT)
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.append(String(cString: c)) }
        }
        return out
    }

    private static let setIdWhereOrdered = """
    c.set_id = ?1 \
    ORDER BY (CASE WHEN c.number GLOB '[0-9]*' THEN 0 ELSE 1 END), \
    CAST(c.number AS INTEGER), c.number
    """

    // MARK: Provenance

    /// A value from the snapshot's `meta` table, or nil if absent. Tolerates a
    /// snapshot with no `meta` table at all (the test fixtures, older builds).
    public func metaValue(_ key: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?1", -1, &stmt, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    /// The normalization version every `equivalence_key` in this snapshot was computed
    /// under. An inventory row stamped with anything else — including nothing at all —
    /// has a key that predates this catalog. See `InventoryMigration`.
    public var normVersion: String? { metaValue("norm_version") }

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
    // transferring the whole blob or a catalog rebuild. `evolvesFrom` and the
    // ACE SPEC rarity flag are pulled the same way, for deck-list evolution/ace-spec
    // ordering (GapChecker) — appended rather than inserted so every existing column
    // index in `row(_:)` stays put.
    private static let selectColumns = """
    SELECT c.card_id, c.set_id, s.name, s.ptcgo_code, c.number, c.name, c.supertype,
           c.equivalence_key, c.standard_legal, c.expanded_legal, c.regulation_mark,
           c.image_small, s.printed_total, c.image_large, s.release_date,
           json_extract(c.attributes, '$.hp'), c.subtypes,
           json_extract(c.attributes, '$.evolvesFrom'),
           CASE WHEN json_extract(c.attributes, '$.rarity') LIKE 'ACE SPEC%' THEN 1 ELSE 0 END
    """

    private static let selectPrefix = selectColumns + "\n"
        + "FROM cards c JOIN sets s ON c.set_id = s.id\nWHERE"

    /// The search index is contentless — it stores no card data, only the trigrams and
    /// a `rowid` pointing back at `cards`.
    private static let searchFrom = "\n"
        + "FROM cards c JOIN sets s ON c.set_id = s.id"
        + " JOIN cards_fts ON cards_fts.rowid = c.rowid\nWHERE "

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
        /// `subtypes` is a JSON array of strings. Anything unparseable reads as empty,
        /// which only costs precision in the errata bridge — never correctness.
        func stringArray(_ i: Int32) -> [String] {
            guard let raw = text(i), let data = raw.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String]
            else { return [] }
            return parsed
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
            hp: text(15),
            subtypes: stringArray(16),
            evolvesFrom: text(17),
            isAceSpec: flag(18)
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
