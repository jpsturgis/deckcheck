import Foundation

/// Render a decklist as **TCG Live import text**.
///
/// The inverse of `DecklistParser`, and the reason it's needed: a deck tab is
/// hand-editable, so by the time you want to take a list back out of DeckCheck it may
/// carry `#built:` directives, notes, stale section headers, blank rows, and cards in
/// whatever order they were typed. Pasting that into TCG Live is at best untidy and at
/// worst rejected.
///
/// This produces the canonical shape instead: three sections in play order, counted
/// headers, a total, nothing else.
public enum DecklistFormatter {

    /// TCG Live import text for `decklist`.
    ///
    /// Basic energy keeps whatever set/number the source line had — any basic Fire is
    /// any other, so there's nothing to normalize and rewriting it would only risk
    /// naming a printing the user doesn't have. Lines that don't resolve are passed
    /// through **verbatim into their best-guess section** rather than dropped: silently
    /// losing a card from an exported list is the worst possible failure here.
    public static func tcgLive(decklist: String, catalog: any CatalogLookup) -> String {
        let resolved = DecklistParser.parse(decklist).map { LineResolver.resolve($0, catalog: catalog) }

        var pokemon: [(qty: Int, text: String)] = []
        var trainer: [(qty: Int, text: String)] = []
        var energy: [(qty: Int, text: String)] = []
        var unplaced: [(qty: Int, text: String)] = []

        for line in resolved {
            switch line.resolution {
            case let .resolved(card):
                let text = DeckEditor.line(for: card, quantity: line.quantity)
                switch card.supertype {
                case .pokemon:  pokemon.append((line.quantity, text))
                case .trainer:  trainer.append((line.quantity, text))
                case .energy:   energy.append((line.quantity, text))
                case .unknown:  unplaced.append((line.quantity, line.parsed.raw))
                }
            case .basicEnergy:
                energy.append((line.quantity, line.parsed.raw))
            case .unidentified:
                unplaced.append((line.quantity, line.parsed.raw))
            }
        }

        var out: [String] = []
        appendSection("Pokémon", pokemon, to: &out)
        appendSection("Trainer", trainer, to: &out)
        appendSection("Energy", energy, to: &out)
        appendSection("Other", unplaced, to: &out)

        let total = (pokemon + trainer + energy + unplaced).reduce(0) { $0 + $1.qty }
        out.append("Total Cards: \(total)")
        return out.joined(separator: "\n")
    }

    private static func appendSection(_ title: String,
                                      _ rows: [(qty: Int, text: String)],
                                      to out: inout [String]) {
        guard !rows.isEmpty else { return }   // an empty section header helps nobody
        out.append("\(title): \(rows.reduce(0) { $0 + $1.qty })")
        out.append(contentsOf: rows.map(\.text))
        out.append("")
    }
}
