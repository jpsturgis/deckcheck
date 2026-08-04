import SwiftUI
import DeckCheckCore

/// Correction picker: when the scan is wrong or uncertain, search by name
/// and pick the exact printing by eye (images disambiguate reprints/alt-arts). Returns
/// the chosen `CatalogCard`. The search field auto-focuses so the keyboard is up the
/// moment it opens — no extra tap to start typing.
struct PrintingPickerView: View {
    let catalog: any CatalogLookup & CatalogSearching
    /// Whether to offer the "enter a promo manually" escape hatch. Off when this picker
    /// is itself being used to pick the card a promo *plays as* (no recursion).
    var allowManualEntry = true
    let onPick: (CatalogCard) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var groups: [SearchResultGroup] = []
    @State private var showManual = false
    @FocusState private var searchFocused: Bool
    /// Shared with the Cards screen — limit the search to Standard-legal cards.
    @AppStorage("standardOnly") private var standardOnly = false

    init(catalog: any CatalogLookup & CatalogSearching,
         allowManualEntry: Bool = true,
         initialQuery: String = "",
         onPick: @escaping (CatalogCard) -> Void) {
        self.catalog = catalog
        self.allowManualEntry = allowManualEntry
        self.onPick = onPick
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                HStack {
                    Toggle(isOn: $standardOnly) {
                        Label("Standard only", systemImage: standardOnly ? "checkmark.seal.fill" : "seal")
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.footnote)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.bottom, 4)
                List {
                    ForEach(groups, id: \.equivalenceKey) { group in
                        Section(group.name) {
                            ForEach(group.printings, id: \.cardId) { card in
                                Button { onPick(card); dismiss() } label: { row(card) }
                            }
                        }
                    }
                    if !query.isEmpty && groups.isEmpty {
                        Text("No cards match “\(query)”.").foregroundStyle(.secondary)
                    }
                    if allowManualEntry { manualEntrySection }
                }
                .listStyle(.plain)
                .scrollDismissesKeyboard(.immediately)
            }
            .navigationTitle(allowManualEntry ? "Pick the printing" : "Which card does it play as?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onChange(of: query) { _, _ in run() }
            .onChange(of: standardOnly) { _, _ in run() }
            .navigationDestination(isPresented: $showManual) {
                ManualPromoEntryView(defaultName: query, catalog: catalog) { card in
                    onPick(card)
                    dismiss()
                }
            }
            .task {
                if !query.isEmpty { run() }   // seed results for a pre-filled query
                // Focus once the sheet has settled so the keyboard rises immediately.
                try? await Task.sleep(nanoseconds: 350_000_000)
                searchFocused = true
            }
        }
    }

    /// Escape hatch for promos the catalog can't list: brand-new
    /// promo sets (Mega Evolution Promos / MEP, …) lag the source, so no name search
    /// will find them. Enter the printed name + set code + number by hand instead.
    private var manualEntrySection: some View {
        Section {
            Button { showManual = true } label: {
                Label(query.trimmingCharacters(in: .whitespaces).isEmpty
                        ? "Enter a promo manually"
                        : "Not here? Enter “\(query)” as a promo",
                      systemImage: "star.circle")
            }
        } footer: {
            Text("For promos the catalog doesn’t list yet — e.g. Mega Evolution Promos (MEP).")
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Name, set, or number", text: $query)
                .focused($searchFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func row(_ card: CatalogCard) -> some View {
        HStack(spacing: 10) {
            thumbnail(card)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.name)
                Text("\(card.ptcgoCode ?? card.setName) \(card.number)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private func thumbnail(_ card: CatalogCard) -> some View {
        // Larger than a list thumb so the card's art + text are legible when comparing
        // a promo to the printing it plays as.
        CardImage(urlString: card.imageSmall, size: CardArtSize.pickerThumb, cornerRadius: 6)
    }

    private func run() {
        // Scan correction: surface the most recent printing first (newest set on top).
        var results = SearchService.search(query: query, owned: [], catalog: catalog,
                                           order: .ownedThenNewest, maxGroups: 30)
        if standardOnly {
            results = results.filter { $0.printings.contains { $0.standardLegal } }
        }
        groups = results
    }
}
