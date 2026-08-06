import Foundation
import DeckCheckCore

/// Settings' "Re-check card grouping": re-derives the Sheet's `equivalence_key` /
/// `norm_version` columns against the bundled catalog, for rows whose stamp doesn't
/// match it — including rows with a blank stamp, which are the ones most likely to be
/// silently mis-grouped.
///
/// Split out of `GoogleSheetsService`: a single-caller concern with no knowledge of
/// live sync, decks, or the gap-check tab, built on `sheets`'s connection
/// (`token()` / `loadInventory()` / `apply()`) rather than holding its own.
@MainActor
final class InventoryMigrator: ObservableObject {
    @Published var status = ""
    @Published var busy = false
    @Published var lastError: String?

    private let sheets: GoogleSheetsService

    init(sheets: GoogleSheetsService) {
        self.sheets = sheets
    }

    /// Read-before-write like every other Sheet operation, and it touches only those
    /// two cells: the person owns the rest of the row. Safe to run repeatedly — an
    /// already-migrated Sheet plans nothing.
    func migrateDerivedColumns(catalog: (any CatalogLookup)?, normVersion: String?) async {
        await run("Checking card grouping…") {
            guard let ref = self.sheets.sheetRef else { throw Fail("Connect your Inventory sheet first.") }
            guard let catalog else { throw Fail("The catalog isn't loaded yet.") }
            guard let normVersion else {
                throw Fail("This catalog snapshot has no norm_version — rebuild it with tools/build-catalog.")
            }
            let token = try await self.sheets.token()
            let table = try await self.sheets.loadInventory(token: token)
            let plan = InventoryMigration.plan(table: table, catalog: catalog, normVersion: normVersion)

            if !plan.isEmpty {
                // Reusing the sync Plan as the carrier: a migration is a list of cell
                // writes, which is exactly what the apply path already executes.
                try await self.sheets.apply(
                    SyncPlanner.Plan(ops: plan.ops, skippedRemovals: [], unappendable: []),
                    ref: ref, layout: table.layout, token: token)
            }
            self.status = Self.summarize(plan)
        }
    }

    /// A plain-language account of what a migration did — including what it couldn't
    /// do, which is the part worth surfacing rather than swallowing.
    private static func summarize(_ plan: InventoryMigration.Plan) -> String {
        var parts: [String] = []
        if !plan.rekeyed.isEmpty { parts.append("\(plan.rekeyed.count) regrouped") }
        if !plan.restamped.isEmpty { parts.append("\(plan.restamped.count) restamped") }
        if !plan.needsRelink.isEmpty { parts.append("\(plan.needsRelink.count) promo(s) need re-linking by hand") }
        if !plan.unresolved.isEmpty { parts.append("\(plan.unresolved.count) not in this catalog") }
        return parts.isEmpty ? "Everything already matches this catalog." : parts.joined(separator: " · ")
    }

    private func run(_ starting: String, _ work: @escaping () async throws -> Void) async {
        busy = true; lastError = nil; status = starting
        do { try await work() }
        catch { lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; status = "" }
        busy = false
    }

    private struct Fail: LocalizedError { let msg: String; init(_ m: String) { msg = m }; var errorDescription: String? { msg } }
}
