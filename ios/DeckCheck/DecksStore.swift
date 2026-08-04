import Foundation
import Combine
import DeckCheckCore

/// The decks read-cache + reservations (the "in-use" feature). Decklists live as
/// hand-maintained `Deck: <name>` tabs in the Sheet; on each sync the app reads them
/// and recomputes how many copies of each functional group they reserve. Because it's
/// recomputed from the current tabs, deleting a deck tab or changing a count releases
/// the affected cards automatically.
///
/// A deck can also be marked **not built** — an idea you haven't sleeved yet. Those
/// still gap-check but reserve nothing. The flag lives in the Sheet (a `#built:` line
/// in the tab), with a pending-override layer here so the toggle responds instantly and
/// survives a crash before the write lands.
@MainActor
final class DecksStore: ObservableObject {
    @Published private(set) var decks: [DeckList] = []
    @Published private(set) var reservations = Reservations()
    @Published var lastError: String?

    /// Toggles applied locally but not yet confirmed by a Sheet read, keyed by tab
    /// title. Persisted so a crash mid-write doesn't silently discard the user's intent.
    @Published private(set) var pendingBuilt: [String: Bool] = [:]

    private let defaults = UserDefaults.standard
    private static let pendingKey = "decks.pendingBuilt"

    init() {
        pendingBuilt = defaults.dictionary(forKey: Self.pendingKey) as? [String: Bool] ?? [:]
    }

    /// Refresh from the Sheet's deck tabs, then recompute reservations against the
    /// catalog (so a line reserves exactly the functional group it would satisfy).
    func refresh(fetch: () async throws -> [DeckList], catalog: (any CatalogLookup)?) async {
        do {
            let fetched = try await fetch()

            // Retire overrides the Sheet has caught up with, and any for a tab that's
            // gone; keep the rest applied on top of what was read.
            let live = Set(fetched.map(\.tabTitle))
            let confirmed = Set(fetched.filter { pendingBuilt[$0.tabTitle] == $0.isBuilt }.map(\.tabTitle))
            pendingBuilt = pendingBuilt.filter { live.contains($0.key) && !confirmed.contains($0.key) }
            savePending()

            decks = fetched.map { $0.setting(isBuilt: pendingBuilt[$0.tabTitle] ?? $0.isBuilt) }
            recompute(catalog)
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }

    /// Apply a built/not-built toggle immediately, recomputing reservations on the spot.
    /// The caller writes it through to the Sheet; `refresh` clears the override once the
    /// Sheet agrees.
    func setBuilt(_ built: Bool, for deck: DeckList, catalog: (any CatalogLookup)?) {
        pendingBuilt[deck.tabTitle] = built
        savePending()
        apply(isBuilt: built, to: deck.tabTitle, catalog)
    }

    /// Roll a toggle back after a failed write, so the local state stops claiming
    /// something the Sheet never accepted.
    func revertBuilt(for deck: DeckList, catalog: (any CatalogLookup)?) {
        pendingBuilt[deck.tabTitle] = nil
        savePending()
        apply(isBuilt: DeckDirectives.isBuilt(deck.text), to: deck.tabTitle, catalog)
    }

    /// Whether a toggle for this deck is still waiting on the Sheet.
    func isPending(_ deck: DeckList) -> Bool { pendingBuilt[deck.tabTitle] != nil }

    func reserved(forKey key: String) -> Int { reservations.reserved(forKey: key) }
    func deckNames(forKey key: String) -> [String] { reservations.decks(forKey: key) }

    // MARK: -

    private func apply(isBuilt: Bool, to tabTitle: String, _ catalog: (any CatalogLookup)?) {
        decks = decks.map { $0.tabTitle == tabTitle ? $0.setting(isBuilt: isBuilt) : $0 }
        recompute(catalog)
    }

    private func recompute(_ catalog: (any CatalogLookup)?) {
        reservations = catalog.map { ReservationEngine.compute(decks: decks, catalog: $0) } ?? Reservations()
    }

    private func savePending() {
        defaults.set(pendingBuilt, forKey: Self.pendingKey)
    }
}
