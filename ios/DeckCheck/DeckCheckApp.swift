import SwiftUI

// DeckCheck — the personal Pokémon TCG inventory app. Wires the tested
// engines (DeckCheckCore / DeckCheckSQLite) to the camera, the durable outbox,
// the read-cache, and the Google Sheet backend.

@main
struct DeckCheckApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Image decoding runs off the main actor, so it can't read UIScreen itself.
        CardImageLoader.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.catalog)
                .environmentObject(model.inventory)
                .environmentObject(model.outbox)
                .environmentObject(model.decks)
                .environmentObject(model.sheets)
                .environmentObject(model.browserGapCheck)
                .environmentObject(model.migrator)
                .task { await model.syncNow() } // flush + refresh on launch
        }
    }
}
