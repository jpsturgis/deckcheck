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

    enum Scope: String, CaseIterable { case owned = "Owned", all = "All" }
    @State private var scope: Scope = .owned
    @State private var query = ""
    @State private var addingPromo = false

    /// Show only Standard-legal cards. Off by default → your whole collection shows.
    /// Persisted and shared with the equivalent-card picker.
    @AppStorage("standardOnly") private var standardOnly = false
    /// Show only cards with a free (unreserved) copy — owned minus what decks use.
    @AppStorage("freeOnly") private var freeOnly = false
    private var legalityFormat: LegalityFormat? { standardOnly ? .standard : nil }

    private var items: [CardListItem] {
        scope == .owned ? ownedItems() : allItems()
    }

    var body: some View {
        NavigationStack {
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
                            Toggle(isOn: $freeOnly) {
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

                content
            }
            .navigationTitle("Cards")
            .searchable(text: $query, prompt: scope == .owned ? "Your cards — name, set, or number" : "Search — name, set, or number")
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
            equivalence_key: card.equivalenceKey
        ))
        addingPromo = false
        Task { await model.syncNow() }
    }

    @ViewBuilder private var content: some View {
        if scope == .all && catalog.lookup == nil {
            ContentUnavailableView("No catalog", systemImage: "tray", description: Text(catalog.status))
        } else if let empty = emptyMessage {
            ContentUnavailableView(empty.title, systemImage: empty.icon, description: Text(empty.detail))
        } else {
            List {
                Section {
                    ForEach(items) { item in
                        if let cardId = item.thumbnailCardId {
                            NavigationLink {
                                CardDetailView(cardId: cardId)
                            } label: {
                                CardRow(item: item, imageURL: thumbnail(item))
                            }
                        } else {
                            CardRow(item: item, imageURL: thumbnail(item))
                        }
                    }
                } header: {
                    Text(header)
                }
            }
            .listStyle(.plain)
        }
    }

    private var emptyMessage: (title: String, icon: String, detail: String)? {
        if items.isEmpty {
            switch scope {
            case .owned:
                return inventory.rows.isEmpty
                    ? ("No inventory yet", "tray", "Add cards from Scan, then Sync. Pull down to refresh.")
                    : ("No owned cards match", "magnifyingglass", "Nothing you own matches “\(query)”.")
            case .all:
                return query.trimmingCharacters(in: .whitespaces).isEmpty
                    ? ("Search all cards", "magnifyingglass", "Type a card name to search the whole catalog.")
                    : ("No cards match", "magnifyingglass", "No cards match “\(query)”.")
            }
        }
        return nil
    }

    private var header: String {
        let cards = items.reduce(0) { $0 + $1.ownedCount }
        switch scope {
        case .owned:
            let printings = items.reduce(0) { $0 + $1.ownedPrintings.count }
            let reserved = items.reduce(0) { $0 + $1.reserved }
            let base = "\(cards) cards · \(items.count) unique · \(printings) printings"
            return reserved > 0 ? base + " · \(reserved) in use" : base
        case .all:
            return "\(items.count) result\(items.count == 1 ? "" : "s")"
        }
    }

    private func thumbnail(_ item: CardListItem) -> String? {
        if let cardId = item.thumbnailCardId, let img = catalog.lookup?.card(byId: cardId)?.imageSmall {
            return img
        }
        // Manual promo (or an imageless printing): borrow the equivalent card's art via
        // the functional group.
        return catalog.lookup?.cards(equivalenceKey: item.id).lazy.compactMap(\.imageSmall).first
    }

    // MARK: - sources

    private func ownedItems() -> [CardListItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var byKey: [String: [InventoryRow]] = [:]
        var order: [String] = []
        for row in inventory.rows where row.qty > 0 {
            if !q.isEmpty && !row.name.lowercased().contains(q) { continue }
            if byKey[row.equivalence_key] == nil { order.append(row.equivalence_key) }
            byKey[row.equivalence_key, default: []].append(row)
        }
        return order.map { key -> CardListItem in
            // Newest printing first; the sheet cache has no release date, so pull
            // it from the catalog per printing. Rows the catalog can't place (manual
            // promos) fall back to set/number ordering behind the dated ones.
            let printings = byKey[key]!.sorted { a, b in
                let da = catalog.lookup?.card(byId: a.card_id)?.releaseDate ?? ""
                let db = catalog.lookup?.card(byId: b.card_id)?.releaseDate ?? ""
                if da != db { return da > db }
                return (a.set, a.number) < (b.set, b.number)
            }
            return CardListItem(
                id: key,
                name: printings.first?.name ?? "—",
                ownedCount: printings.reduce(0) { $0 + $1.qty },
                ownedPrintings: printings.map {
                    // A linked promo reads as its equivalent card's designation:
                    // "MEP 075" shows as "CRI 029/086". Unlinked promos keep their own.
                    let designation = linkedDesignation($0) ?? "\($0.set.isEmpty ? $0.code : $0.set) \($0.number)"
                    var label = "\(designation) ×\($0.qty)"
                    if !$0.location.isEmpty { label += "  ·  \($0.location)" }
                    return CardListItem.Printing(id: $0.card_id, label: label)
                },
                printingCount: printings.count,
                thumbnailCardId: printings.first?.card_id,
                formatLegal: nil,
                isPromo: ManualEntry.isManual(printings.first?.card_id ?? ""),
                reserved: decks.reserved(forKey: key)
            )
        }
        .filter { legalityFormat == nil || ownedGroupIsLegal($0) }
        .filter { !freeOnly || $0.available > 0 }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// A linked promo's display designation — its *equivalent* catalog card's code +
    /// zero-padded number/total (e.g. "CRI 029/086") — so it reads as that card in the
    /// list. nil for real cards and unlinked promos (they keep their own set/number).
    private func linkedDesignation(_ row: InventoryRow) -> String? {
        guard ManualEntry.isManual(row.card_id),
              let rep = catalog.lookup?.cards(equivalenceKey: row.equivalence_key).orderedNewestFirst().first
        else { return nil }
        let code = rep.ptcgoCode ?? rep.setName
        let number: String
        if let total = rep.printedTotal, rep.number.allSatisfy(\.isNumber) {
            // Zero-pad both to ≥3 digits, the printed-card convention → "029/086".
            let width = max(3, String(total).count, rep.number.count)
            func pad(_ s: String) -> String { String(repeating: "0", count: max(0, width - s.count)) + s }
            number = "\(pad(rep.number))/\(pad(String(total)))"
        } else {
            number = rep.number
        }
        return "\(code) \(number)".trimmingCharacters(in: .whitespaces)
    }

    /// An owned group passes the filter if any owned printing is legal in the format.
    /// A promo's own `manual:` id isn't in the catalog, so judge it by its linked
    /// equivalent card(s) (the group key) instead of dropping it.
    private func ownedGroupIsLegal(_ item: CardListItem) -> Bool {
        guard let fmt = legalityFormat else { return true }
        func legal(_ c: CatalogCard) -> Bool { fmt == .standard ? c.standardLegal : c.expandedLegal }
        return item.ownedPrintings.contains { p in
            if let c = catalog.lookup?.card(byId: p.id) { return legal(c) }
            return (catalog.lookup?.cards(equivalenceKey: item.id) ?? []).contains(where: legal)
        }
    }

    private func allItems() -> [CardListItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
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
                    reserved: decks.reserved(forKey: group.equivalenceKey)
                )
            }
    }
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
        Group {
            if let s = imageURL, let url = URL(string: s) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                }
                .frame(width: 40, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 40, height: 56)
            }
        }
        .overlay(alignment: .topTrailing) {
            if item.isPromo { PromoBadge(compact: true).padding(2) }
        }
    }
}
