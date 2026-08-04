import Foundation

/// Per-deck settings, stored as a comment line inside the deck's own Sheet tab.
///
/// A deck tab is just pasted decklist text, and `DecklistParser` skips any line that
/// doesn't start with a quantity — so a `#built: no` line rides along in column A
/// without disturbing anything that reads the list. That makes the Sheet the source of
/// truth for these settings, keeps them hand-editable from a laptop, and means they
/// survive a reinstall, in keeping with the rest of the app's data.
///
/// Directives are `#<key>: <value>`, matched case-insensitively.
public enum DeckDirectives {
    /// Whether the deck is physically assembled. Only built decks reserve cards.
    public static let builtKey = "built"

    private static let truthy: Set<String> = ["yes", "y", "true", "1", "on", "built"]
    private static let falsey: Set<String> = ["no", "n", "false", "0", "off", "unbuilt"]

    /// Whether this deck's cards are sleeved and therefore unavailable for other decks.
    /// **Defaults to true** when the directive is absent, so every deck that existed
    /// before this feature keeps reserving exactly as it did.
    public static func isBuilt(_ decklist: String) -> Bool {
        guard let raw = value(of: builtKey, in: decklist) else { return true }
        if falsey.contains(raw) { return false }
        if truthy.contains(raw) { return true }
        return true   // unrecognized value: assume built rather than silently freeing cards
    }

    /// The line to write for a given state. Always explicit — someone opening the tab
    /// in a browser should be able to see the setting and flip it by hand.
    public static func builtLine(_ built: Bool) -> String {
        "#\(builtKey): \(built ? "yes" : "no")"
    }

    /// Zero-based index of the line carrying `key`, or nil. The app uses this to
    /// overwrite one cell rather than rewriting the whole tab.
    public static func lineIndex(of key: String, in lines: [String]) -> Int? {
        lines.firstIndex { parse($0)?.key == key.lowercased() }
    }

    /// `decklist` with the directive set — replacing the existing line in place, or
    /// appended if there isn't one. Used for the local copy; the Sheet write is a
    /// targeted single-cell update driven by `lineIndex(of:in:)`.
    public static func setting(_ key: String, to value: String, in decklist: String) -> String {
        var lines = decklist.components(separatedBy: "\n")
        let line = "#\(key): \(value)"
        if let i = lineIndex(of: key, in: lines) {
            lines[i] = line
        } else {
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// `decklist` with the built directive set.
    public static func settingBuilt(_ built: Bool, in decklist: String) -> String {
        setting(builtKey, to: built ? "yes" : "no", in: decklist)
    }

    // MARK: -

    /// The lowercased value for `key`, or nil when the directive isn't present.
    private static func value(of key: String, in decklist: String) -> String? {
        for raw in decklist.split(separator: "\n", omittingEmptySubsequences: false) {
            if let d = parse(String(raw)), d.key == key.lowercased() { return d.value }
        }
        return nil
    }

    /// "#built: no" → (key: "built", value: "no"). Tolerant of spacing and case, and of
    /// the `#` being written as `//` — both read as comments in a pasted list.
    private static func parse(_ line: String) -> (key: String, value: String)? {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("//") { t = String(t.dropFirst(2)) }
        else if t.hasPrefix("#") { t = String(t.dropFirst()) }
        else { return nil }

        guard let colon = t.firstIndex(of: ":") else { return nil }
        let key = t[t.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        let value = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return nil }
        return (key, value)
    }
}
