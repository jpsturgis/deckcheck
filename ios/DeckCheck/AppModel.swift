import Foundation
import Combine
import DeckCheckCore

/// Top-level coordinator. Owns the stores and the sync action that flushes the
/// outbox then refreshes the read-cache. The individual stores are
/// injected into the view tree as environment objects; this ties them together.
@MainActor
final class AppModel: ObservableObject {
    let catalog = Catalog()
    let inventory = InventoryStore()
    let outbox = Outbox()
    let decks = DecksStore()             // deck tabs → "in-use" reservations
    let sheets = GoogleSheetsService()   // the inventory backend: direct Sheets API

    /// Whether writes/reads will actually go somewhere — i.e. the Sheet is connected.
    /// Drives the "Sync now" affordance.
    var canSync: Bool { sheets.isConnected }

    /// Flush pending writes, then pull the latest inventory. Safe to call on launch,
    /// on pull-to-refresh, and after enqueuing intake/removal.
    func syncNow() async {
        guard sheets.isConnected else { return }
        await outbox.flush { try await self.sheets.applyOutbox($0) }
        await inventory.refresh { try await self.sheets.fetchInventory() }
        await decks.refresh(fetch: { try await self.sheets.fetchDecks() }, catalog: catalog.lookup)
        await runSheetGapCheck()
    }

    /// Save a decklist as a new `Deck:` tab, then refresh reservations. Returns a
    /// status line for the caller to show. (Used by "Add as deck" in the gap-checker.)
    func addDeck(name: String, decklist: String) async -> String {
        do {
            try await sheets.createDeck(name: name, decklist: decklist)
            await decks.refresh(fetch: { try await self.sheets.fetchDecks() }, catalog: catalog.lookup)
            return "Added deck “\(name.trimmingCharacters(in: .whitespaces))”."
        } catch {
            return "Couldn't add deck: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
        }
    }

    /// App-driven sheet gap-check: read the decklist pasted into the Gap
    /// Check tab, run the engine, and write the report back into that tab. Best-effort
    /// — a failure here never blocks a sync.
    private func runSheetGapCheck() async {
        guard let lookup = catalog.lookup else { return }
        do {
            let decklist = try await sheets.readGapCheckDecklist()
            guard !DecklistParser.parse(decklist).isEmpty else { return } // only when a real list is present
            let report = GapChecker.check(decklist: decklist, owned: inventory.owned, catalog: lookup, lens: nil)
            try await sheets.writeGapCheckReport(report)
        } catch {
            // best-effort; the in-app Gap Check tab always works regardless
        }
    }
}
