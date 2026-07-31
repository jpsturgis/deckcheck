import SwiftUI
import UIKit
import DeckCheckCore

/// Renders a `GapReport` as Form sections — the gap-first buckets plus a TCGplayer
/// buy list you can copy or open pre-filled (spec §7.4). Shared by the Gap Check
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
