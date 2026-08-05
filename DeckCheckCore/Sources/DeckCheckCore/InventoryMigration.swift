import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// Re-deriving the Sheet's machine columns after a normalization change.
//
// `equivalence_key` is denormalized into every inventory row: it's what makes two
// printings count as the same card, and it's computed by resolve() at catalog-build
// time, not by the phone. So when resolve() changes — the reason `norm_version`
// exists at all — every key already written into someone's Sheet is stale, and rows
// that should group together silently stop doing so. The gap-check just reports cards
// as missing that the person owns.
//
// Nothing re-derived those columns until now: `norm_version` was written and read
// back, but never *compared* to anything. This is that comparison, as a pure planner
// over the read grid — same shape as SyncPlanner, emitting the same SyncOp type, so
// the network layer applies a migration exactly the way it applies a sync.
//
// A row is stale if its stamp doesn't match the catalog's. That deliberately includes
// a BLANK stamp: rows written before the stamp was populated carry keys of unknown
// provenance, and the honest thing is to re-derive them from the catalog rather than
// assume they're current. Real sheets contain these — see docs/performance.md.
// ─────────────────────────────────────────────────────────────────────────────

/// Re-derives `equivalence_key` / `norm_version` for inventory rows whose stamp
/// doesn't match the catalog the app is carrying.
public enum InventoryMigration {

    /// What a migration pass would do, as pure data.
    public struct Plan: Equatable {
        /// The writes to apply — all `.setDerived`, one per row that needs changing.
        public let ops: [SyncOp]
        /// Rows whose `equivalence_key` actually changed. These are the ones that were
        /// grouping wrongly: the migration is what makes them count as copies again.
        public let rekeyed: [String]
        /// Rows whose key was already right and only needed the stamp — the common
        /// case for a Sheet with blank `norm_version` cells.
        public let restamped: [String]
        /// Hand-entered promos linked to a catalog card whose key no longer exists.
        /// Not fixable from the row alone (see `plan`); they need re-linking by hand.
        public let needsRelink: [String]
        /// Rows the catalog has never heard of. Left untouched — a card_id the current
        /// snapshot can't place is more likely a stale snapshot than a bad row.
        public let unresolved: [String]

        public var isEmpty: Bool { ops.isEmpty }

        public init(ops: [SyncOp], rekeyed: [String], restamped: [String],
                    needsRelink: [String], unresolved: [String]) {
            self.ops = ops; self.rekeyed = rekeyed; self.restamped = restamped
            self.needsRelink = needsRelink; self.unresolved = unresolved
        }
    }

    /// Plan a migration of `table` against `catalog`, whose normalization is
    /// `normVersion` (the snapshot's `meta.norm_version`).
    ///
    /// Per row:
    /// - a real printing re-derives its key straight from the catalog by `card_id`,
    ///   which is authoritative and independent of whatever the row currently claims;
    /// - an **unlinked** promo is its own one-card group (`equivalence_key == card_id`)
    ///   and so has no key to re-derive — resolve() never produced it and can't
    ///   invalidate it. It only needs the stamp;
    /// - a **linked** promo adopted a catalog card's key, and that key is baked into
    ///   its synthetic `card_id` (see `ManualEntry.promoCard`). If the key still exists
    ///   in the catalog the link is intact and the row just needs stamping. If it
    ///   doesn't, the row records only the *old* key and the old key is gone from the
    ///   rebuilt snapshot — there is nothing left to map it through, so it's reported
    ///   rather than guessed at. (Carrying a previous-key column in the catalog would
    ///   make these recoverable; see docs/performance.md.)
    ///
    /// Rows that are already correct and correctly stamped produce no op, so running
    /// this against an up-to-date Sheet is a no-op rather than a rewrite of every row.
    public static func plan(table: SheetTable,
                            catalog: CatalogLookup,
                            normVersion: String) -> Plan {
        var ops: [SyncOp] = []
        var rekeyed: [String] = []
        var restamped: [String] = []
        var needsRelink: [String] = []
        var unresolved: [String] = []

        for placed in table.rows {
            let row = placed.row
            let stampIsCurrent = row.normVersion == normVersion

            /// Emit a write for this row unless nothing about it would change.
            func write(key: String) {
                guard key != row.equivalenceKey || !stampIsCurrent else { return }
                ops.append(.setDerived(sheetRowNumber: placed.sheetRowNumber,
                                       cardId: row.cardId,
                                       equivalenceKey: key,
                                       normVersion: normVersion))
                if key != row.equivalenceKey { rekeyed.append(row.cardId) }
                else { restamped.append(row.cardId) }
            }

            if ManualEntry.isManual(row.cardId) {
                if row.equivalenceKey == row.cardId {
                    write(key: row.equivalenceKey)          // unlinked — key is its own id
                } else if !catalog.cards(equivalenceKey: row.equivalenceKey).isEmpty {
                    write(key: row.equivalenceKey)          // linked, and the link still resolves
                } else {
                    needsRelink.append(row.cardId)
                }
                continue
            }

            guard let card = catalog.card(byId: row.cardId) else {
                unresolved.append(row.cardId)
                continue
            }
            write(key: card.equivalenceKey)
        }

        return Plan(ops: ops, rekeyed: rekeyed, restamped: restamped,
                    needsRelink: needsRelink, unresolved: unresolved)
    }
}
