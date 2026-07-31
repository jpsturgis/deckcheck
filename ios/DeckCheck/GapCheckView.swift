import SwiftUI
import UIKit
import DeckCheckCore

/// Decklist gap-check: paste a TCG Live / Limitless list → gap-first
/// report + a TCGplayer buy list you can copy or open pre-filled. Functional
/// ownership is the criterion; unidentified lines (promos) get a review step.
struct GapCheckView: View {
    @EnvironmentObject var catalog: Catalog
    @EnvironmentObject var model: AppModel

    @State private var deckText = ""
    @State private var checkedText: String?
    @State private var showAddDeck = false
    @State private var deckName = ""
    @State private var addDeckStatus: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $deckText)
                        .frame(minHeight: 130)
                        .font(.system(.footnote, design: .monospaced))
                    HStack {
                        // .borderless makes each button its own hit target — otherwise a
                        // tap in this Form row fires BOTH (Check *and* Clear).
                        Button("Check") { checkedText = deckText }
                            .buttonStyle(.borderless)
                            .disabled(catalog.lookup == nil || deckText.isEmpty)
                        Spacer()
                        Button("Clear", role: .destructive) {
                            deckText = ""
                            checkedText = nil
                            hideKeyboard()
                        }
                        .buttonStyle(.borderless)
                        .disabled(deckText.isEmpty && checkedText == nil)
                    }
                } header: {
                    Text("Decklist")
                } footer: {
                    Text("Tip: your Sheet also has a “Gap Check” tab — paste a decklist into column A there and the report fills in on the next sync.")
                }

                if let checkedText {
                    Section {
                        Button {
                            deckName = ""
                            showAddDeck = true
                        } label: {
                            Label("Add as deck", systemImage: "plus.rectangle.on.folder")
                        }
                        .disabled(!model.sheets.isConnected)
                        if let addDeckStatus {
                            Text(addDeckStatus).font(.caption).foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("Saves this list as a “Deck: <name>” tab in your Sheet — it then reserves your cards and appears under Decks.")
                    }
                    GapReportView(decklist: checkedText)
                }
            }
            .navigationTitle("Gap Check")
            .scrollDismissesKeyboard(.interactively)
            .keyboardDoneButton()
            .alert("Name this deck", isPresented: $showAddDeck) {
                TextField("Deck name", text: $deckName)
                Button("Add") {
                    guard let list = checkedText else { return }
                    let name = deckName
                    Task { addDeckStatus = await model.addDeck(name: name, decklist: list) }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}
