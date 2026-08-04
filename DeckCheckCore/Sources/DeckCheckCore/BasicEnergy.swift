import Foundation

/// Basic energy is never tracked: decklist basic-energy lines
/// auto-satisfy. This detects them by name so they never need a catalog match
/// (TCG Live writes them as e.g. "Basic Fire Energy SVI 230", but the set/number
/// is irrelevant — any basic Fire is interchangeable).
public enum BasicEnergy {
    static let types = [
        "grass", "fire", "water", "lightning", "psychic",
        "fighting", "darkness", "metal", "fairy", "dragon", "colorless",
    ]

    /// TCG Live also exports basic energy with the *type symbol* in place of the type
    /// name — "5 Basic {R} Energy MEE 2" rather than "5 Basic Fire Energy MEE 2".
    /// Same token alphabet the catalog builder canonicalizes energy costs to
    /// (tools/build-catalog/src/resolve.ts, `ENERGY_TOKEN`); keep the two in step.
    static let symbolTypes: [Character: String] = [
        "g": "grass", "r": "fire", "w": "water", "l": "lightning", "p": "psychic",
        "f": "fighting", "d": "darkness", "m": "metal", "y": "fairy", "n": "dragon",
        "c": "colorless",
    ]

    /// Returns the canonical "<Type> Energy" label if `rawName` is a basic energy
    /// line, else nil. Handles the optional "Basic " prefix and the symbol form.
    public static func match(_ rawName: String) -> String? {
        var n = Normalize.name(rawName)
        let prefix = "basic "
        if n.hasPrefix(prefix) { n = String(n.dropFirst(prefix.count)) }
        guard let type = energyType(n) else { return nil }
        return "\(type.prefix(1).uppercased())\(type.dropFirst()) Energy"
    }

    /// "<type> energy" or "<symbol> energy" → the lowercase type. The trailing
    /// " energy" is required, so "Double Colorless Energy" and "Reversal Energy"
    /// (special energy, which *is* tracked) don't match.
    private static func energyType(_ normalized: String) -> String? {
        let suffix = " energy"
        guard normalized.hasSuffix(suffix) else { return nil }
        let head = String(normalized.dropLast(suffix.count))
        if types.contains(head) { return head }
        return symbolType(head)
    }

    /// "{r}" or "[r]" → "fire". Both bracket styles appear in the wild.
    private static func symbolType(_ head: String) -> String? {
        guard head.count == 3,
              let open = head.first, let close = head.last,
              (open == "{" && close == "}") || (open == "[" && close == "]")
        else { return nil }
        return symbolTypes[head[head.index(after: head.startIndex)]]
    }
}
