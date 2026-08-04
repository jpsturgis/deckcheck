import Foundation

/// Bridges printings that the equivalence hash splits but the *game* treats as one card.
///
/// `equivalence_key` is an exact hash of a card's gameplay profile, and for Trainers and
/// Energy the profile is essentially the printed text. That is the right primitive — it
/// is what keeps two genuinely different cards that happen to share a name apart — but
/// it means a rewording splits a card from its own reprints. Real example: Energy
/// Retrieval reads "Put 2 basic Energy cards…" on AOR 99 and "Put **up to** 2 basic
/// Energy cards…" on SVI 171. Same card; two keys. A decklist citing the old printing
/// reported as missing even with four of the new one in the binder.
///
/// The Pokémon TCG resolves this by errata: a card is always played with its most recent
/// wording, so every printing of a given Trainer is interchangeable in a deck. This type
/// encodes that rule as a *looser* grouping used only to annotate the gap-check. The
/// strict key is never modified, and a bridged match is always reported as its own thing
/// rather than silently folded into "have" — the wording differs, and you should get to
/// see that.
///
/// Deliberately **not** applied to Pokémon. Two Pokémon sharing a name are routinely
/// different cards with different attacks and HP, and are not interchangeable; the
/// profile hash is doing exactly the right thing there. Restricting the bridge to
/// Trainer/Energy is what keeps it from becoming a false-positive machine.
public enum ErrataBridge {
    /// The looser group a card belongs to, or nil if it isn't eligible for bridging.
    /// Name plus card type: "Item" and "Tool" printings that share a name stay apart.
    public static func groupKey(_ card: CatalogCard) -> String? {
        switch card.supertype {
        case .trainer, .energy:
            let name = Normalize.name(card.name)
            guard !name.isEmpty else { return nil }
            let kind = card.subtypes.map { $0.lowercased() }.sorted().joined(separator: "+")
            return "\(name)\u{1F}\(kind)"
        case .pokemon, .unknown:
            // .unknown covers hand-entered promos, which already have an explicit
            // "plays as" link for exactly this purpose.
            return nil
        }
    }
}
