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

    /// Bumped whenever `rows` changes. Lets views key expensive derived work
    /// (per-deck gap reports) off "did the inventory actually change" rather than off
    /// "did SwiftUI re-evaluate body".
    @Published private(set) var revision = 0

    private let fileURL: URL

    init() {
        fileURL = Outbox.supportDir().appendingPathComponent("inventory-cache.json")
        load()
    }

    /// The engines' owned-copy view.
    var owned: [OwnedCard] { rows.ownedCards }

    // MARK: catalog resolution

    private var cardCache: [String: CatalogCard] = [:]
    private var cardCacheRevision = -1

    /// Every owned printing resolved against the catalog, computed once per inventory
    /// revision rather than once per render.
    ///
    /// The Cards list needs each printing's release date (to order printings) and image
    /// URL (to draw the row). Resolving that inside `body` meant one SQLite lookup per
    /// owned printing on every keystroke, filter toggle and store update — ~17 ms for a
    /// 1,500-printing collection, repeated for no reason, since none of it changes
    /// until the inventory does. Keying the cache off `revision` is what makes typing
    /// cost no catalog work at all. See docs/performance.md.
    ///
    /// Rows the catalog can't place (hand-entered promos) are simply absent, and are
    /// re-tried only when the inventory changes.
    func resolvedCards(using catalog: (any CatalogLookup)?) -> [String: CatalogCard] {
        guard let catalog else { return [:] }
        guard cardCacheRevision != revision else { return cardCache }
        var resolved: [String: CatalogCard] = [:]
        for row in rows where row.qty > 0 {
            guard resolved[row.card_id] == nil, let card = catalog.card(byId: row.card_id) else { continue }
            resolved[row.card_id] = card
        }
        cardCache = resolved
        cardCacheRevision = revision
        return resolved
    }

    /// Thumbnail URLs for the whole collection — what the art pre-warmer downloads.
    func thumbnailURLs(using catalog: (any CatalogLookup)?) -> [String] {
        Array(Set(resolvedCards(using: catalog).values.compactMap(\.imageSmall)))
    }

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
            revision += 1
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
        revision += 1
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rows) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
