import XCTest
@testable import DeckCheckCore

final class SheetSyncTests: XCTestCase {

    // A canonical-order inventory grid (header + rows), as Sheets `values.get` returns it.
    let grid: [[String]] = [
        ["name", "set", "code", "number", "qty", "location", "card_id", "equivalence_key", "norm_version"],
        ["Charizard ex", "Obsidian Flames", "OBF", "125", "2", "Binder A", "sv3-125", "char", "v1"],
        ["Iono", "Paldea Evolved", "PAL", "185", "1", "", "sv2-185", "iono", "v1"],
    ]

    func row(_ cardId: String, qty: Int, key: String = "k", name: String = "X",
             set: String = "S", code: String? = "C", number: String = "1",
             location: String? = nil, norm: String = "v1") -> InventoryRow {
        InventoryRow(name: name, set: set, code: code, number: number, qty: qty,
                     location: location, cardId: cardId, equivalenceKey: key, normVersion: norm)
    }

    // ── parse ───────────────────────────────────────────────────────────────

    func testParseTracksTypedRowsAndSheetPositions() {
        let t = SheetTable.parse(values: grid)!
        XCTAssertEqual(t.rows.count, 2)
        XCTAssertEqual(t.rows[0].sheetRowNumber, 2) // header is row 1
        XCTAssertEqual(t.rows[1].sheetRowNumber, 3)
        XCTAssertEqual(t.rows[0].row.cardId, "sv3-125")
        XCTAssertEqual(t.rows[0].row.qty, 2)
        XCTAssertEqual(t.rows[0].row.code, "OBF")
        XCTAssertEqual(t.rows[0].row.location, "Binder A")
        XCTAssertNil(t.rows[1].row.location) // empty cell → nil
    }

    func testParseIsHeaderDrivenSoColumnOrderMayVary() {
        // Person reordered columns and dropped an optional one; identity still maps.
        let reordered: [[String]] = [
            ["card_id", "qty", "name", "equivalence_key", "norm_version"],
            ["sv3-125", "3", "Charizard ex", "char", "v1"],
        ]
        let t = SheetTable.parse(values: reordered)!
        XCTAssertEqual(t.rows[0].row.cardId, "sv3-125")
        XCTAssertEqual(t.rows[0].row.qty, 3)
        XCTAssertNil(t.rows[0].row.code) // absent column → nil
    }

    func testParseSkipsRowsWithoutACardId() {
        let withNote: [[String]] = [
            grid[0],
            grid[1],
            ["a stray human note in column A"], // no card_id
            grid[2],
        ]
        let t = SheetTable.parse(values: withNote)!
        XCTAssertEqual(t.rows.map(\.row.cardId), ["sv3-125", "sv2-185"])
        // the surviving rows keep their TRUE sheet positions (2 and 4, note is row 3)
        XCTAssertEqual(t.rows.map(\.sheetRowNumber), [2, 4])
    }

    func testParseReturnsNilWithoutAHeader() {
        XCTAssertNil(SheetTable.parse(values: []))
    }

    func testOwnedBridgeFeedsTheGapCheckCore() {
        let t = SheetTable.parse(values: grid)!
        XCTAssertEqual(t.owned, [
            OwnedCard(cardId: "sv3-125", equivalenceKey: "char", qty: 2),
            OwnedCard(cardId: "sv2-185", equivalenceKey: "iono", qty: 1),
        ])
    }

    // ── serialize ─────────────────────────────────────────────────────────────

    func testSerializeMatchesLayoutOrderAndBlanksNullables() {
        let layout = SheetLayout.canonical
        let r = row("sv3-125", qty: 4, key: "char", name: "Charizard ex", set: "Obsidian Flames",
                    code: nil, number: "125", location: nil)
        XCTAssertEqual(layout.serialize(r),
                       ["Charizard ex", "Obsidian Flames", "", "125", "4", "", "sv3-125", "char", "v1"])
    }

    // ── planner: the core ──────────────────────────────────────────────

    func testIntakeOfOwnedPrintingIncrements() {
        let t = SheetTable.parse(values: grid)!
        let plan = SyncPlanner.plan(current: t, changes: [.intake(row("sv3-125", qty: 1))])
        XCTAssertEqual(plan.ops, [.setQty(sheetRowNumber: 2, cardId: "sv3-125", qty: 3)])
    }

    func testIntakeOfNewPrintingAppends() {
        let t = SheetTable.parse(values: grid)!
        let newCard = row("sv4-30", qty: 1, key: "gard", name: "Gardevoir ex")
        let plan = SyncPlanner.plan(current: t, changes: [.intake(newCard)])
        guard case let .appendRow(appended) = plan.ops.first else { return XCTFail("expected append") }
        XCTAssertEqual(appended.cardId, "sv4-30")
        XCTAssertEqual(appended.qty, 1)
        XCTAssertEqual(appended.name, "Gardevoir ex")
    }

    func testRemovalDecrementsThenDeletesAtZero() {
        let t = SheetTable.parse(values: grid)!
        // Charizard qty 2 → remove 1 → setQty 1
        XCTAssertEqual(SyncPlanner.plan(current: t, changes: [.removal(cardId: "sv3-125")]).ops,
                       [.setQty(sheetRowNumber: 2, cardId: "sv3-125", qty: 1)])
        // Iono qty 1 → remove 1 → deleteRow
        XCTAssertEqual(SyncPlanner.plan(current: t, changes: [.removal(cardId: "sv2-185")]).ops,
                       [.deleteRow(sheetRowNumber: 3, cardId: "sv2-185")])
    }

    func testOverRemovalClampsToDelete() {
        let t = SheetTable.parse(values: grid)!
        // own 2, remove 5 → row deleted (never negative)
        XCTAssertEqual(SyncPlanner.plan(current: t, changes: [.removal(cardId: "sv3-125", quantity: 5)]).ops,
                       [.deleteRow(sheetRowNumber: 2, cardId: "sv3-125")])
    }

    func testRemovingACardYouDontOwnIsANoOp() {
        let t = SheetTable.parse(values: grid)!
        let plan = SyncPlanner.plan(current: t, changes: [.removal(cardId: "zzz-9")])
        XCTAssertTrue(plan.ops.isEmpty)
        XCTAssertEqual(plan.skippedRemovals, ["zzz-9"])
    }

    func testIntakeOfNewCardWithoutTemplateIsUnappendable() {
        let t = SheetTable.parse(values: grid)!
        let plan = SyncPlanner.plan(current: t,
                                    changes: [InventoryChange(cardId: "sv9-1", delta: 1, template: nil)])
        XCTAssertTrue(plan.ops.isEmpty)
        XCTAssertEqual(plan.unappendable, ["sv9-1"])
    }

    func testBatchNettingCollapsesSameCardToOneOp() {
        let t = SheetTable.parse(values: grid)!
        // A brand-new card snapped 3× in one batch → a single append at qty 3.
        let newCard = row("sv4-30", qty: 1, key: "gard")
        let plan = SyncPlanner.plan(current: t, changes: [.intake(newCard), .intake(newCard), .intake(newCard)])
        guard case let .appendRow(appended) = plan.ops.first, plan.ops.count == 1 else {
            return XCTFail("expected one append")
        }
        XCTAssertEqual(appended.qty, 3)
    }

    func testBatchNettingToZeroDeletes() {
        let t = SheetTable.parse(values: grid)!
        // Charizard qty 2, remove 1 and remove 1 in one batch → net −2 → delete.
        let plan = SyncPlanner.plan(current: t,
                                    changes: [.removal(cardId: "sv3-125"), .removal(cardId: "sv3-125")])
        XCTAssertEqual(plan.ops, [.deleteRow(sheetRowNumber: 2, cardId: "sv3-125")])
    }

    func testOpsOrderingIsWriteSafeDeletesLastBottomUp() {
        // Three rows; two get deleted (rows 2 and 3), one gets an increment (row 4),
        // plus a brand-new append. Expected order: setQty, append, then deletes DESC.
        let g: [[String]] = [
            grid[0],
            ["A", "s", "c", "1", "1", "", "a-1", "ka", "v1"], // row 2 → delete
            ["B", "s", "c", "2", "1", "", "b-2", "kb", "v1"], // row 3 → delete
            ["C", "s", "c", "3", "2", "", "c-3", "kc", "v1"], // row 4 → +1
        ]
        let t = SheetTable.parse(values: g)!
        let plan = SyncPlanner.plan(current: t, changes: [
            .removal(cardId: "a-1"),
            .removal(cardId: "b-2"),
            .intake(row("c-3", qty: 1)),
            .intake(row("d-9", qty: 1, key: "kd")),
        ])
        XCTAssertEqual(plan.ops, [
            .setQty(sheetRowNumber: 4, cardId: "c-3", qty: 3),
            .appendRow(row("d-9", qty: 1, key: "kd")),
            .deleteRow(sheetRowNumber: 3, cardId: "b-2"),
            .deleteRow(sheetRowNumber: 2, cardId: "a-1"),
        ])
    }
}
