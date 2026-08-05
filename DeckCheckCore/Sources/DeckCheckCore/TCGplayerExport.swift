import Foundation

/// Turn a gap report into a TCGplayer **Mass Entry** buy list: the
/// shortfall only. Cards satisfied by a functional different printing are already
/// owned, so they're `.have` and excluded — as are copies the errata bridge matched to
/// a differently-worded printing you own, which is the same card in play.
///
/// Line format is `<qty> <name> [<SETCODE>] <number>/<printedTotal>` — the form Mass
/// Entry accepts for Pokémon (e.g. `1 Ralts [MEG] 058/132`): the set code is bracketed,
/// and the collector number is **zero-padded to the printed total's width** with the
/// total appended. (Our catalog stores numbers without leading zeros, so we re-pad
/// here.) A printing with no code / total falls back to a looser form.
public enum TCGplayerExport {
    /// Newline-joined Mass Entry lines — paste into TCGplayer Mass Entry.
    ///
    /// One rule: every entry still short, at its shortfall. `entries` is already sorted
    /// missing → short → have, so the list stays gap-first. (A missing entry owns
    /// nothing, so its shortfall *is* the required quantity.)
    public static func massEntry(_ report: GapReport) -> String {
        massEntry(report.entries
            .filter { $0.shortQty > 0 }
            .map { (quantity: $0.shortQty, card: $0.representative) })
    }

    /// Mass Entry lines for an arbitrary want list, in the order given.
    ///
    /// The gap report isn't the only thing that produces one — set completion has a
    /// shortfall too ("the 49 cards I still need from Surging Sparks"), and it's the
    /// same buy list in the same format. Keeping the line formatting in one place is
    /// the point: the zero-padding rules below are fiddly and easy to re-derive wrong.
    public static func massEntry(_ lines: [(quantity: Int, card: CatalogCard)]) -> String {
        lines
            .filter { $0.quantity > 0 }
            .map { entryLine($0.quantity, $0.card) }
            .joined(separator: "\n")
    }

    /// A link to TCGplayer search for a card. Passing the set name and collector
    /// number narrows the query to the *specific* printing (e.g. `Charizard ex
    /// Obsidian Flames 125`) instead of every printing that shares the name — TCGplayer
    /// has no stable set-code+number deep link, so a narrowed search is the closest we
    /// can get.
    public static func searchURL(cardName: String, setName: String? = nil, number: String? = nil) -> URL? {
        let terms = [cardName, setName, number]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        var comps = URLComponents(string: "https://www.tcgplayer.com/search/pokemon/product")
        comps?.queryItems = [
            URLQueryItem(name: "productLineName", value: "pokemon"),
            URLQueryItem(name: "q", value: terms.joined(separator: " ")),
        ]
        return comps?.url
    }

    // MARK: -

    private static func entryLine(_ qty: Int, _ card: CatalogCard) -> String {
        guard let code = card.ptcgoCode, !code.isEmpty else {
            return "\(qty) \(card.name)"
        }
        return "\(qty) \(card.name) [\(code)] \(numberField(card))"
    }

    /// `058/132` — zero-pad a purely-numeric collector number to the printed total's
    /// width and append the total. Non-numeric numbers (TG/GG galleries) or a missing
    /// total pass through unchanged.
    private static func numberField(_ card: CatalogCard) -> String {
        guard let total = card.printedTotal, card.number.allSatisfy(\.isNumber) else {
            return card.number
        }
        let width = max(String(total).count, card.number.count)
        let padded = String(repeating: "0", count: width - card.number.count) + card.number
        return "\(padded)/\(total)"
    }
}
