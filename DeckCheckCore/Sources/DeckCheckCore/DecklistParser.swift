import Foundation

/// Tolerant decklist parser. Keyed on the `<qty> <Name> <SETCODE> <Number>`
/// line shape used by Pokémon TCG Live "copy list" and Limitless exports. Section
/// headers ("Pokémon: 6", "Total Cards: 60") are hints, not required — any line that
/// doesn't start with a quantity is skipped.
public enum DecklistParser {
    public static func parse(_ text: String) -> [ParsedLine] {
        var out: [ParsedLine] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let parsed = parseLine(line) { out.append(parsed) }
        }
        return out
    }

    static func parseLine(_ line: String) -> ParsedLine? {
        var tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.count >= 2, let qty = quantity(tokens[0]) else { return nil }
        tokens.removeFirst()

        // Peel a trailing "<SETCODE> <Number>" pair if present; otherwise the whole
        // remainder is the card name (basic energy / name-only lines).
        var setCode: String?
        var number: String?
        if tokens.count >= 2,
           looksLikeNumber(tokens[tokens.count - 1]),
           looksLikeSetCode(tokens[tokens.count - 2]) {
            number = tokens.removeLast()
            setCode = tokens.removeLast()
        }

        let name = tokens.joined(separator: " ")
        guard !name.isEmpty else { return nil }
        return ParsedLine(quantity: qty, name: name, setCode: setCode, number: number, raw: line)
    }

    /// Leading quantity token: "4", "4x", "4X".
    static func quantity(_ token: String) -> Int? {
        var t = token
        if let last = t.last, last == "x" || last == "X" { t.removeLast() }
        return Int(t)
    }

    /// A set code: 2–5 chars, uppercase letters with an optional trailing digit
    /// (OBF, SVI, PAL, SV8, SWSH, SVP).
    static func looksLikeSetCode(_ t: String) -> Bool {
        guard (2...5).contains(t.count) else { return false }
        var letters = 0
        for ch in t {
            if ch.isLetter && ch.isUppercase { letters += 1 }
            else if ch.isNumber { continue }
            else { return false }
        }
        return letters >= 2
    }

    /// A collector number: has a digit, alphanumeric only, ≤5 chars — covers "125",
    /// "057", secret rares ("199"), and alnum galleries ("TG12", "GG01").
    static func looksLikeNumber(_ t: String) -> Bool {
        guard (1...5).contains(t.count) else { return false }
        var hasDigit = false
        for ch in t {
            if ch.isNumber { hasDigit = true }
            else if ch.isLetter { continue }
            else { return false }
        }
        return hasDigit
    }
}
