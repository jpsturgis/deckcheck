import SwiftUI

struct RootView: View {
    @EnvironmentObject var outbox: Outbox
    @StateObject private var inbox = DecklistInbox.shared

    /// Bound so a decklist arriving from the App Intent can route itself to Gap Check.
    /// Nothing else drives it — tapping a tab still works exactly as it did.
    @State private var selection: Tab = .scan

    enum Tab: Hashable { case scan, cards, decks, gapCheck, settings }

    var body: some View {
        TabView(selection: $selection) {
            ScanView()
                .tabItem { Label("Scan", systemImage: "camera") }
                .tag(Tab.scan)
            CardsView()
                .tabItem { Label("Cards", systemImage: "rectangle.stack") }
                .tag(Tab.cards)
            DecksView()
                .tabItem { Label("Decks", systemImage: "rectangle.on.rectangle.angled") }
                .tag(Tab.decks)
            GapCheckView()
                .tabItem { Label("Gap Check", systemImage: "checklist") }
                .tag(Tab.gapCheck)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .badge(outbox.count) // pending sync: N
                .tag(Tab.settings)
        }
        // Routing only — `GapCheckView` does the claiming. A tab the user has never
        // visited hasn't been built yet and so couldn't have observed anything;
        // switching to it here is what brings it into existence to collect the text.
        .onChange(of: inbox.pending) { _, pending in
            if pending != nil { selection = .gapCheck }
        }
        .onAppear {
            if inbox.pending != nil { selection = .gapCheck } // cold launch from the intent
        }
    }
}
