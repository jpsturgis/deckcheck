import SwiftUI
import UIKit
import DeckCheckCore

/// Decklist gap-check: paste a TCG Live / Limitless list → gap-first
/// report + a TCGplayer buy list you can copy or open pre-filled. Functional
/// ownership is the criterion; unidentified lines (promos) get a review step.
struct GapCheckView: View {
    @EnvironmentObject var catalog: Catalog
    @EnvironmentObject var model: AppModel
    @StateObject private var inbox = DecklistInbox.shared

    @State private var deckText = ""
    @State private var checkedText: String?
    @State private var showAddDeck = false
    @State private var deckName = ""
    @State private var addDeckStatus: String?

    /// Why an incoming decklist was refused, if it was.
    @State private var ingestNotice: String?

    /// A pasted decklist held back for confirmation because the editor already has
    /// something in it. Pasting over your own text should be possible, but not silent.
    @State private var pendingReplacement: String?

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

                    // Its own row on purpose. `PasteButton` is a system control with
                    // known hit-testing trouble when it's drawn tight against a text
                    // field, and this Form already had a two-buttons-in-one-row tap
                    // collision (see .borderless above) — so it gets its own cell.
                    //
                    // **Rendered unconditionally.** Wrapping it in an `if` looked
                    // tidier — hide it when there's nothing to paste — but putting a
                    // `PasteButton` behind a condition means SwiftUI removes and
                    // re-inserts it, and the recycled `UIPasteControl` comes back
                    // without its privileged status: greyed out, and prompting for
                    // permission on tap, until the app is relaunched. One instance that
                    // is never re-inserted is the fix.
                    //
                    // Letting the system own the enabled state is also simply more
                    // correct than tracking it here: it fades the control from its own
                    // live view of the pasteboard, where `hasStrings` was a copy that
                    // went stale the moment anything changed.
                    PasteButton(payloadType: String.self) { strings in
                        guard let text = strings.first else { return }
                        accept(text)
                    }
                    .buttonBorderShape(.capsule)

                    if let ingestNotice {
                        Text(ingestNotice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
            .onAppear {
                claimSharedDecklist()   // cold launch, or first visit after the intent ran
            }
            .onChange(of: inbox.pending) { _, _ in claimSharedDecklist() }
            .alert("Replace the decklist?", isPresented: Binding(
                get: { pendingReplacement != nil }, set: { if !$0 { pendingReplacement = nil } })
            ) {
                Button("Replace") {
                    let text = pendingReplacement
                    pendingReplacement = nil
                    if let text { apply(text) }
                }
                Button("Cancel", role: .cancel) { pendingReplacement = nil }
            } message: {
                Text("The box already has a list in it. Pasting will replace it.")
            }
        }
    }

    // MARK: -

    private func claimSharedDecklist() {
        guard let text = inbox.claim() else { return }
        accept(text)
    }

    /// Take a decklist that arrived from outside the editor — the paste button or the
    /// App Intent.
    ///
    /// Rejection comes before the replace prompt: asking "replace what you typed?" only
    /// to answer "…with something that isn't a decklist" wastes the user's decision.
    private func accept(_ text: String) {
        guard DecklistDetection.looksLikeDecklist(text) else {
            ingestNotice = "That doesn't look like a decklist — expected lines like “4 Iono PAL 185”."
            return
        }
        let existing = deckText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard existing.isEmpty || existing == text.trimmingCharacters(in: .whitespacesAndNewlines) else {
            pendingReplacement = text
            return
        }
        apply(text)
    }

    /// Run an accepted decklist. Pasting and checking are one step: separating them
    /// would put a tap back in the flow this whole feature exists to remove.
    private func apply(_ text: String) {
        ingestNotice = nil
        deckText = text
        hideKeyboard()

        // Without a catalog nothing can resolve, so hold the text rather than showing
        // an empty report that looks like the list was the problem.
        guard catalog.lookup != nil else {
            ingestNotice = "Pasted. Build your catalog snapshot to check it — see Settings → Status."
            return
        }
        checkedText = text
    }
}
