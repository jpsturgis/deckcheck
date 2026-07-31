import Foundation
import DeckCheckCore

/// Renders search results: owned first, count including 0, owned
/// printings expandable inline.
enum SearchFormatter {
    static func format(_ groups: [SearchResultGroup], query: String, lens: LegalityFormat?) -> String {
        guard !groups.isEmpty else { return "No cards match \"\(query)\"." }

        var lensNote = ""
        if let lens { lensNote = " · lens: \(lens.rawValue)" }
        var out = ["\"\(query)\" — \(groups.count) group(s)\(lensNote)", ""]

        for g in groups {
            let marker = g.ownedCount > 0 ? "●" : "○"       // owned vs catalog-only
            let name = g.name.padding(toLength: 30, withPad: " ", startingAt: 0)
            var head = "\(marker) \(name)  own \(g.ownedCount)  · \(g.printings.count) printing(s)"
            if let legal = g.formatLegal, let lens {
                head += legal ? "  · \(lens.rawValue)-legal" : "  · not \(lens.rawValue)-legal"
            }
            out.append(head)
            if !g.ownedPrintings.isEmpty {
                let owned = g.ownedPrintings
                    .map { "\(code($0.card)) \($0.card.number) ×\($0.qty)" }
                    .joined(separator: " · ")
                out.append("     owned: \(owned)")
            }
        }
        return out.joined(separator: "\n")
    }

    private static func code(_ c: CatalogCard) -> String { c.ptcgoCode ?? c.setName }
}
