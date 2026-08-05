import Foundation

/// Editing a decklist **as text**, one line at a time.
///
/// A deck lives in a Sheet tab the user can open in a browser and edit by hand. That
/// makes the text — not some parsed model — the source of truth, and it means an edit
/// has to be surgical: touch the line it means to touch and leave every other byte
/// alone. Section headers, blank lines, `#built:` directives, a stray note someone
/// typed in row 40 — all of it has to survive a quantity change.
///
/// So every operation here takes text and returns text, and the line index is the
/// address. `entries` hands out those addresses alongside the parse.
public enum DeckEditor {

    /// A card line, with its address in the original text.
    public struct Entry: Equatable, Identifiable {
        /// Zero-based index into the text's lines — the address for the mutators below.
        public let lineIndex: Int
        public let parsed: ParsedLine

        public var id: Int { lineIndex }
        public var quantity: Int { parsed.quantity }
        public var name: String { parsed.name }

        public init(lineIndex: Int, parsed: ParsedLine) {
            self.lineIndex = lineIndex; self.parsed = parsed
        }
    }

    /// Every card line in `decklist`, in order, addressed by line index.
    ///
    /// Non-card lines — headers, comments, directives, blanks — are skipped here but
    /// stay in the text; the indices are gappy on purpose so the mutators can address
    /// the original.
    public static func entries(_ decklist: String) -> [Entry] {
        lines(decklist).enumerated().compactMap { index, raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let parsed = DecklistParser.parseLine(trimmed) else { return nil }
            return Entry(lineIndex: index, parsed: parsed)
        }
    }

    /// Set a line's quantity, rewriting **only** the leading quantity token.
    ///
    /// The rest of the line is copied through byte for byte, so "4 Iono PAL 185  # my
    /// last copy" keeps its comment and its double space. A quantity of zero or less
    /// removes the line — that's what a stepper hitting 0 means.
    public static func setQuantity(_ quantity: Int, atLine index: Int, in decklist: String) -> String {
        guard quantity > 0 else { return remove(atLine: index, in: decklist) }
        var all = lines(decklist)
        guard all.indices.contains(index) else { return decklist }

        let original = all[index]
        // Preserve leading whitespace, then swap just the first token.
        let leading = original.prefix { $0 == " " || $0 == "\t" }
        let body = original.dropFirst(leading.count)
        guard let firstSpace = body.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            return decklist   // no separator → not a card line shape; refuse rather than mangle
        }
        all[index] = leading + "\(quantity)" + body[firstSpace...]
        return all.joined(separator: "\n")
    }

    /// Delete a line outright.
    public static func remove(atLine index: Int, in decklist: String) -> String {
        var all = lines(decklist)
        guard all.indices.contains(index) else { return decklist }
        all.remove(at: index)
        return all.joined(separator: "\n")
    }

    /// Add `quantity` copies of `card`.
    ///
    /// If the card is already on the list, this **adds to that line** rather than
    /// writing a second one — two lines naming the same printing is a thing TCG Live
    /// won't import and a person wouldn't write. Otherwise the new line is inserted
    /// after the last card line of the same supertype, so a Trainer lands among the
    /// Trainers instead of at the bottom of the file. With no cards of that supertype
    /// yet, it goes after the last card line; with no card lines at all, at the end.
    public static func add(_ card: CatalogCard, quantity: Int,
                           to decklist: String, catalog: any CatalogLookup) -> String {
        guard quantity > 0 else { return decklist }

        let existing = entries(decklist).first { entry in
            guard case let .resolved(c) = LineResolver.resolve(entry.parsed, catalog: catalog).resolution
            else { return false }
            return c.cardId == card.cardId
        }
        if let existing {
            return setQuantity(existing.quantity + quantity, atLine: existing.lineIndex, in: decklist)
        }

        var all = lines(decklist)
        let newLine = line(for: card, quantity: quantity)
        guard let insertAfter = insertionPoint(for: card, in: decklist, catalog: catalog) else {
            all.append(newLine)
            return all.joined(separator: "\n")
        }
        all.insert(newLine, at: insertAfter + 1)
        return all.joined(separator: "\n")
    }

    /// One decklist line for a printing: `<qty> <Name> <CODE> <number>`, degrading to
    /// name-only when the catalog has no TCG Live code for the set.
    public static func line(for card: CatalogCard, quantity: Int) -> String {
        guard let code = card.ptcgoCode, !code.isEmpty else { return "\(quantity) \(card.name)" }
        return "\(quantity) \(card.name) \(code) \(card.number)"
    }

    // MARK: -

    /// The line index to insert after: the last card line sharing `card`'s supertype,
    /// else the last card line, else nil for "there are no card lines".
    private static func insertionPoint(for card: CatalogCard, in decklist: String,
                                       catalog: any CatalogLookup) -> Int? {
        var lastOfKind: Int?
        var lastAny: Int?
        for entry in entries(decklist) {
            lastAny = entry.lineIndex
            if supertype(of: entry, catalog: catalog) == card.supertype { lastOfKind = entry.lineIndex }
        }
        return lastOfKind ?? lastAny
    }

    private static func supertype(of entry: Entry, catalog: any CatalogLookup) -> Supertype? {
        switch LineResolver.resolve(entry.parsed, catalog: catalog).resolution {
        case let .resolved(card): return card.supertype
        case .basicEnergy:        return .energy
        case .unidentified:       return nil
        }
    }

    /// Split preserving empty lines — they're part of the user's formatting, and
    /// dropping them would reflow a hand-laid-out tab on the first quantity tap.
    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }
}
