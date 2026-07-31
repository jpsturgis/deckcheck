import UIKit

/// Crops a full-frame camera photo down to the on-screen framing guide, so Vision
/// only sees the card the user lined up — not neighboring cards elsewhere in the shot
/// — and the batch thumbnail is tight to the card.
///
/// The preview uses aspect-fill (fills the screen, cropping the photo's overflow), so
/// the guide's screen fractions don't map 1:1 to the photo. This reverses that mapping
/// from the photo's aspect vs the preview's aspect. Errs slightly generous (a little
/// padding) so a small miscalibration can't clip the collector number at the card's
/// bottom edge. Camera geometry — verify/tune on device.
enum CardFrameCrop {
    /// Guide width as a fraction of the preview width. Shared with the drawn guide so
    /// the two can't drift.
    static let guideWidthFraction: CGFloat = 0.82
    /// Card aspect (short side / long side), ~63×88mm.
    static let cardAspect: CGFloat = 63.0 / 88.0
    /// Squares the *drawn* guide up by this factor (1.0 = true card aspect). At true
    /// aspect the tall box ran off the top of the frame; 0.9 read too square. This is
    /// the midpoint — a touch shorter than a real card, still clearly portrait. Only
    /// affects the on-screen guide — the crop below stays at true card aspect so the
    /// bottom collector number is never clipped (the box just sits a hair inside the
    /// captured card). Tune on device.
    static let guideHeightScale: CGFloat = 0.95

    /// Drawn-guide height for a given width — the on-screen box (a touch squared up).
    static func guideHeight(forWidth w: CGFloat) -> CGFloat { w / cardAspect * guideHeightScale }
    /// Crop tightness relative to the guide (1.0 = exactly the guide). Slightly under
    /// 1 crops inside the guide; over 1 leaves a margin. Tune on device.
    static let padding: CGFloat = 1.0

    static func crop(_ image: UIImage, previewSize: CGSize) -> UIImage {
        guard previewSize.width > 0, previewSize.height > 0,
              let cg = image.cgImageOriented() else { return image }

        let wp = CGFloat(cg.width), hp = CGFloat(cg.height)
        let photoAspect = wp / hp
        let screenAspect = previewSize.width / previewSize.height

        // Guide as fractions of the on-screen preview.
        let guideWFrac = guideWidthFraction
        let guideHFrac = (guideWidthFraction * previewSize.width / cardAspect) / previewSize.height

        var wFrac: CGFloat
        var hFrac: CGFloat
        if photoAspect >= screenAspect {
            // Aspect-fill fills height, crops width → only screen/photo of the width is visible.
            wFrac = guideWFrac * (screenAspect / photoAspect)
            hFrac = guideHFrac
        } else {
            // Fills width, crops height.
            wFrac = guideWFrac
            hFrac = guideHFrac * (photoAspect / screenAspect)
        }
        wFrac = min(wFrac * padding, 1)
        hFrac = min(hFrac * padding, 1)

        let rect = CGRect(x: (1 - wFrac) / 2 * wp,
                          y: (1 - hFrac) / 2 * hp,
                          width: wFrac * wp,
                          height: hFrac * hp).integral
        let clamped = rect.intersection(CGRect(x: 0, y: 0, width: wp, height: hp))
        guard !clamped.isNull, clamped.width > 1, clamped.height > 1,
              let cropped = cg.cropping(to: clamped) else { return image }
        return UIImage(cgImage: cropped)
    }
}
