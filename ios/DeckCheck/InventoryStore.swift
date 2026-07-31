import Foundation
import Combine
import DeckCheckCore

/// The local read-cache mirroring the Sheet: instant/offline lookups,
/// owned counts, and search input. Refreshes from `doGet` on launch and pull-to-
/// refresh; persisted so it's available offline.
@MainActor
final class InventoryStore: ObservableObject {
    @Published private(set) var rows: [InventoryRow] = []
    @Published private(set) var lastSyncedAt: Date?
    @Published var lastError: String?

    private let fileURL: URL

    init() {
        fileURL = Outbox.supportDir().appendingPathComponent("inventory-cache.json")
        load()
    }

    /// The engines' owned-copy view.
    var owned: [OwnedCard] { rows.ownedCards }

    /// Functional owned count for an equivalence group (any printing) — for the
    /// quiet "owned: N" badge and search.
    func ownedCount(forKey key: String) -> Int {
        rows.filter { $0.equivalence_key == key }.reduce(0) { $0 + $1.qty }
    }

    /// Which owned printing a removal should decrement: the exact scanned
    /// printing if owned, else an owned **functional equivalent** (the printing you
    /// own the most of), else nil = not in inventory.
    func removalTarget(cardId: String, equivalenceKey key: String) -> (row: InventoryRow, exact: Bool)? {
        if let exact = rows.first(where: { $0.card_id == cardId && $0.qty > 0 }) {
            return (exact, true)
        }
        if let equivalent = rows.filter({ $0.equivalence_key == key && $0.qty > 0 })
            .max(by: { $0.qty < $1.qty }) {
            return (equivalent, false)
        }
        return nil
    }

    /// Refresh the read-cache via the active backend (injected as a closure so this
    /// works against either the v1 Apps Script client or the v2 Sheets API).
    func refresh(fetch: () async throws -> [InventoryRow]) async {
        do {
            rows = try await fetch()
            lastSyncedAt = Date()
            lastError = nil
            save()
        } catch {
            lastError = "\(error)"
        }
    }

    // MARK: persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let cached = try? JSONDecoder().decode([InventoryRow].self, from: data) else { return }
        rows = cached
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rows) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
