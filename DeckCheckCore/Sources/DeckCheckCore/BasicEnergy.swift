import Foundation

/// Basic energy is never tracked (spec §4.5): decklist basic-energy lines
/// auto-satisfy. This detects them by name so they never need a catalog match
/// (TCG Live writes them as e.g. "Basic Fire Energy SVI 230", but the set/number
/// is irrelevant — any basic Fire is interchangeable).
public enum BasicEnergy {
    static let types = [
        "grass", "fire", "water", "lightning", "psychic",
        "fighting", "darkness", "metal", "fairy", "dragon", "colorless",
    ]

    /// Returns the canonical "<Type> Energy" label if `rawName` is a basic energy
    /// line, else nil. Handles the optional "Basic " prefix.
    public static func match(_ rawName: String) -> String? {
        var n = Normalize.name(rawName)
        let prefix = "basic "
        if n.hasPrefix(prefix) { n = String(n.dropFirst(prefix.count)) }
        for t in types where n == "\(t) energy" {
            return "\(t.prefix(1).uppercased())\(t.dropFirst()) Energy"
        }
        return nil
    }
}
