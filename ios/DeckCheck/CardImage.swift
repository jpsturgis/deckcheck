import SwiftUI

/// A card image that renders instantly when it's been seen before.
///
/// The whole point is the synchronous cache read in `init`: if `CardImageLoader` already
/// holds a decoded image at this size, `phase` starts as `.loaded` and the very first
/// frame draws the art. `AsyncImage` can't do this — it always begins empty and hops
/// through an async load, which is what produced a placeholder flash on every scroll.
struct CardImage<Placeholder: View>: View {
    private let url: URL?
    private let size: CGSize
    private let cornerRadius: CGFloat
    private let placeholder: Placeholder

    @State private var image: UIImage?
    @State private var didAttempt: Bool

    init(url: URL?, width: CGFloat, height: CGFloat, cornerRadius: CGFloat = 4,
         @ViewBuilder placeholder: () -> Placeholder) {
        self.url = url
        self.size = CGSize(width: width, height: height)
        self.cornerRadius = cornerRadius
        self.placeholder = placeholder()

        let hit = url.flatMap { CardImageLoader.cached($0, size: CGSize(width: width, height: height)) }
        _image = State(initialValue: hit)
        _didAttempt = State(initialValue: hit != nil)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                placeholder
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: url) {
            guard let url, image == nil, !didAttempt else { return }
            didAttempt = true
            let loaded = await CardImageLoader.shared.image(for: url, size: size)
            // A cancelled row (scrolled away) shouldn't publish; the bytes stay cached
            // for whoever asks next.
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { image = loaded }
        }
    }
}

extension CardImage where Placeholder == AnyView {
    /// The standard grey card-shaped placeholder used across the lists.
    init(url: URL?, width: CGFloat, height: CGFloat, cornerRadius: CGFloat = 4) {
        self.init(url: url, width: width, height: height, cornerRadius: cornerRadius) {
            AnyView(RoundedRectangle(cornerRadius: cornerRadius).fill(.quaternary))
        }
    }
}

/// Convenience for the string URLs the catalog stores.
extension CardImage where Placeholder == AnyView {
    init(urlString: String?, width: CGFloat, height: CGFloat, cornerRadius: CGFloat = 4) {
        self.init(url: urlString.flatMap(URL.init(string:)),
                  width: width, height: height, cornerRadius: cornerRadius)
    }
}

/// The sizes card art is drawn at. Named in one place because the decoded-image cache
/// is keyed by size — the detail view can only reuse a list's thumbnail as its blur-up
/// placeholder if it asks for the same dimensions the list did.
enum CardArtSize {
    static let listThumb = CGSize(width: 40, height: 56)
    static let printingThumb = CGSize(width: 34, height: 47)
    static let pickerThumb = CGSize(width: 72, height: 100)
    static let hero = CGSize(width: 320, height: 440)
}

extension CardImage where Placeholder == AnyView {
    init(urlString: String?, size: CGSize, cornerRadius: CGFloat = 4) {
        self.init(urlString: urlString, width: size.width, height: size.height,
                  cornerRadius: cornerRadius)
    }
}

/// Warm images for rows that are about to appear. Card art is ~11 KB and immutable, so
/// requesting a few rows early costs almost nothing and removes the visible load.
enum CardImagePrefetch {
    static func warm(_ urlStrings: [String?], size: CGSize) {
        let urls = urlStrings.compactMap { $0 }.compactMap(URL.init(string:))
        guard !urls.isEmpty else { return }
        Task { await CardImageLoader.shared.prefetch(urls, size: size) }
    }
}
