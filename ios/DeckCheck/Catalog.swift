import Foundation
import Combine
import DeckCheckCore
import DeckCheckSQLite

/// The bundled read-only catalog snapshot. Loads `catalog.sqlite`
/// from the app bundle and exposes it as the shared `CatalogLookup` + `CatalogSearching`
/// the resolve / gap-check / search paths use. Absent snapshot → a clear status
/// rather than a crash (build it with tools/build-catalog and add it to the target).
@MainActor
final class Catalog: ObservableObject {
    /// Non-nil once a snapshot is loaded.
    @Published private(set) var lookup: (any CatalogLookup & CatalogSearching)?
    @Published private(set) var status: String = "Loading catalog…"

    /// The normalization version this snapshot's `equivalence_key`s were computed
    /// under. An inventory row stamped with anything else has a key from an older
    /// catalog — see `InventoryMigration`.
    @Published private(set) var normVersion: String?

    init() { load() }

    var isLoaded: Bool { lookup != nil }

    func load() {
        guard let url = Bundle.main.url(forResource: "catalog", withExtension: "sqlite") else {
            status = "No catalog.sqlite in the app bundle. Build it with tools/build-catalog "
                   + "(npm run build) and add it to the DeckCheck target."
            lookup = nil
            return
        }
        do {
            let snapshot = try SQLiteCatalog(path: url.path)
            lookup = snapshot
            normVersion = snapshot.normVersion
            status = snapshot.hasSearchIndex
                ? "Catalog loaded"
                : "Catalog loaded (no search index — rebuild it with tools/build-catalog for fast search)"
        } catch {
            status = "Catalog failed to open: \(error)"
            lookup = nil
            normVersion = nil
        }
    }
}
