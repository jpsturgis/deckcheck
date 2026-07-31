import Foundation

/// Resolves one parsed decklist line to a functional-equivalence group (spec §7.4
/// "resolve"), reusing the same catalog the recognizer and search use so a decklist
/// target and the inventory land in the same group.
///
/// Order: basic energy (auto-satisfy) → set-code + number → name + number →
/// unidentified. Unidentified lines are **never silently dropped** — they're
/// bucketed for manual attention and excluded from the buildable count.
public enum LineResolver {
    public static func resolve(_ line: ParsedLine, catalog: CatalogLookup) -> ResolvedLine {
        if let energy = BasicEnergy.match(line.name) {
            return ResolvedLine(parsed: line, resolution: .basicEnergy(name: energy))
        }

        if let number = line.number {
            // set code + number (the primary path)
            if let code = line.setCode,
               let card = uniqueByKey(catalog.cards(setCode: code, number: number)) {
                return ResolvedLine(parsed: line, resolution: .resolved(card))
            }
            // fall back to name + number (code unreadable / variant)
            let wanted = Normalize.name(line.name)
            let byNumber = catalog.cards(number: number).filter { Normalize.name($0.name) == wanted }
            if let card = uniqueByKey(byNumber) {
                return ResolvedLine(parsed: line, resolution: .resolved(card))
            }
        }

        return ResolvedLine(
            parsed: line,
            resolution: .unidentified(reason: "no unique printing for \"\(line.raw)\"")
        )
    }

    /// Collapse candidate printings to one *iff* they share a single equivalence
    /// key — for a gap-check, differing printings that hash the same are one answer,
    /// but candidates spanning several keys are genuinely ambiguous.
    static func uniqueByKey(_ cards: [CatalogCard]) -> CatalogCard? {
        guard !cards.isEmpty else { return nil }
        return Set(cards.map { $0.equivalenceKey }).count == 1 ? cards[0] : nil
    }
}
