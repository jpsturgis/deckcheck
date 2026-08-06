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
    let browserGapCheck: BrowserGapCheckManager
    let migrator: InventoryMigrator

    init() {
        browserGapCheck = BrowserGapCheckManager(sheets: sheets)
        migrator = InventoryMigrator(sheets: sheets)
    }

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

    /// Mark a deck built / not built. Applies locally first so the toggle moves under
    /// the finger, then writes the directive into the deck's Sheet tab; a failed write
    /// rolls the local state back rather than leaving the two out of step.
    func setDeckBuilt(_ built: Bool, for deck: DeckList) async -> String? {
        decks.setBuilt(built, for: deck, catalog: catalog.lookup)
        guard sheets.isConnected else {
            decks.revertBuilt(for: deck, catalog: catalog.lookup)
            return "Connect your Sheet to change this."
        }
        do {
            try await sheets.setDeckBuilt(deck, built: built)
            return nil
        } catch {
            decks.revertBuilt(for: deck, catalog: catalog.lookup)
            return "Couldn't update “\(deck.name)”: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
        }
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

    /// Save an edited decklist back to its Sheet tab, then re-read the decks so
    /// reservations and reports pick the change up. Returns an error message, or nil.
    ///
    /// Unlike the built toggle, this deliberately has **no optimistic local apply**.
    /// An edit is made in a draft the user is looking at and committed on purpose, so
    /// showing it as saved before the Sheet agrees would be a lie you could act on —
    /// and the Sheet is the source of truth for decks. A failed save leaves the draft
    /// intact so it can be retried.
    func saveDeck(_ deck: DeckList, text: String) async -> String? {
        guard sheets.isConnected else { return "Connect your Sheet to save changes." }
        do {
            try await sheets.writeDeck(deck, text: text)
            await decks.refresh(fetch: { try await self.sheets.fetchDecks() }, catalog: catalog.lookup)
            return nil
        } catch {
            return "Couldn't save “\(deck.name)”: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
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
