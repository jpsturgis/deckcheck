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

    @State private var toggleError: String?

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
                    List {
                        ForEach(decks.decks, id: \.tabTitle) { deck in
                            NavigationLink { DeckDetailView(deck: deck) } label: { row(deck) }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    builtSwipeButton(deck)
                                }
                        }
                        if decks.decks.contains(where: { !$0.isBuilt }) {
                            Text("Decks marked “Idea” don’t reserve cards — their copies stay free for the decks you’ve actually built.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Decks")
            .refreshable { await model.syncNow() }
            // Gap reports are computed here — when the decks, the inventory or the
            // legality lens actually change — rather than per row per render.
            .task(id: ReportInputs(decks: decks.revision,
                                   inventory: inventory.revision,
                                   standardOnly: standardOnly)) {
                decks.refreshReports(owned: inventory.owned, catalog: catalog.lookup,
                                     lens: standardOnly ? .standard : nil)
            }
            .alert("Couldn’t update deck", isPresented: Binding(
                get: { toggleError != nil }, set: { if !$0 { toggleError = nil } })
            ) {
                Button("OK", role: .cancel) { toggleError = nil }
            } message: {
                Text(toggleError ?? "")
            }
        }
    }

    private func row(_ deck: DeckList) -> some View {
        let report = decks.report(for: deck)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(deck.name).font(.body.weight(.medium))
                if !deck.isBuilt { ideaBadge }
                if decks.isPending(deck) { ProgressView().controlSize(.mini) }
            }
            if let r = report {
                Text("Buildable \(r.buildableQty)/\(r.deckTotal)\(r.shortTotal > 0 ? " · short \(r.shortTotal)" : "")")
                    .font(.caption)
                    .foregroundStyle(r.shortTotal > 0 ? Color.orange : Color.green)
            }
        }
    }

    private var ideaBadge: some View {
        Text("Idea")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private func builtSwipeButton(_ deck: DeckList) -> some View {
        Button {
            Task { toggleError = await model.setDeckBuilt(!deck.isBuilt, for: deck) }
        } label: {
            deck.isBuilt
                ? Label("Mark idea", systemImage: "lightbulb")
                : Label("Mark built", systemImage: "checkmark.circle")
        }
        .tint(deck.isBuilt ? .orange : .green)
    }
}

struct DeckDetailView: View {
    let deck: DeckList

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var decks: DecksStore
    @State private var toggleError: String?

    /// Read through the store so the toggle reflects pending state rather than the
    /// value captured when this view was pushed.
    private var current: DeckList {
        decks.decks.first { $0.tabTitle == deck.tabTitle } ?? deck
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { current.isBuilt },
                    set: { built in
                        Task { toggleError = await model.setDeckBuilt(built, for: current) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Counts against my card totals")
                        Text(current.isBuilt
                             ? "Built — these copies show as in use elsewhere."
                             : "Idea — the cards stay free for other decks.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(decks.isPending(current))
            } footer: {
                Text("Stored as a “#built:” line in this deck’s Sheet tab, so you can flip it by hand from a laptop too. The gap-check below runs either way.")
            }
            GapReportView(decklist: current.text)
        }
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn’t update deck", isPresented: Binding(
            get: { toggleError != nil }, set: { if !$0 { toggleError = nil } })
        ) {
            Button("OK", role: .cancel) { toggleError = nil }
        } message: {
            Text(toggleError ?? "")
        }
    }
}

/// What the cached per-deck reports depend on. Any change here invalidates them; a
/// plain `body` re-evaluation doesn't.
private struct ReportInputs: Equatable {
    let decks: Int
    let inventory: Int
    let standardOnly: Bool
}
