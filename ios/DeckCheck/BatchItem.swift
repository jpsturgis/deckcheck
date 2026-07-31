import UIKit
import DeckCheckCore

/// One captured card awaiting batch review: the photo, what the
/// recognizer resolved, and the printing currently chosen for it (the resolver's
/// best guess by default, overridable via the correction picker). `chosen == nil`
/// means it still needs identifying — those float to the top of the review list.
struct BatchItem: Identifiable {
    let id = UUID()
    let image: UIImage
    var resolution: PrintingResolution
    var chosen: CatalogCard?
    /// Copies to commit for this card — scan one, dial it up to how many
    /// you actually have. Committing enqueues this many ops.
    var qty: Int = 1

    init(image: UIImage, resolution: PrintingResolution) {
        self.image = image
        self.resolution = resolution
        self.chosen = resolution.best
    }

    var identified: Bool { chosen != nil }
}
