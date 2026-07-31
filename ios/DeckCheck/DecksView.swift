import SwiftUI
import DeckCheckCore

/// The Decks tab: your hand-maintained `Deck: <name>` sheet tabs, each with a
/// per-deck gap-check. Reservations from these decks drive the "in use" flags in
/// Cards (see DecksStore); this is the browse-by-deck surface.
struct DecksView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var decks: DecksStore
    @EnvironmentObject var catalog: Catalog
    @EnvironmentObject var inventory: InventoryStore
    @AppStorage("standardOnly") private var standardOnly = false

    var body: some View {
        NavigationStack {
            Group {
                if decks.decks.isEmpty {
                    ContentUnavailableView {
                        Label("No decks yet", systemImage: "rectangle.on.rectangle.angled")
                    } description: {
                        Text("Add a tab named “Deck: <name>” to your Sheet, paste a TCG Live decklist into it, then pull to refresh.")
                    }
                } else {
                    List(decks.decks, id: \.name) { deck in
                        NavigationLink { DeckDetailView(deck: deck) } label: { row(deck) }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Decks")
            .refreshable { await model.syncNow() }
        }
    }

    private func row(_ deck: DeckList) -> some View {
        let report = gapReport(for: deck, catalog: catalog, inventory: inventory, standardOnly: standardOnly)
        return VStack(alignment: .leading, spacing: 3) {
            Text(deck.name).font(.body.weight(.medium))
            if let r = report {
                Text("Buildable \(r.buildableQty)/\(r.deckTotal)\(r.shortTotal > 0 ? " · short \(r.shortTotal)" : "")")
                    .font(.caption)
                    .foregroundStyle(r.shortTotal > 0 ? Color.orange : Color.green)
            }
        }
    }
}

struct DeckDetailView: View {
    let deck: DeckList

    var body: some View {
        Form {
            GapReportView(decklist: deck.text)
        }
        .navigationTitle(deck.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Per-deck gap-check against your owned inventory, honoring the shared Standard filter.
@MainActor
private func gapReport(for deck: DeckList, catalog: Catalog, inventory: InventoryStore,
                       standardOnly: Bool) -> GapReport? {
    guard let lookup = catalog.lookup else { return nil }
    return GapChecker.check(decklist: deck.text, owned: inventory.owned, catalog: lookup,
                            lens: standardOnly ? .standard : nil)
}
