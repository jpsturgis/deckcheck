import XCTest
@testable import DeckCheckCore

/// Re-deriving the Sheet's `equivalence_key` / `norm_version` columns.
///
/// The case that motivates this: real Sheets contain rows whose `norm_version` is
/// **blank** rather than "v1" — an artefact of the poke-check → deckcheck migration.
/// A blank stamp says nothing about whether the row's key is current, so it has to
/// count as stale. Skipping blanks (the easy mistake — comparing only non-empty
/// stamps) leaves exactly those rows unmigrated forever.
final class InventoryMigrationTests: XCTestCase {

    private let catalog = FakeCatalog(all: [
        CatalogCard(cardId: "obf-125", setId: "obf", setName: "Obsidian Flames", ptcgoCode: "OBF",
                    number: "125", name: "Charizard ex", supertype: .pokemon,
                    equivalenceKey: "key-charizard", standardLegal: true, expandedLegal: true,
                    regulationMark: "G", printedTotal: 197, releaseDate: "2023/08/11"),
        CatalogCard(cardId: "paf-234", setId: "paf", setName: "Paldean Fates", ptcgoCode: "PAF",
                    number: "234", name: "Charizard ex", supertype: .pokemon,
                    equivalenceKey: "key-charizard", standardLegal: true, expandedLegal: true,
                    regulationMark: "H", printedTotal: 91, releaseDate: "2024/01/26"),
    ])

    /// A grid with the canonical header, one row per supplied tuple.
    private func table(_ rows: [(cardId: String, key: String, norm: String)]) -> SheetTable {
        var values: [[String]] = [InventoryRow.canonicalHeader]
        for r in rows {
            values.append(["Charizard ex", "Obsidian Flames", "OBF", "125", "1", "",
                           r.cardId, r.key, r.norm])
        }
        return SheetTable.parse(values: values)!
    }

    private func plan(_ rows: [(cardId: String, key: String, norm: String)]) -> InventoryMigration.Plan {
        InventoryMigration.plan(table: table(rows), catalog: catalog, normVersion: "v2")
    }

    // MARK: the blank stamp

    func testBlankNormVersionCountsAsStale() {
        // The row's key happens to be right; only the stamp is missing. It must still
        // be re-derived and stamped, not skipped for having "no version to compare".
        let p = plan([(cardId: "obf-125", key: "key-charizard", norm: "")])
        XCTAssertEqual(p.ops, [.setDerived(sheetRowNumber: 2, cardId: "obf-125",
                                           equivalenceKey: "key-charizard", normVersion: "v2")])
        XCTAssertEqual(p.restamped, ["obf-125"])
        XCTAssertTrue(p.rekeyed.isEmpty)
    }

    func testBlankStampWithAStaleKeyIsRekeyed() {
        // The dangerous version of the same row: blank stamp AND a key from an older
        // normalization. Left alone, this card silently stops counting as a copy of
        // its other printings.
        let p = plan([(cardId: "obf-125", key: "old-key", norm: "")])
        XCTAssertEqual(p.ops, [.setDerived(sheetRowNumber: 2, cardId: "obf-125",
                                           equivalenceKey: "key-charizard", normVersion: "v2")])
        XCTAssertEqual(p.rekeyed, ["obf-125"])
        XCTAssertTrue(p.restamped.isEmpty)
    }

    func testAMixOfBlankAndStampedRowsAllMigrate() {
        let p = plan([
            (cardId: "obf-125", key: "old-key", norm: "v1"),
            (cardId: "paf-234", key: "old-key", norm: ""),
        ])
        XCTAssertEqual(p.rekeyed.sorted(), ["obf-125", "paf-234"])
        XCTAssertEqual(p.ops.count, 2)
    }

    // MARK: idempotence

    func testAnUpToDateSheetPlansNothing() {
        // Running a migration against an already-migrated Sheet must not rewrite every
        // row — that's a write quota spent to change nothing.
        let p = plan([
            (cardId: "obf-125", key: "key-charizard", norm: "v2"),
            (cardId: "paf-234", key: "key-charizard", norm: "v2"),
        ])
        XCTAssertTrue(p.isEmpty)
        XCTAssertTrue(p.rekeyed.isEmpty)
        XCTAssertTrue(p.restamped.isEmpty)
    }

    func testApplyingThePlanTwiceIsStable() {
        // Simulate the write, then re-plan: the second pass has nothing left to do.
        let first = plan([(cardId: "obf-125", key: "old-key", norm: "")])
        XCTAssertEqual(first.ops.count, 1)
        let second = plan([(cardId: "obf-125", key: "key-charizard", norm: "v2")])
        XCTAssertTrue(second.isEmpty)
    }

    // MARK: rows the catalog can't speak for

    func testUnknownCardIdIsReportedNotRewritten() {
        // A card_id this snapshot has never heard of is more likely a stale snapshot
        // than a bad row — clearing its key would destroy information.
        let p = plan([(cardId: "zzz-999", key: "some-key", norm: "")])
        XCTAssertTrue(p.ops.isEmpty)
        XCTAssertEqual(p.unresolved, ["zzz-999"])
    }

    func testUnlinkedPromoOnlyNeedsTheStamp() {
        // An unlinked promo is its own one-card group: its key IS its id, so resolve()
        // never produced it and can't invalidate it.
        let id = "manual:mep-075"
        let p = plan([(cardId: id, key: id, norm: "")])
        XCTAssertEqual(p.ops, [.setDerived(sheetRowNumber: 2, cardId: id,
                                           equivalenceKey: id, normVersion: "v2")])
        XCTAssertEqual(p.restamped, [id])
    }

    func testLinkedPromoKeepsAKeyThatStillResolves() {
        let id = "manual:mep-075-key-charizard"
        let p = plan([(cardId: id, key: "key-charizard", norm: "")])
        XCTAssertEqual(p.ops, [.setDerived(sheetRowNumber: 2, cardId: id,
                                           equivalenceKey: "key-charizard", normVersion: "v2")])
        XCTAssertEqual(p.restamped, [id])
        XCTAssertTrue(p.needsRelink.isEmpty)
    }

    func testLinkedPromoWhoseKeyVanishedIsReportedForRelinking() {
        // The unrecoverable case: the row records only the OLD key, and the old key no
        // longer exists in the rebuilt catalog, so there's nothing to map it through.
        // Guessing here would silently re-point the promo at the wrong card.
        let id = "manual:mep-075-gone"
        let p = plan([(cardId: id, key: "key-that-no-longer-exists", norm: "")])
        XCTAssertTrue(p.ops.isEmpty)
        XCTAssertEqual(p.needsRelink, [id])
    }

    // MARK: the write

    func testOpsTargetTheRowTheyCameFrom() {
        // Row numbers are 1-based with the header at row 1, so the first data row is 2.
        let p = plan([
            (cardId: "obf-125", key: "old", norm: ""),
            (cardId: "paf-234", key: "old", norm: ""),
        ])
        guard case let .setDerived(r1, _, _, _) = p.ops[0],
              case let .setDerived(r2, _, _, _) = p.ops[1] else { return XCTFail("wrong op kind") }
        XCTAssertEqual([r1, r2], [2, 3])
    }

    func testMigrationTouchesOnlyTheTwoDerivedCells() {
        // The Sheet is the database of record and the person owns the human columns.
        // A migration that rewrote whole rows would clobber their edits and their qty.
        let p = plan([(cardId: "obf-125", key: "old", norm: "")])
        let layout = SheetLayout.canonical
        let requests = GoogleSheets.applyRequests(
            plan: SyncPlanner.Plan(ops: p.ops, skippedRemovals: [], unappendable: []),
            ref: SheetRef(spreadsheetId: "sheet1", sheetId: 0, title: "Inventory"),
            layout: layout, accessToken: "tok")
        XCTAssertEqual(requests.count, 1)                 // one values:batchUpdate
        let body = try! JSONSerialization.jsonObject(with: requests[0].body!) as! [String: Any]
        let data = body["data"] as! [[String: Any]]
        XCTAssertEqual(data.count, 2)                     // exactly two cells
        let ranges = data.map { $0["range"] as! String }.sorted()
        XCTAssertEqual(ranges, ["Inventory!H2", "Inventory!I2"])  // equivalence_key, norm_version
        XCTAssertEqual(data.compactMap { ($0["values"] as? [[Any]])?.first?.first as? String }.sorted(),
                       ["key-charizard", "v2"])
    }
}
