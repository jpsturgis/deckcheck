import Foundation

/// A promo the bundled catalog can't resolve, entered by hand (the "promo entry
/// path"). Brand-new promo sets — e.g. TCGplayer's "Mega Evolution Promos" (MEP) —
/// lag the pokemontcg.io source the catalog is built from, and promos print their
/// own set code + number (e.g. "MEP EN 075") with a black star and no "/total", so
/// the recognizer's set-pin and number lookups can't reach them (their number in the
/// source, when present at all, is a different value). The user types name + set code
/// + number; we synthesize a `CatalogCard` so the promo flows through intake /
/// inventory / removal exactly like a resolved printing — no special-casing anywhere
/// downstream.
public enum ManualEntry {
    /// Prefix marking a hand-entered card's synthetic id — never collides with a real
    /// `ptcg:` catalog id, and lets the UI tell promos apart (e.g. to badge them).
    public static let idPrefix = "manual:"

    /// Whether a card id is a hand-entered promo (vs. a real catalog printing).
    public static func isManual(_ cardId: String) -> Bool { cardId.hasPrefix(idPrefix) }

    /// Build a synthetic printing from hand-entered promo fields. Inputs are trimmed;
    /// the set code is upper-cased (TCGplayer codes are upper-case, e.g. MEP). Returns
    /// nil only when there's nothing to identify the card by (name and number both
    /// blank).
    ///
    /// The synthetic `cardId` is always a stable `manual:`-prefixed value derived from
    /// the typed fields (so re-entering the same promo matches for removal, and never
    /// collides with a real `ptcg:` id). `equivalenceKey`:
    /// - if `equivalenceKey` is supplied (the user linked the catalog card this promo
    ///   *plays as*, §4), the promo adopts that functional group and so counts as a copy
    ///   in the gap-check (#48);
    /// - otherwise it's the `manual:` id — the promo is its own one-printing group and
    ///   won't match any deck's requirement.
    public static func promoCard(name: String, code: String, number: String,
                                 equivalenceKey: String? = nil) -> CatalogCard? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let number = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty || !number.isEmpty else { return nil }

        // code + number is unique within a TCGplayer promo set; fall back to the name
        // when the code is unknown so two different promos never share an identity.
        // A *linked* promo folds its adopted key into the id, so a re-link produces a
        // genuinely distinct row: remove the old id + append the new id can ride one
        // outbox batch without the reconciler netting them into a mere qty change
        // (it keys rows by card_id and never rewrites a row's equivalence_key). §5.3
        let idSource = [code.isEmpty ? name : code, number, equivalenceKey]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let id = idPrefix + slug(idSource)

        return CatalogCard(
            cardId: id,
            setId: "",
            setName: "",
            ptcgoCode: code.isEmpty ? nil : code,
            number: number,
            name: name,
            supertype: .unknown,
            equivalenceKey: equivalenceKey ?? id,
            standardLegal: false,
            expandedLegal: false,
            regulationMark: nil,
            printedTotal: nil,
            imageSmall: nil,
            imageLarge: nil
        )
    }

    /// Lowercase, keep letters/digits, collapse every other run to a single dash.
    private static func slug(_ s: String) -> String {
        var out = ""
        var pendingDash = false
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber {
                if pendingDash && !out.isEmpty { out.append("-") }
                out.append(ch)
                pendingDash = false
            } else {
                pendingDash = true
            }
        }
        return out
    }
}
