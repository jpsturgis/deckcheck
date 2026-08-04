import SwiftUI
import UIKit
import DeckCheckCore

/// Renders a `GapReport` as Form sections — the gap-first buckets plus a TCGplayer
/// buy list you can copy or open pre-filled. Shared by the Gap Check
/// scratchpad (paste a list) and the per-deck view (a saved `Deck:` tab).
struct GapReportSections: View {
    let report: GapReport
    @State private var copied = false

    var body: some View {
        Group {
            Section("Result") {
                Text("Buildable \(report.buildableQty)/\(report.deckTotal) · short \(report.shortTotal)")
                    .font(.headline)
                bucket("❌ Missing", report.missing, buyLink: true)
                bucket("⚠️ Short", report.short, buyLink: true)
                differentWordingBucket
                bucket("✅ Have", report.have)
                if report.basicEnergyQty > 0 {
                    Text("🔋 Basic Energy: \(report.basicEnergyQty) (auto-satisfied)").font(.footnote)
                }
                if !report.unidentified.isEmpty {
                    Text("❓ Couldn’t identify (\(report.unidentified.count))")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
            buyListSection
        }
    }

    @ViewBuilder private var buyListSection: some View {
        let buy = TCGplayerExport.massEntry(report)
        Section("TCGplayer buy list") {
            if buy.isEmpty {
                Text("Nothing to buy — deck is buildable.").font(.footnote).foregroundStyle(.secondary)
            } else {
                Text(buy)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                Button {
                    UIPasteboard.general.string = buy
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied!" : "Copy list",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            }
        }
    }

    /// Cards the deck lists under an older wording that you own a reprint of. Counted
    /// toward the build — the game plays every printing with the most recent text — but
    /// shown on their own, because the wording genuinely differs and that's your call
    /// to make, not the app's.
    @ViewBuilder private var differentWordingBucket: some View {
        let entries = report.differentWording
        if !entries.isEmpty {
            Text("📝 Different wording — likely the same card")
                .font(.footnote.weight(.semibold))
            ForEach(entries, id: \.equivalenceKey) { e in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("\(e.requiredQty)× \(e.name)").font(.footnote)
                        Spacer()
                        Text("own \(e.effectiveOwnedQty)").font(.caption2).foregroundStyle(.secondary)
                        if e.shortQty > 0, let url = TCGplayerExport.searchURL(cardName: e.name) {
                            Link(destination: url) { Image(systemName: "cart").font(.caption2) }
                        }
                    }
                    Text(wordingDetail(e)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text("Reprints are sometimes reworded. These are the same card in play, so they’re counted and left off the buy list.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    /// "deck lists AOR 99 · you own SVI 171, CRZ 127" — so it's obvious which copies
    /// are being counted and why they didn't match exactly.
    private func wordingDetail(_ e: GapEntry) -> String {
        func designation(_ c: CatalogCard) -> String {
            "\(c.ptcgoCode ?? c.setName) \(c.number)"
        }
        let shown = e.errataPrintings.prefix(3).map(designation).joined(separator: ", ")
        var s = "deck lists \(designation(e.representative)) · you own \(shown)"
        if e.errataPrintings.count > 3 { s += ", +\(e.errataPrintings.count - 3) more" }
        if e.ownedQty > 0 { s += " (plus \(e.ownedQty) exact)" }
        if e.shortQty > 0 { s += " — still short \(e.shortQty)" }
        return s
    }

    @ViewBuilder private func bucket(_ title: String, _ entries: [GapEntry], buyLink: Bool = false) -> some View {
        if !entries.isEmpty {
            Text(title).font(.footnote.weight(.semibold))
            ForEach(entries, id: \.equivalenceKey) { e in
                HStack(spacing: 6) {
                    Text("\(e.requiredQty)× \(e.name)").font(.footnote)
                    if e.differentPrinting { Text("🔁").font(.caption2) }
                    Spacer()
                    Text("own \(e.ownedQty)").font(.caption2).foregroundStyle(.secondary)
                    if buyLink, let url = TCGplayerExport.searchURL(cardName: e.name) {
                        Link(destination: url) { Image(systemName: "cart").font(.caption2) }
                    }
                }
            }
        }
    }
}
