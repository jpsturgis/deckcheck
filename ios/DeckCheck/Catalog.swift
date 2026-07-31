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
            lookup = try SQLiteCatalog(path: url.path)
            status = "Catalog loaded"
        } catch {
            status = "Catalog failed to open: \(error)"
            lookup = nil
        }
    }
}
