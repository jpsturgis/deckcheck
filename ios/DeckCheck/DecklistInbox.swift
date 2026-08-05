import Foundation
import Combine

/// Where a decklist arrives from outside the app — the `Gap Check Decklist` App
/// Intent, run from Shortcuts, the share sheet, Spotlight, or Siri.
///
/// An `AppIntent` is instantiated by the system, not by the view tree, so it can't be
/// handed the `AppModel` the way a view can. A tiny singleton mailbox is the seam: the
/// intent drops text in, `RootView` routes to the Gap Check tab, and `GapCheckView`
/// takes it out. Nothing else knows the intent exists.
///
/// Delivery has to survive a cold launch. When the intent starts the app, `perform()`
/// runs before the tab that consumes it has ever been built — which is why the value
/// stays here until someone claims it, rather than being posted as a notification that
/// a not-yet-existing observer would miss.
@MainActor
final class DecklistInbox: ObservableObject {
    static let shared = DecklistInbox()

    /// Text waiting to be gap-checked. Cleared by whoever consumes it.
    @Published private(set) var pending: String?

    private init() {}

    func deliver(_ decklist: String) { pending = decklist }

    /// Take the pending decklist, if any, leaving the mailbox empty. Consuming rather
    /// than reading is what keeps a backgrounded-then-foregrounded app from
    /// re-checking the same list.
    func claim() -> String? {
        defer { pending = nil }
        return pending
    }
}
