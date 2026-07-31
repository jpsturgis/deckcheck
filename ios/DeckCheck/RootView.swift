import SwiftUI

struct RootView: View {
    @EnvironmentObject var outbox: Outbox

    var body: some View {
        TabView {
            ScanView()
                .tabItem { Label("Scan", systemImage: "camera") }
            CardsView()
                .tabItem { Label("Cards", systemImage: "rectangle.stack") }
            DecksView()
                .tabItem { Label("Decks", systemImage: "rectangle.on.rectangle.angled") }
            GapCheckView()
                .tabItem { Label("Gap Check", systemImage: "checklist") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .badge(outbox.count) // pending sync: N (§5.4)
        }
    }
}
