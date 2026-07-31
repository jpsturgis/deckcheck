import Foundation
import Combine
import DeckCheckCore

/// The decks read-cache + reservations (the "in-use" feature). Decklists live as
/// hand-maintained `Deck: <name>` tabs in the Sheet; on each sync the app reads them
/// and recomputes how many copies of each functional group they reserve. Because it's
/// recomputed from the current tabs, deleting a deck tab or changing a count releases
/// the affected cards automatically.
@MainActor
final class DecksStore: ObservableObject {
    @Published private(set) var decks: [DeckList] = []
    @Published private(set) var reservations = Reservations()
    @Published var lastError: String?

    /// Refresh from the Sheet's deck tabs, then recompute reservations against the
    /// catalog (so a line reserves exactly the functional group it would satisfy).
    func refresh(fetch: () async throws -> [DeckList], catalog: (any CatalogLookup)?) async {
        do {
            let fetched = try await fetch()
            decks = fetched
            reservations = catalog.map { ReservationEngine.compute(decks: fetched, catalog: $0) } ?? Reservations()
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }

    func reserved(forKey key: String) -> Int { reservations.reserved(forKey: key) }
    func deckNames(forKey key: String) -> [String] { reservations.decks(forKey: key) }
}
