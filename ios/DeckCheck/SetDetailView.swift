import SwiftUI
import UIKit
import DeckCheckCore

/// One set's completion: what you have, what you're missing, and a buy list for the
/// gap — the same shape as a decklist gap-check, pointed at a set instead of a deck.
struct SetDetailView: View {
    let setId: String

    @EnvironmentObject var inventory: InventoryStore
    @EnvironmentObject var catalog: Catalog

    @State private var progress: SetProgress?
    @State private var missing: [CatalogCard] = []
    @State private var owned: [CatalogCard] = []
    @State private var copied = false

    /// Missing and Have are two lists of the same kind, and a nearly-complete set puts
    /// hundreds of Have rows between you and them. A scope switch beats stacked
    /// sections — it's also what the Cards screen above already does.
    @State private var scope: Scope = .missing
    @State private var pickedInitialScope = false

    enum Scope: String, CaseIterable { case missing = "Missing", have = "Have" }

    private var shown: [CatalogCard] { scope == .missing ? missing : owned }

    var body: some View {
        List {
            if let progress {
                Section {
                    SetProgressBar(progress: progress)
                        .padding(.vertical, 4)
                } header: {
                    Text("Progress")
                } footer: {
                    Text(footerText(progress))
                }
            }

            if !missing.isEmpty {
                Section {
                    Button {
                        UIPasteboard.general.string = buyList
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy buy list (\(missing.count))",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                } footer: {
                    Text("A TCGplayer Mass Entry list of everything you're missing from this set.")
                }
            }

            Section {
                Picker("Show", selection: $scope) {
                    Text("Missing (\(missing.count))").tag(Scope.missing)
                    Text("Have (\(owned.count))").tag(Scope.have)
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))

                if shown.isEmpty {
                    Text(scope == .missing
                         ? "Nothing missing — this set is complete."
                         : "You don't have any cards from this set yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(shown, id: \.cardId) { card in
                        NavigationLink { CardDetailView(cardId: card.cardId) } label: {
                            SetCardRow(card: card, owned: scope == .have)
                        }
                    }
                }
            }
        }
        .navigationTitle(progress?.name ?? "Set")
        .navigationBarTitleDisplayMode(.inline)
        // Keyed on the inventory revision so adjusting a count anywhere else in the app
        // is reflected here without recomputing on every body pass.
        .task(id: inventory.revision) { reload() }
    }

    private func reload() {
        guard let lookup = catalog.lookup else { return }
        progress = SetCompletion.progress(forSet: setId, owned: inventory.owned, catalog: lookup)

        let ownedIds = Set(inventory.owned.lazy.filter { $0.qty > 0 }.map(\.cardId))
        let all = lookup.cards(setId: setId)
        missing = all.filter { !ownedIds.contains($0.cardId) }
        owned = all.filter { ownedIds.contains($0.cardId) }
        copied = false

        // A complete set would otherwise open on an empty Missing list. Only on first
        // load — after that the switch is the user's, and a sync shouldn't move it.
        if !pickedInitialScope {
            pickedInitialScope = true
            if missing.isEmpty && !owned.isEmpty { scope = .have }
        }
    }

    private var buyList: String {
        TCGplayerExport.massEntry(missing.map { (quantity: 1, card: $0) })
    }

    private func footerText(_ p: SetProgress) -> String {
        var parts = ["Counted by printing — a reprint in another set doesn't fill a slot here."]
        if let printed = p.catalogSet.printedTotal, printed > 0, printed != p.totalCount {
            parts.append("The set is printed as \(printed) cards; your catalog has \(p.totalCount).")
        }
        parts.append("Hand-entered promos can't count toward a set — they aren't tied to a catalog printing.")
        return parts.joined(separator: " ")
    }
}

/// The shared progress readout — bar, count, and percentage.
struct SetProgressBar: View {
    let progress: SetProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(progress.name).font(.body.weight(.medium))
                Spacer()
                if progress.isComplete {
                    Label("Complete", systemImage: "checkmark.seal.fill")
                        .font(.caption).foregroundStyle(.green)
                }
            }
            ProgressView(value: progress.fraction)
                .tint(progress.isComplete ? .green : .accentColor)
            HStack {
                Text("\(progress.ownedCount)/\(progress.totalCount)")
                    .font(.caption.monospacedDigit())
                if let code = progress.ptcgoCode {
                    Text("·  \(code)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int((progress.fraction * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SetCardRow: View {
    let card: CatalogCard
    let owned: Bool

    var body: some View {
        HStack(spacing: 10) {
            CardImage(urlString: card.imageSmall, size: CardArtSize.listThumb)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.name).font(.body)
                Text(designation).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if owned {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    /// "125/197" where the set has a printed total, else the bare collector number.
    /// Zero is "no total", not a total — promo sets carry 0, and a black star promo
    /// prints its number without one. See `TCGplayerExport.numberField`.
    private var designation: String {
        guard let total = card.printedTotal, total > 0, card.number.allSatisfy(\.isNumber) else {
            return card.number
        }
        let width = max(3, String(total).count, card.number.count)
        func pad(_ s: String) -> String { String(repeating: "0", count: max(0, width - s.count)) + s }
        return "\(pad(card.number))/\(pad(String(total)))"
    }
}
