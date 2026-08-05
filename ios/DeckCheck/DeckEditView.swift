import SwiftUI
import UIKit
import DeckCheckCore

/// Editing a deck's card lines, over a **draft** of the tab's text.
///
/// Every mutation goes through `DeckEditor`, which edits the text surgically — so the
/// section headers, blank lines, `#built:` directive and any notes in the tab come back
/// out unchanged. Nothing reaches the Sheet until Save; Cancel throws the draft away.
struct DeckEditView: View {
    let deck: DeckList
    @Binding var draft: String
    let onDone: () -> Void

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var catalog: Catalog
    @AppStorage("standardOnly") private var standardOnly = false

    @State private var picking = false
    @State private var saving = false
    @State private var saveError: String?

    private var lens: LegalityFormat? { standardOnly ? .standard : nil }

    private var entries: [DeckEditor.Entry] { DeckEditor.entries(draft) }

    private var violations: [DeckViolation] {
        guard let lookup = catalog.lookup else { return [] }
        return DeckValidator.validate(decklist: draft, catalog: lookup, lens: lens)
    }

    var body: some View {
        Form {
            if !violations.isEmpty {
                Section("Legality") {
                    ForEach(violations) { v in
                        Label(v.message, systemImage: icon(for: v))
                            .font(.callout)
                            .foregroundStyle(color(for: v))
                    }
                }
            }

            Section {
                ForEach(entries) { entry in
                    row(entry)
                }
                .onDelete { offsets in
                    // Delete high indices first so earlier removals don't shift them.
                    for index in offsets.sorted(by: >) {
                        draft = DeckEditor.remove(atLine: entries[index].lineIndex, in: draft)
                    }
                }

                Button {
                    picking = true
                } label: {
                    Label("Add card", systemImage: "plus.circle")
                }
                .disabled(catalog.lookup == nil)
            } header: {
                Text("\(cardTotal) cards · \(entries.count) lines")
            } footer: {
                Text("Swipe a line to delete it. Comments, blank rows and the “#built:” line in your Sheet tab are left untouched.")
            }
        }
        .navigationTitle("Edit \(deck.name)")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(saving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { onDone() }.disabled(saving)
            }
            ToolbarItem(placement: .confirmationAction) {
                if saving {
                    ProgressView()
                } else {
                    Button("Save") { save() }
                }
            }
        }
        .sheet(isPresented: $picking) {
            if let lookup = catalog.lookup {
                PrintingPickerView(catalog: lookup, allowManualEntry: false) { card in
                    draft = DeckEditor.add(card, quantity: 1, to: draft, catalog: lookup)
                    picking = false
                }
            }
        }
        .alert("Couldn’t save deck", isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } })
        ) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: -

    private var cardTotal: Int { entries.reduce(0) { $0 + $1.quantity } }

    @ViewBuilder private func row(_ entry: DeckEditor.Entry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.body)
                Text(designation(entry)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Stepper(
                value: Binding(
                    get: { entry.quantity },
                    set: { draft = DeckEditor.setQuantity($0, atLine: entry.lineIndex, in: draft) }
                ),
                in: 0...99
            ) {
                Text("\(entry.quantity)")
                    .font(.body.monospacedDigit())
                    .frame(minWidth: 22, alignment: .trailing)
            }
            .labelsHidden()
            // The label is rendered separately so the stepper's own hit area stays
            // small — a Form row with a full-width Stepper swallows taps meant for it.
            .overlay(alignment: .leading) {
                Text("\(entry.quantity)")
                    .font(.body.monospacedDigit())
                    .offset(x: -26)
            }
        }
    }

    private func designation(_ entry: DeckEditor.Entry) -> String {
        let parsed = entry.parsed
        if let code = parsed.setCode, let number = parsed.number { return "\(code) \(number)" }
        return "no set/number"
    }

    private func icon(for v: DeckViolation) -> String {
        switch v.kind {
        case .cardCount:    return "number.circle"
        case .copyLimit:    return "exclamationmark.triangle"
        case .notLegal:     return "seal.slash"
        case .unidentified: return "questionmark.circle"
        }
    }

    private func color(for v: DeckViolation) -> Color {
        if case .unidentified = v.kind { return .secondary }
        return .orange
    }

    private func save() {
        saving = true
        Task {
            let error = await model.saveDeck(deck, text: draft)
            saving = false
            if let error {
                saveError = error   // draft is kept, so Save can be retried
            } else {
                onDone()
            }
        }
    }
}
