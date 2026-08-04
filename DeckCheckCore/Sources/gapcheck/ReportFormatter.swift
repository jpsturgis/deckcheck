import Foundation
import DeckCheckCore

/// Renders a GapReport as a gap-first terminal report.
enum ReportFormatter {
    static func format(_ r: GapReport, showBuylist: Bool) -> String {
        var out: [String] = []

        var headline = "Deck — buildable \(r.buildableQty)/\(r.deckTotal) · short \(r.shortTotal)"
        if !r.unidentified.isEmpty { headline += " · \(r.unidentified.count) unidentified" }
        if let lens = r.legalityLens { headline += " · lens: \(lens.rawValue)" }
        out.append(headline)
        out.append("")

        if !r.missing.isEmpty {
            out.append("❌ MISSING")
            for e in r.missing { out.append("   " + line(e)) }
        }
        if !r.short.isEmpty {
            out.append("⚠️  SHORT")
            for e in r.short { out.append("   " + line(e)) }
        }
        if !r.differentWording.isEmpty {
            out.append("📝 DIFFERENT WORDING — likely the same card (counted, not on the buy list)")
            for e in r.differentWording {
                out.append("   " + line(e))
                out.append("        " + wordingDetail(e))
            }
        }
        if !r.have.isEmpty {
            out.append("✅ HAVE (\(r.have.count))")
            for e in r.have { out.append("   " + line(e)) }
        }
        if r.basicEnergyQty > 0 {
            out.append("🔋 Basic Energy: \(r.basicEnergyQty) (auto-satisfied)")
        }
        if !r.unidentified.isEmpty {
            out.append("❓ COULDN'T IDENTIFY (\(r.unidentified.count)) — excluded from buildable")
            for u in r.unidentified { out.append("   \(u.quantity) \(u.name)  [\(u.raw)]") }
        }
        let noLegal = r.entries.filter { $0.ownedNoLegalPrinting }
        if !noLegal.isEmpty, let lens = r.legalityLens {
            out.append("🏷️  OWNED — no \(lens.rawValue.capitalized)-legal printing")
            for e in noLegal { out.append("   \(e.name)") }
        }

        if showBuylist {
            out.append("")
            out.append("── TCGplayer Mass Entry (shortfall) ──")
            let buy = TCGplayerExport.massEntry(r)
            out.append(buy.isEmpty ? "(nothing to buy — deck is buildable)" : buy)
        }

        return out.joined(separator: "\n")
    }

    /// Which printings the errata bridge counted, and which one the deck asked for.
    private static func wordingDetail(_ e: GapEntry) -> String {
        func designation(_ c: CatalogCard) -> String { "\(c.ptcgoCode ?? c.setName) \(c.number)" }
        let shown = e.errataPrintings.prefix(3).map(designation).joined(separator: ", ")
        var s = "deck lists \(designation(e.representative)) · you own \(shown)"
        if e.errataPrintings.count > 3 { s += ", +\(e.errataPrintings.count - 3) more" }
        if e.ownedQty > 0 { s += " (plus \(e.ownedQty) exact)" }
        return s
    }

    private static func line(_ e: GapEntry) -> String {
        let qty = "\(e.requiredQty)×"
        let name = e.name.padding(toLength: 34, withPad: " ", startingAt: 0)
        var tail = "own \(e.effectiveOwnedQty) / need \(e.requiredQty)"
        if e.shortQty > 0 { tail += "  → short \(e.shortQty)" }
        var flags: [String] = []
        if e.differentPrinting { flags.append("🔁 diff printing") }
        if e.ownedNoLegalPrinting { flags.append("🏷️ not format-legal") }
        let flagStr = flags.isEmpty ? "" : "   " + flags.joined(separator: " · ")
        return "\(qty.padding(toLength: 4, withPad: " ", startingAt: 0)) \(name) \(tail)\(flagStr)"
    }
}
