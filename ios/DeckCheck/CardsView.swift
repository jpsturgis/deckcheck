import SwiftUI
import DeckCheckCore

/// Cards: one browse/search surface with an **Owned / All** scope.
/// Owned (default) lists your collection from the read-cache, offline. All searches
/// the whole catalog by name, showing owned count incl. 0. Both are equivalence-grouped.
struct CardsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var inventory: InventoryStore
    @EnvironmentObject var catalog: Catalog
    @EnvironmentObject var outbox: Outbox
    @EnvironmentObject var decks: DecksStore

    enum Scope: String, CaseIterable { case owned = "Owned", all = "All", sets = "Sets" }
    @State private var scope: Scope = .owned

    /// Per-set completion, recomputed on a `.task(id:)` rather than per `body`.
    /// Counting touches every printing in the snapshot, so doing it inside a computed
    /// property would redo ~23k id reads on every keystroke and every scroll frame —
    /// the same trap docs/performance.md records for the deck reports.
    @State private var setProgress: [SetProgress] = []
    @State private var query = ""
    /// `query` settled. Catalog search is a full-table LIKE scan (~22 ms against a
    /// 23k-card snapshot on a Mac, more on a phone), so running it per keystroke made
    /// typing feel heavy. See docs/performance.md.
    @State private var debouncedQuery = ""
    @State private var addingPromo = false

    /// Show only Standard-legal cards. Off by default → your whole collection shows.
    /// Persisted and shared with the equivalent-card picker.
    @AppStorage("standardOnly") private var standardOnly = false
    /// Show only cards with a free (unreserved) copy — owned minus what decks use.
    @AppStorage("freeOnly") private var freeOnly = false
    private var legalityFormat: LegalityFormat? { standardOnly ? .standard : nil }

    private var items: [CardListItem] {
        switch scope {
        case .owned: return ownedItems()
        case .all:   return allItems()
        case .sets:  return []   // Sets renders its own rows; see setsList()
        }
    }

    /// Sets matching the search box, by name or TCG Live code.
    private var filteredSets: [SetProgress] {
        let q = debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return setProgress }
        return setProgress.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || ($0.ptcgoCode?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var body: some View {
        // Computed ONCE per pass and threaded down. It used to be read three times per
        // body evaluation — by the empty-state check, the ForEach, and the header — each
        // one redoing the full grouping and sort.
        let items = self.items
        return NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Picker("Scope", selection: $scope) {
                        ForEach(Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    // Standard-only filter lives here (not the nav bar) so it stays
                    // reachable while the search field is active.
                    HStack {
                        Toggle(isOn: $standardOnly) {
                            Label("Standard only", systemImage: standardOnly ? "checkmark.seal.fill" : "seal")
                        }
                        .toggleStyle(.button)
                        .buttonStyle(.bordered)
                        if scope == .owned {
                            Toggle(isOn: $freeOnly) {   // free-only is meaningless for a set
                                Label("Free only", systemImage: freeOnly ? "checkmark.circle.fill" : "circle")
                            }
                            .toggleStyle(.button)
                            .buttonStyle(.bordered)
                        }
                        Spacer()
                    }
                    .font(.subheadline)
                }
                .padding([.horizontal, .top])
                .padding(.bottom, 6)

                content(items)
            }
            .navigationTitle("Cards")
            .searchable(text: $query, prompt: searchPrompt)
            // Recompute set completion when the collection changes, when the legality
            // lens changes, when the catalog finishes loading, or when the user first
            // switches to this scope — and at no other time.
            .task(id: SetsInputs(revision: inventory.revision,
                                 standardOnly: standardOnly,
                                 catalogLoaded: catalog.isLoaded,
                                 active: scope == .sets)) {
                guard scope == .sets, let lookup = catalog.lookup else { return }
                setProgress = SetCompletion.progress(owned: inventory.owned,
                                                     catalog: lookup,
                                                     lens: legalityFormat)
            }
            .task(id: query) {
                // Let typing settle before re-querying. Clearing is instant — that
                // should feel immediate.
                if !query.isEmpty { try? await Task.sleep(for: .milliseconds(180)) }
                guard !Task.isCancelled else { return }
                debouncedQuery = query
            }
            .scrollDismissesKeyboard(.immediately)
            .refreshable { await model.syncNow() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { addingPromo = true } label: {
                        Label("Add promo", systemImage: "star.circle")
                    }
                    .labelStyle(.titleAndIcon)
                }
            }
            .sheet(isPresented: $addingPromo) {
                NavigationStack {
                    ManualPromoEntryView(catalog: catalog.lookup) { commitPromo($0) }
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { addingPromo = false }
                            }
                        }
                }
            }
        }
    }

    /// Record a hand-entered promo straight from the inventory browser — no scan
    /// needed. Intake goes through the durable outbox like a batch commit, then
    /// syncs; the new row lands in the Owned list on the next refresh.
    private func commitPromo(_ card: CatalogCard) {
        outbox.enqueue(OutboxOp(
            id: UUID().uuidString,
            op: .intake,
            card_id: card.cardId,
            name: card.name, set: card.setName, code: card.ptcgoCode ?? "",
            number: card.number, location: "",
            equivalence_key: card.equivalenceKey,
            norm_version: catalog.normVersion ?? ""
        ))
        addingPromo = false
        Task { await model.syncNow() }
    }

    private var searchPrompt: String {
        switch scope {
        case .owned: return "Your cards — name, set, or number"
        case .all:   return "Search — name, set, or number"
        case .sets:  return "Find a set — name or code"
        }
    }

    @ViewBuilder private func content(_ items: [CardListItem]) -> some View {
        if (scope == .all || scope == .sets) && catalog.lookup == nil {
            ContentUnavailableView("No catalog", systemImage: "tray", description: Text(catalog.status))
        } else if scope == .sets {
            setsList()
        } else if let empty = emptyMessage(items) {
            ContentUnavailableView(empty.title, systemImage: empty.icon, description: Text(empty.detail))
        } else {
            List {
                Section {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        row(item)
                            // Warm the art for rows about to scroll in. ~11 KB each and
                            // immutable, so asking early is nearly free and removes the
                            // visible load.
                            .onAppear { prefetchAhead(of: index, in: items) }
                    }
                } header: {
                    Text(header(items))
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder private func setsList() -> some View {
        let sets = filteredSets
        if sets.isEmpty {
            ContentUnavailableView(
                debouncedQuery.isEmpty ? "No sets" : "No sets match",
                systemImage: "square.grid.2x2",
                description: Text(debouncedQuery.isEmpty
                    ? "Your catalog snapshot has no sets in it. Rebuild it with tools/build-catalog."
                    : "No set matches “\(debouncedQuery)”."))
        } else {
            List {
                Section {
                    ForEach(sets) { progress in
                        NavigationLink { SetDetailView(setId: progress.setId) } label: {
                            SetProgressBar(progress: progress)
                                .padding(.vertical, 2)
                        }
                    }
                } header: {
                    Text(setsHeader(sets))
                }
            }
            .listStyle(.plain)
        }
    }

    private func setsHeader(_ sets: [SetProgress]) -> String {
        let complete = sets.filter(\.isComplete).count
        let ownedTotal = sets.reduce(0) { $0 + $1.ownedCount }
        let cardTotal = sets.reduce(0) { $0 + $1.totalCount }
        var out = "\(sets.count) set\(sets.count == 1 ? "" : "s") · \(ownedTotal)/\(cardTotal) cards"
        if complete > 0 { out += " · \(complete) complete" }
        return out
    }

    @ViewBuilder private func row(_ item: CardListItem) -> some View {
        if let cardId = item.thumbnailCardId {
            NavigationLink { CardDetailView(cardId: cardId) } label: {
                CardRow(item: item, imageURL: item.thumbnailURL)
            }
        } else {
            CardRow(item: item, imageURL: item.thumbnailURL)
        }
    }

    private static let prefetchLookahead = 8

    private func prefetchAhead(of index: Int, in items: [CardListItem]) {
        let upper = min(index + Self.prefetchLookahead, items.count)
        guard index + 1 < upper else { return }
        CardImagePrefetch.warm(items[(index + 1)..<upper].map(\.thumbnailURL),
                               size: CardArtSize.listThumb)
    }

    private func emptyMessage(_ items: [CardListItem]) -> (title: String, icon: String, detail: String)? {
        if items.isEmpty {
            switch scope {
            case .sets:
                return nil   // setsList() shows its own empty state
            case .owned:
                return inventory.rows.isEmpty
                    ? ("No inventory yet", "tray", "Add cards from Scan, then Sync. Pull down to refresh.")
                    : ("No owned cards match", "magnifyingglass", "Nothing you own matches “\(debouncedQuery)”.")
            case .all:
                return debouncedQuery.trimmingCharacters(in: .whitespaces).isEmpty
                    ? ("Search all cards", "magnifyingglass", "Type a card name to search the whole catalog.")
                    : ("No cards match", "magnifyingglass", "No cards match “\(debouncedQuery)”.")
            }
        }
        return nil
    }

    private func header(_ items: [CardListItem]) -> String {
        let cards = items.reduce(0) { $0 + $1.ownedCount }
        switch scope {
        case .owned:
            let printings = items.reduce(0) { $0 + $1.ownedPrintings.count }
            let reserved = items.reduce(0) { $0 + $1.reserved }
            let base = "\(cards) cards · \(items.count) unique · \(printings) printings"
            return reserved > 0 ? base + " · \(reserved) in use" : base
        case .all:
            return "\(items.count) result\(items.count == 1 ? "" : "s")"
        case .sets:
            return ""   // setsList() renders its own header
        }
    }

    // MARK: - sources

    private func ownedItems() -> [CardListItem] {
        // Every owned printing resolved against the catalog — the release date the sort
        // needs and the image URL the row needs. This used to be looked up inside the
        // sort comparator (two SQLite queries per comparison, ~n log n per pass), then
        // once per pass, and is now once per *inventory change*: typing, toggling a
        // filter and scrolling all reuse it. See docs/performance.md.
        let resolved = inventory.resolvedCards(using: catalog.lookup)

        let groups = SearchService.ownedGroups(query: debouncedQuery, rows: inventory.rows.asCoreRows,
                                               resolved: resolved, catalog: catalog.lookup,
                                               lens: legalityFormat)

        return groups.map { group -> CardListItem in
            let first = group.printings.first
            return CardListItem(
                id: group.equivalenceKey,
                name: group.name,
                ownedCount: group.ownedCount,
                ownedPrintings: group.printings.map {
                    // A linked promo reads as its equivalent card's designation:
                    // "MEP 075" shows as "CRI 029/086". Unlinked promos keep their own.
                    let designation = linkedDesignation($0) ?? "\($0.row.set.isEmpty ? ($0.row.code ?? "") : $0.row.set) \($0.row.number)"
                    var label = "\(designation) ×\($0.row.qty)"
                    if let loc = $0.row.location, !loc.isEmpty { label += "  ·  \(loc)" }
                    return CardListItem.Printing(id: $0.row.cardId, label: label)
                },
                printingCount: group.printings.count,
                thumbnailCardId: first?.row.cardId,
                formatLegal: nil,
                isPromo: ManualEntry.isManual(first?.row.cardId ?? ""),
                reserved: decks.reserved(forKey: group.equivalenceKey),
                thumbnailURL: first?.card?.imageSmall ?? borrowedArt(forKey: group.equivalenceKey)
            )
        }
        .filter { !freeOnly || $0.available > 0 }
    }

    /// A manual promo (or an imageless printing) has no art of its own — borrow the
    /// equivalent card's via the functional group. Only reached when the direct lookup
    /// came up empty, which is rare.
    private func borrowedArt(forKey key: String) -> String? {
        catalog.lookup?.cards(equivalenceKey: key).lazy.compactMap(\.imageSmall).first
    }

    /// A linked promo's display designation — its *equivalent* catalog card's code +
    /// zero-padded number/total (e.g. "CRI 029/086") — so it reads as that card in the
    /// list. nil for real cards and unlinked promos (they keep their own set/number).
    private func linkedDesignation(_ printing: OwnedRowPrinting) -> String? {
        guard ManualEntry.isManual(printing.row.cardId),
              let rep = catalog.lookup?.cards(equivalenceKey: printing.row.equivalenceKey).orderedNewestFirst().first
        else { return nil }
        let code = rep.ptcgoCode ?? rep.setName
        // The printed-card convention: floor the number at 3 digits. See
        // `CatalogCard.designation`.
        return "\(code) \(rep.designation(minWidth: 3))".trimmingCharacters(in: .whitespaces)
    }

    private func allItems() -> [CardListItem] {
        let trimmed = debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lookup = catalog.lookup, !trimmed.isEmpty else { return [] }
        return SearchService.search(query: trimmed, owned: inventory.owned, catalog: lookup, lens: legalityFormat)
            .filter { legalityFormat == nil || $0.formatLegal == true }
            .map { group in
                CardListItem(
                    id: group.equivalenceKey,
                    name: group.name,
                    ownedCount: group.ownedCount,
                    ownedPrintings: group.ownedPrintings.map {
                        CardListItem.Printing(
                            id: $0.card.cardId,
                            label: "\($0.card.ptcgoCode ?? $0.card.setName) \($0.card.number) ×\($0.qty)"
                        )
                    },
                    printingCount: group.printings.count,
                    thumbnailCardId: group.representative.cardId,
                    formatLegal: group.formatLegal,
                    reserved: decks.reserved(forKey: group.equivalenceKey),
                    thumbnailURL: group.representative.imageSmall
                )
            }
    }
}

/// The inputs a set recount depends on, bundled so `.task(id:)` fires on a real change
/// rather than on every `body`.
private struct SetsInputs: Equatable {
    let revision: Int
    let standardOnly: Bool
    let catalogLoaded: Bool
    let active: Bool
}

/// A unified card-group row for both scopes.
struct CardListItem: Identifiable {
    struct Printing: Identifiable { let id: String; let label: String }
    let id: String            // equivalence key
    let name: String
    let ownedCount: Int
    let ownedPrintings: [Printing]
    let printingCount: Int
    let thumbnailCardId: String?
    let formatLegal: Bool?
    var isPromo = false
    /// Copies reserved by decks (the in-use feature); `available` is owned − reserved.
    var reserved = 0
    /// Resolved when the item is built, so rendering a row costs no catalog reads.
    var thumbnailURL: String?
    var available: Int { max(0, ownedCount - reserved) }
}

private struct CardRow: View {
    let item: CardListItem
    let imageURL: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.name).font(.body.weight(.medium))
                    Spacer()
                    Text("own \(item.ownedCount)")
                        .font(.caption)
                        .foregroundStyle(item.ownedCount > 0 ? .green : .secondary)
                }
                Text("\(item.printingCount) printing\(item.printingCount == 1 ? "" : "s")")
                    .font(.caption2).foregroundStyle(.secondary)
                if item.reserved > 0 {
                    Label("\(item.reserved) in use · \(item.available) free", systemImage: "tray.full")
                        .font(.caption2)
                        .foregroundStyle(item.available > 0 ? Color.secondary : Color.orange)
                }
                ForEach(item.ownedPrintings) { p in
                    Text(p.label).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var thumbnail: some View {
        CardImage(urlString: imageURL, size: CardArtSize.listThumb)
            .overlay(alignment: .topTrailing) {
                if item.isPromo { PromoBadge(compact: true).padding(2) }
            }
    }
}
