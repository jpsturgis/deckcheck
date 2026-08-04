import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// The inventory ↔ Google Sheet sync core. Two pure, testable pieces:
//
//   1. SheetTable — parse a Sheets `values.get` grid ([[String]]) into typed,
//      position-tagged rows (header-driven, so the person may reorder columns),
//      and serialize a row back into the Sheet's column order for writes.
//
//   2. SyncPlanner — the reconciliation that in v1 lived in the Apps Script
//      `doPost`, ported CLIENT-SIDE: intake → +1 or append; removal → −1,
//      delete the row at 0. It reads the current grid and emits a list of planned
//      operations as PURE DATA. The iOS network layer (next increment) translates
//      those into Sheets `values.batchUpdate` / `deleteDimension` calls.
//
// Keeping the planner pure is what makes the risky part unit-testable off-device;
// read-before-write + last-writer-wins fall out of planning against the read grid.
// ─────────────────────────────────────────────────────────────────────────────

/// The live Sheet's header column order — lets the writer target the right cells
/// no matter how the person has arranged the columns.
public struct SheetLayout: Equatable {
    /// Lowercased header names, in Sheet column order (index 0 = column A).
    public let columns: [String]

    public init(header: [String]) {
        self.columns = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    /// The canonical layout a freshly-created "Inventory" tab is given.
    public static let canonical = SheetLayout(header: InventoryRow.canonicalHeader)

    /// 0-based column index of a known inventory column, if present.
    public func index(of column: InventoryColumn) -> Int? { columns.firstIndex(of: column.rawValue) }

    /// Render a row into this layout's column order (columns we don't recognize → "").
    public func serialize(_ row: InventoryRow) -> [String] {
        columns.map { InventoryColumn(rawValue: $0)?.cell(of: row) ?? "" }
    }

    /// Parse one data row (a Sheet values row, possibly short) using this layout.
    /// Returns nil when the row has no `card_id` — the app keys on it.
    public func parse(_ cells: [String]) -> InventoryRow? {
        func cell(_ col: InventoryColumn) -> String {
            guard let i = index(of: col), i < cells.count else { return "" }
            return cells[i].trimmingCharacters(in: .whitespaces)
        }
        let cardId = cell(.cardId)
        guard !cardId.isEmpty else { return nil }
        let codeStr = cell(.code), locStr = cell(.location)
        return InventoryRow(
            name: cell(.name),
            set: cell(.set),
            code: codeStr.isEmpty ? nil : codeStr,
            number: cell(.number),
            qty: Int(cell(.qty)) ?? 0,
            location: locStr.isEmpty ? nil : locStr,
            cardId: cardId,
            equivalenceKey: cell(.equivalenceKey),
            normVersion: cell(.normVersion)
        )
    }
}

/// An inventory row at its absolute Sheet position. `sheetRowNumber` is 1-based
/// A1 (header is row 1, first data row is row 2); the reconciler targets updates
/// and deletes by it. (`deleteDimension` is zero-based: startIndex = number − 1.)
public struct PlacedRow: Equatable {
    public let row: InventoryRow
    public let sheetRowNumber: Int
    public init(row: InventoryRow, sheetRowNumber: Int) {
        self.row = row; self.sheetRowNumber = sheetRowNumber
    }
}

/// A parsed inventory grid: the header layout + placed data rows.
public struct SheetTable: Equatable {
    public let layout: SheetLayout
    public let rows: [PlacedRow]

    public init(layout: SheetLayout, rows: [PlacedRow]) {
        self.layout = layout; self.rows = rows
    }

    /// Parse a Sheets `values.get` grid. The first row is the header; each later
    /// row keeps its true Sheet position even if it's blank/invalid (so writes to
    /// other rows stay correctly aligned). Returns nil if there's no header row.
    public static func parse(values: [[String]]) -> SheetTable? {
        guard let header = values.first else { return nil }
        let layout = SheetLayout(header: header)
        var placed: [PlacedRow] = []
        for (i, cells) in values.dropFirst().enumerated() {
            let sheetRowNumber = i + 2 // header = row 1
            if let row = layout.parse(cells) {
                placed.append(PlacedRow(row: row, sheetRowNumber: sheetRowNumber))
            }
        }
        return SheetTable(layout: layout, rows: placed)
    }

    /// The read-cache view the gap-check / search core consumes.
    public var owned: [OwnedCard] { rows.compactMap { $0.row.owned } }
}

// ── Reconciliation (v1's doPost, ported client-side) ───────────────────

/// One inventory change to reconcile. Intake carries a `template` (the resolved
/// card's display columns) so a not-yet-owned printing can be appended; removal
/// needs only the `cardId`.
public struct InventoryChange: Equatable {
    public let cardId: String
    public let delta: Int              // +N intake, −N removal
    public let template: InventoryRow? // display columns to append when the card is new

    public init(cardId: String, delta: Int, template: InventoryRow?) {
        self.cardId = cardId; self.delta = delta; self.template = template
    }

    /// Intake of a resolved printing (its row supplies the columns to append if new).
    public static func intake(_ row: InventoryRow, quantity: Int = 1) -> InventoryChange {
        InventoryChange(cardId: row.cardId, delta: quantity, template: row)
    }

    /// Removal of a printing you own, by canonical card_id.
    public static func removal(cardId: String, quantity: Int = 1) -> InventoryChange {
        InventoryChange(cardId: cardId, delta: -quantity, template: nil)
    }
}

/// A planned Sheet write. Pure data — the network layer executes it.
public enum SyncOp: Equatable {
    /// Set an existing row's qty cell (qty stays > 0). `values.batchUpdate`.
    case setQty(sheetRowNumber: Int, cardId: String, qty: Int)
    /// Append a new printing at the given qty. `values.append`.
    case appendRow(InventoryRow)
    /// Delete a row whose qty reached 0. `deleteDimension`.
    case deleteRow(sheetRowNumber: Int, cardId: String)
    /// Rewrite an existing row's derived machine columns after a normalization
    /// change (`InventoryMigration`). Touches only `equivalence_key` and
    /// `norm_version` — never qty, never the human columns.
    case setDerived(sheetRowNumber: Int, cardId: String, equivalenceKey: String, normVersion: String)
}

public enum SyncPlanner {
    /// The reconciliation result: ops to apply, plus what couldn't be planned.
    public struct Plan: Equatable {
        /// Ops in safe apply order: setQty, then appendRow, then deleteRow sorted
        /// DESCENDING by row number (bottom-up) so a delete never shifts the row a
        /// later op targets. Apply value writes first, deletes last.
        public let ops: [SyncOp]
        /// Removals of a card_id you don't own — nothing to decrement.
        public let skippedRemovals: [String]
        /// Intake of a new card_id with no template — can't append without columns.
        public let unappendable: [String]

        public init(ops: [SyncOp], skippedRemovals: [String], unappendable: [String]) {
            self.ops = ops; self.skippedRemovals = skippedRemovals; self.unappendable = unappendable
        }
    }

    /// Reconcile a batch of changes against the current grid. Same-card_id
    /// changes are netted so a batch collapses into one op per card (fewer writes).
    /// Read-before-write + last-writer-wins are inherent: we plan against the
    /// grid we read, and setQty overwrites the whole cell.
    public static func plan(current table: SheetTable, changes: [InventoryChange]) -> Plan {
        // First occurrence of each card_id wins if the Sheet has accidental dupes.
        var placedByCardId: [String: PlacedRow] = [:]
        for p in table.rows where placedByCardId[p.row.cardId] == nil {
            placedByCardId[p.row.cardId] = p
        }

        // Net deltas + keep the first template offered for each card_id.
        var netDelta: [String: Int] = [:]
        var template: [String: InventoryRow] = [:]
        var order: [String] = []
        for c in changes {
            if netDelta[c.cardId] == nil { order.append(c.cardId) }
            netDelta[c.cardId, default: 0] += c.delta
            if template[c.cardId] == nil, let t = c.template { template[c.cardId] = t }
        }

        var setOps: [SyncOp] = []
        var appendOps: [SyncOp] = []
        var deleteOps: [(Int, SyncOp)] = []
        var skippedRemovals: [String] = []
        var unappendable: [String] = []

        for cardId in order.sorted() { // deterministic output
            let delta = netDelta[cardId] ?? 0
            if delta == 0 { continue }
            if let placed = placedByCardId[cardId] {
                let newQty = placed.row.qty + delta
                if newQty <= 0 {
                    deleteOps.append((placed.sheetRowNumber,
                                      .deleteRow(sheetRowNumber: placed.sheetRowNumber, cardId: cardId)))
                } else {
                    setOps.append(.setQty(sheetRowNumber: placed.sheetRowNumber, cardId: cardId, qty: newQty))
                }
            } else if delta > 0 {
                if var t = template[cardId] {
                    t.qty = delta
                    appendOps.append(.appendRow(t))
                } else {
                    unappendable.append(cardId)
                }
            } else {
                skippedRemovals.append(cardId) // removing a card you don't own — no-op
            }
        }

        // deletes bottom-up so earlier deletions don't invalidate later row numbers.
        let deletes = deleteOps.sorted { $0.0 > $1.0 }.map(\.1)
        return Plan(ops: setOps + appendOps + deletes,
                    skippedRemovals: skippedRemovals,
                    unappendable: unappendable)
    }
}
