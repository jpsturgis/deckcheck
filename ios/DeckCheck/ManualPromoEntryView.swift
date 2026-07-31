import SwiftUI
import DeckCheckCore

/// Hand-enter a promo the catalog doesn't carry. Promos print
/// their own code + number by a black star (e.g. "MEP EN 075") with no "/total", and
/// new promo sets lag the pokemontcg.io source — so this records name + set code +
/// number directly. It hands back a synthesized `CatalogCard` (via `ManualEntry`) so
/// the promo can commit through intake / inventory / removal like any resolved
/// printing. Reused from the scan correction picker (into a batch) and from the Cards
/// tab (committed straight to the outbox).
///
/// Optionally link the catalog card the promo *plays as*: the promo adopts that
/// card's functional-equivalence group, so it counts as a copy in the gap-check.
struct ManualPromoEntryView: View {
    let onSave: (CatalogCard) -> Void
    /// For the "plays as" search; nil hides the link option (no catalog loaded).
    var catalog: (any CatalogLookup & CatalogSearching)?

    @State private var name: String
    @State private var code = ""
    @State private var number = ""
    @State private var playsAs: CatalogCard?
    @State private var showPlaysAs = false
    @FocusState private var focus: Field?
    private enum Field { case name, code, number }

    init(defaultName: String = "",
         catalog: (any CatalogLookup & CatalogSearching)? = nil,
         onSave: @escaping (CatalogCard) -> Void) {
        self.onSave = onSave
        self.catalog = catalog
        _name = State(initialValue: defaultName.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var card: CatalogCard? {
        ManualEntry.promoCard(name: name, code: code, number: number,
                              equivalenceKey: playsAs?.equivalenceKey)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name (e.g. Ampharos)", text: $name)
                    .focused($focus, equals: .name)
                    .textInputAutocapitalization(.words).autocorrectionDisabled()
                TextField("Set code (e.g. MEP)", text: $code)
                    .focused($focus, equals: .code)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                TextField("Number (e.g. 075)", text: $number)
                    .focused($focus, equals: .number)
                    .autocorrectionDisabled()
            } header: {
                Text("Promo card")
            } footer: {
                Text("The name, plus the set code and number by the black star (e.g. “MEP EN 075”). Saved as \(preview).")
            }

            if catalog != nil { playsAsSection }
        }
        .navigationTitle("Add a promo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { if let c = card { onSave(c) } }
                    .disabled(card == nil)
            }
        }
        .onAppear { focus = name.isEmpty ? .name : .code }
        .sheet(isPresented: $showPlaysAs) {
            if let catalog {
                PrintingPickerView(catalog: catalog, allowManualEntry: false, initialQuery: name) { picked in
                    playsAs = picked
                    showPlaysAs = false
                }
            }
        }
    }

    /// Optional link to the catalog card this promo is gameplay-identical to, so the
    /// gap-check counts it as a functional copy.
    @ViewBuilder private var playsAsSection: some View {
        Section {
            if let p = playsAs {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name)
                        Text("\(p.ptcgoCode ?? p.setName) \(p.number)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Change") { showPlaysAs = true }
                        .buttonStyle(.borderless)
                    Button(role: .destructive) { playsAs = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            } else {
                Button { showPlaysAs = true } label: {
                    Label("Link the card it plays as", systemImage: "link")
                }
            }
        } header: {
            Text("Plays as (optional)")
        } footer: {
            Text("Pick the catalog card this promo is gameplay-identical to, so it counts as a copy in the gap-check. Skip it to just log the promo.")
        }
    }

    /// Live echo of the row that will be stored, so the user can eyeball it.
    private var preview: String {
        guard let c = card else { return "…" }
        let bracket = c.ptcgoCode.map { "[\($0)] " } ?? ""
        return "\(c.name) \(bracket)\(c.number)"
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
