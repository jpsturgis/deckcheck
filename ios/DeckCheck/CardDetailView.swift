import SwiftUI
import DeckCheckCore

/// Card detail: the full card image plus its info, your owned copies, and every
/// printing in the functional-equivalence group (owned marked). Read-only.
struct CardDetailView: View {
    let cardId: String

    @EnvironmentObject var catalog: Catalog
    @EnvironmentObject var inventory: InventoryStore
    @EnvironmentObject var outbox: Outbox
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showRelink = false

    private var card: CatalogCard? { catalog.lookup?.card(byId: cardId) }
    private var printings: [CatalogCard] {
        guard let key = card?.equivalenceKey else { return [] }
        return (catalog.lookup?.cards(equivalenceKey: key) ?? []).orderedNewestFirst()  // newest first
    }

    /// Owned rows for a card the catalog doesn't carry — a hand-entered promo,
    /// whose `manual:` id resolves nowhere in the snapshot.
    private var manualRows: [InventoryRow] {
        inventory.rows.filter { ($0.card_id == cardId || $0.equivalence_key == cardId) && $0.qty > 0 }
    }

    var body: some View {
        Group {
            if let card {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        heroImage(card)
                        info(card)
                        ownedSection(card)
                        copiesStepper(cardId: card.cardId, name: card.name, set: card.setName,
                                      code: card.ptcgoCode ?? "", number: card.number,
                                      equivalenceKey: card.equivalenceKey)
                        if inventory.rows.contains(where: { $0.card_id == card.cardId && $0.qty > 0 }) {
                            playsAsRealSection(card)
                        }
                        tcgplayerLink(name: card.name, setName: card.setName, number: card.number)
                        if printings.count > 1 { printingsSection }
                    }
                    .padding()
                }
            } else if !manualRows.isEmpty {
                manualDetail(manualRows)
            } else {
                ContentUnavailableView("Card not found", systemImage: "questionmark.square.dashed")
            }
        }
        .navigationTitle(card?.name ?? manualRows.first?.name ?? "Card")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showRelink) {
            if let lookup = catalog.lookup {
                PrintingPickerView(catalog: lookup, allowManualEntry: false,
                                   initialQuery: card?.name ?? manualRows.first?.name ?? "") { picked in
                    showRelink = false
                    performRelink(to: picked)
                }
            }
        }
    }

    /// Route a "plays as" pick to the right relink: a real catalog card gets converted
    /// to a linked promo; a hand-entered promo is re-keyed in place (existing path).
    private func performRelink(to target: CatalogCard) {
        if let card {
            relinkReal(card, to: target)
        } else {
            relink(manualRows, to: target)
        }
    }

    /// Detail for a hand-entered promo, built entirely from the inventory rows (no
    /// catalog image or legality — those don't exist for it).
    private func manualDetail(_ rows: [InventoryRow]) -> some View {
        let first = rows[0]
        let total = rows.reduce(0) { $0 + $1.qty }
        let place = first.set.isEmpty ? first.code : first.set
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                promoHero(imageURL: linkedImage(forKey: first.equivalence_key))
                VStack(spacing: 6) {
                    infoRow("Set", place.isEmpty ? "Promo" : place)
                    infoRow("Number", first.number)
                    if !first.code.isEmpty { infoRow("TCG set code", first.code) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("You own \(total)").font(.headline).foregroundStyle(.green)
                    ForEach(rows) { r in
                        Text(ownedLine(r)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                copiesStepper(cardId: first.card_id, name: first.name, set: first.set,
                              code: first.code, number: first.number,
                              equivalenceKey: first.equivalence_key)
                playsAsSection(first)
                tcgplayerLink(name: first.name,
                              setName: first.set.isEmpty ? first.code : first.set,
                              number: first.number)
                Label("Entered by hand — not in the catalog.", systemImage: "star.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    /// Link (or change) the catalog card this promo *plays as*, after the fact.
    /// Shows the current link, or a button to set one.
    @ViewBuilder private func playsAsSection(_ row: InventoryRow) -> some View {
        let linked = catalog.lookup?.cards(equivalenceKey: row.equivalence_key).orderedNewestFirst().first
        VStack(alignment: .leading, spacing: 6) {
            Text("Plays as").font(.headline)
            if let linked {
                HStack {
                    Text("\(linked.name) · \(linked.ptcgoCode ?? linked.setName) \(linked.number)")
                        .font(.subheadline)
                    Spacer()
                    Button("Change") { showRelink = true }.font(.subheadline)
                }
            } else {
                Button { showRelink = true } label: {
                    Label("Link the card it plays as", systemImage: "link")
                }
                .font(.subheadline)
                Text("Links this promo to its gameplay-identical card so it counts in the gap-check.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Re-key an existing promo to the card it plays as: remove the old rows and append
    /// them under the linked id + key. Old and new ids differ (ManualEntry folds the key
    /// in), so both ride one outbox batch without netting. Pops back to the list
    /// afterward since this card's id has changed.
    private func relink(_ rows: [InventoryRow], to card: CatalogCard) {
        guard let newCard = ManualEntry.promoCard(name: rows[0].name, code: rows[0].code,
                                                  number: rows[0].number,
                                                  equivalenceKey: card.equivalenceKey),
              newCard.cardId != rows[0].card_id else { return }   // no-op if already this link
        for row in rows {
            for _ in 0..<max(1, row.qty) {
                outbox.enqueue(OutboxOp(id: UUID().uuidString, op: .removal, card_id: row.card_id,
                                        name: row.name, set: row.set, code: row.code, number: row.number,
                                        location: row.location, equivalence_key: row.equivalence_key))
                outbox.enqueue(OutboxOp(id: UUID().uuidString, op: .intake, card_id: newCard.cardId,
                                        name: newCard.name, set: newCard.setName, code: newCard.ptcgoCode ?? "",
                                        number: newCard.number, location: row.location,
                                        equivalence_key: newCard.equivalenceKey))
            }
        }
        Task { await model.syncNow() }
        dismiss()
    }

    /// "Plays as" for a real catalog card you own (e.g. a promo whose source data
    /// differs from the set printing, so it lands in its own equivalence group). Lets
    /// you fold your copies into another card's functional group.
    @ViewBuilder private func playsAsRealSection(_ card: CatalogCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Plays as").font(.headline)
            Button { showRelink = true } label: {
                Label("Link the card it plays as", systemImage: "link")
            }
            .font(.subheadline)
            Text("Count your copies of this card as functional copies of another (e.g. a promo that plays as its set printing). Moves them into that card's group.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Convert a real catalog card you own into a promo linked to `target`: remove the
    /// real rows and re-add them as a `manual:` promo that adopts the target's
    /// equivalence group (so they count together). Same remove-old + append-new outbox
    /// pattern as `relink`, and the new id differs, so both ride one batch.
    private func relinkReal(_ card: CatalogCard, to target: CatalogCard) {
        guard target.equivalenceKey != card.equivalenceKey else { return } // already same group
        let rows = inventory.rows.filter { $0.card_id == card.cardId && $0.qty > 0 }
        guard !rows.isEmpty,
              let newCard = ManualEntry.promoCard(name: card.name, code: card.ptcgoCode ?? "",
                                                  number: card.number,
                                                  equivalenceKey: target.equivalenceKey)
        else { return }
        for row in rows {
            for _ in 0..<max(1, row.qty) {
                outbox.enqueue(OutboxOp(id: UUID().uuidString, op: .removal, card_id: row.card_id,
                                        name: row.name, set: row.set, code: row.code, number: row.number,
                                        location: row.location, equivalence_key: row.equivalence_key))
                outbox.enqueue(OutboxOp(id: UUID().uuidString, op: .intake, card_id: newCard.cardId,
                                        name: newCard.name, set: newCard.setName, code: newCard.ptcgoCode ?? "",
                                        number: newCard.number, location: row.location,
                                        equivalence_key: newCard.equivalenceKey))
            }
        }
        Task { await model.syncNow() }
        dismiss()
    }

    /// Jump out to TCGplayer's search for this exact printing (price-check / verify).
    @ViewBuilder private func tcgplayerLink(name: String, setName: String? = nil, number: String? = nil) -> some View {
        if let url = TCGplayerExport.searchURL(cardName: name, setName: setName, number: number) {
            Link(destination: url) {
                Label("View on TCGplayer", systemImage: "arrow.up.right.square")
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: sections

    @ViewBuilder private func heroImage(_ card: CatalogCard) -> some View {
        let urlString = card.imageLarge ?? card.imageSmall
        Group {
            if let s = urlString, let url = URL(string: s) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFit()
                    case .failure: imagePlaceholder
                    default: ProgressView().frame(height: 360)
                    }
                }
            } else {
                imagePlaceholder
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 440)
    }

    /// Hero for a hand-entered promo: its linked card's art with a PROMO badge,
    /// or the placeholder when the promo isn't linked to a catalog card.
    @ViewBuilder private func promoHero(imageURL: String?) -> some View {
        Group {
            if let s = imageURL, let url = URL(string: s) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFit()
                    case .failure: imagePlaceholder
                    default: ProgressView().frame(height: 360)
                    }
                }
            } else {
                imagePlaceholder
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 440)
        .overlay(alignment: .bottomTrailing) { PromoBadge().padding(10) }
    }

    /// The art of the catalog card this promo *plays as*, if any.
    private func linkedImage(forKey key: String) -> String? {
        catalog.lookup?.cards(equivalenceKey: key).lazy.compactMap { $0.imageLarge ?? $0.imageSmall }.first
    }

    private var imagePlaceholder: some View {
        RoundedRectangle(cornerRadius: 12).fill(.quaternary)
            .frame(height: 340)
            .overlay(Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary))
    }

    private func info(_ card: CatalogCard) -> some View {
        VStack(spacing: 6) {
            infoRow("Set", card.setName)
            infoRow("Number", card.printedTotal.map { "\(card.number)/\($0)" } ?? card.number)
            if let code = card.ptcgoCode, !code.isEmpty { infoRow("TCG Live code", code) }
            if let mark = card.regulationMark, !mark.isEmpty { infoRow("Regulation mark", mark) }
            infoRow("Standard", card.standardLegal ? "Legal" : "Not legal")
            infoRow("Expanded", card.expandedLegal ? "Legal" : "Not legal")
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.subheadline)
    }

    private func ownedSection(_ card: CatalogCard) -> some View {
        let owned = inventory.ownedCount(forKey: card.equivalenceKey)
        let mine = inventory.rows.filter { $0.equivalence_key == card.equivalenceKey && $0.qty > 0 }
        return VStack(alignment: .leading, spacing: 6) {
            Text(owned > 0 ? "You own \(owned)" : "You don’t own this card")
                .font(.headline)
                .foregroundStyle(owned > 0 ? .green : .secondary)
            ForEach(mine) { r in
                Text(ownedLine(r)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Adjust how many of *this printing* you own, right from the detail. Each tap
    /// enqueues one intake (+) or removal (−) op to the durable outbox, then syncs
    /// The count is optimistic — inventory qty plus the not-yet-synced outbox
    /// delta — so it moves the instant you tap, then reconciles when the sync lands.
    private func copiesStepper(cardId: String, name: String, set: String,
                               code: String, number: String, equivalenceKey: String) -> some View {
        let owned = effectiveQty(cardId: cardId)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your copies").font(.subheadline.weight(.medium))
                Text("this printing").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 12) {
                Button {
                    adjust(-1, cardId: cardId, name: name, set: set, code: code,
                           number: number, equivalenceKey: equivalenceKey)
                } label: { Image(systemName: "minus").frame(width: 18, height: 18) }
                .disabled(owned <= 0)
                Text("\(owned)").font(.title3.weight(.semibold)).monospacedDigit().frame(minWidth: 28)
                Button {
                    adjust(1, cardId: cardId, name: name, set: set, code: code,
                           number: number, equivalenceKey: equivalenceKey)
                } label: { Image(systemName: "plus").frame(width: 18, height: 18) }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
        }
        .frame(maxWidth: .infinity)
    }

    /// Owned copies of one printing, including pending (unsynced) outbox ops so the
    /// stepper responds immediately: intake counts +1, removal −1.
    private func effectiveQty(cardId: String) -> Int {
        let synced = inventory.rows.first { $0.card_id == cardId }?.qty ?? 0
        let pending = outbox.pending.filter { $0.card_id == cardId }
            .reduce(0) { $0 + ($1.op == .intake ? 1 : -1) }
        return max(0, synced + pending)
    }

    private func adjust(_ delta: Int, cardId: String, name: String, set: String,
                        code: String, number: String, equivalenceKey: String) {
        outbox.enqueue(OutboxOp(
            id: UUID().uuidString,
            op: delta > 0 ? .intake : .removal,
            card_id: cardId,
            name: name, set: set, code: code, number: number,
            location: "", equivalence_key: equivalenceKey
        ))
        Task { await model.syncNow() }
    }

    private func ownedLine(_ r: InventoryRow) -> String {
        let place = r.set.isEmpty ? r.code : r.set
        var line = "\(place) \(r.number) ×\(r.qty)"
        if !r.location.isEmpty { line += "  ·  \(r.location)" }
        return line
    }

    private var printingsSection: some View {
        let ownedIds = Set(inventory.rows.filter { $0.qty > 0 }.map(\.card_id))
        return VStack(alignment: .leading, spacing: 10) {
            Text("Printings (\(printings.count))").font(.headline)
            ForEach(printings, id: \.cardId) { p in
                let isCurrent = p.cardId == cardId
                if isCurrent {
                    printingRow(p, owned: ownedIds.contains(p.cardId), current: true)
                } else {
                    // Tap a printing to open its own full detail (spec follow-up).
                    NavigationLink {
                        CardDetailView(cardId: p.cardId)
                    } label: {
                        printingRow(p, owned: ownedIds.contains(p.cardId), current: false)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func printingRow(_ p: CatalogCard, owned: Bool, current: Bool) -> some View {
        HStack(spacing: 10) {
            printingThumb(p.imageSmall)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(p.ptcgoCode ?? p.setName) \(p.number)")
                Text(p.setName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if owned {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            if current {
                Text("current").font(.caption2).foregroundStyle(.tertiary)
            } else {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private func printingThumb(_ s: String?) -> some View {
        if let s, let url = URL(string: s) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            }
            .frame(width: 34, height: 47)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 34, height: 47)
        }
    }
}
