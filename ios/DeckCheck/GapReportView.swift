import SwiftUI
import DeckCheckCore

/// A decklist gap-check with a **review step** for lines the catalog couldn't
/// identify (spec §7.4) — usually promos or brand-new cards. Tap an unresolved line
/// to pick the card it is (search the catalog, or enter it as a promo and link what
/// it plays as); it's then counted. Overrides are in-memory for this view.
///
/// Shared by the Gap Check scratchpad and the per-deck view: both hand it a decklist
/// string; it owns the resolve/override state and the report rendering.
struct GapReportView: View {
    let decklist: String

    @EnvironmentObject var catalog: Catalog
    @EnvironmentObject var inventory: InventoryStore
    @AppStorage("standardOnly") private var standardOnly = false

    @State private var resolved: [ResolvedLine] = []
    @State private var resolvingIndex: Int?

    private var lens: LegalityFormat? { standardOnly ? .standard : nil }

    private var report: GapReport? {
        guard let lookup = catalog.lookup else { return nil }
        return GapChecker.report(resolved: resolved, owned: inventory.owned, catalog: lookup, lens: lens)
    }

    /// Indices of lines still unidentified (the review queue).
    private var unresolved: [Int] {
        resolved.indices.filter {
            if case .unidentified = resolved[$0].resolution { return true }
            return false
        }
    }

    var body: some View {
        Group {
            if let report {
                GapReportSections(report: report)
                if !unresolved.isEmpty {
                    Section {
                        ForEach(unresolved, id: \.self) { i in
                            Button { resolvingIndex = i } label: {
                                HStack {
                                    Text(lineLabel(resolved[i].parsed)).font(.footnote)
                                    Spacer()
                                    Label("Resolve", systemImage: "questionmark.circle")
                                        .labelStyle(.iconOnly)
                                }
                            }
                        }
                    } header: {
                        Text("❓ Couldn’t identify — tap to resolve")
                    } footer: {
                        Text("Pick the card each line is — search the catalog, or enter it as a promo and link the card it plays as. It then counts in the check.")
                    }
                }
            } else {
                Section {
                    Text(catalog.status).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { if resolved.isEmpty { resolve() } }
        .onChange(of: decklist) { _, _ in resolve() }
        .sheet(isPresented: Binding(get: { resolvingIndex != nil },
                                    set: { if !$0 { resolvingIndex = nil } })) {
            if let i = resolvingIndex, i < resolved.count, let lookup = catalog.lookup {
                PrintingPickerView(catalog: lookup, allowManualEntry: true,
                                   initialQuery: resolved[i].parsed.name) { picked in
                    resolved[i] = ResolvedLine(parsed: resolved[i].parsed, resolution: .resolved(picked))
                    resolvingIndex = nil
                }
            }
        }
    }

    private func resolve() {
        guard let lookup = catalog.lookup else { resolved = []; return }
        resolved = DecklistParser.parse(decklist).map { LineResolver.resolve($0, catalog: lookup) }
    }

    private func lineLabel(_ p: ParsedLine) -> String {
        var s = "\(p.quantity)× \(p.name)"
        if let code = p.setCode { s += " \(code)" }
        if let num = p.number { s += " \(num)" }
        return s
    }
}
