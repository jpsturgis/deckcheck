import Foundation

/// The gap-check engine: parse → resolve → diff → gap-first report.
/// Functional ownership is the satisfaction criterion — a different printing that
/// hashes to the same equivalence key counts as owned (annotated).
public enum GapChecker {
    /// Convenience: parse + resolve + diff in one call.
    public static func check(decklist: String,
                             owned: [OwnedCard],
                             catalog: CatalogLookup,
                             lens: LegalityFormat? = nil) -> GapReport {
        let resolved = DecklistParser.parse(decklist).map { LineResolver.resolve($0, catalog: catalog) }
        return report(resolved: resolved, owned: owned, catalog: catalog, lens: lens)
    }

    /// Diff already-resolved lines against owned inventory. Split out so the app can
    /// resolve incrementally (e.g. after manual disambiguation) and re-diff.
    public static func report(resolved: [ResolvedLine],
                              owned: [OwnedCard],
                              catalog: CatalogLookup,
                              lens: LegalityFormat?) -> GapReport {
        // ---- aggregate the deck's requirements by equivalence key ----
        var requiredByKey: [String: Int] = [:]
        var requiredIdsByKey: [String: Set<String>] = [:]
        var repByKey: [String: CatalogCard] = [:]
        var basicEnergyQty = 0
        var unidentified: [ParsedLine] = []
        var deckTotal = 0

        for line in resolved {
            deckTotal += line.quantity
            switch line.resolution {
            case .basicEnergy:
                basicEnergyQty += line.quantity
            case .unidentified:
                unidentified.append(line.parsed)
            case .resolved(let card):
                requiredByKey[card.equivalenceKey, default: 0] += line.quantity
                requiredIdsByKey[card.equivalenceKey, default: []].insert(card.cardId)
                if repByKey[card.equivalenceKey] == nil { repByKey[card.equivalenceKey] = card }
            }
        }

        // ---- aggregate owned copies by equivalence key ----
        var ownedByKey: [String: Int] = [:]
        var ownedIdsByKey: [String: Set<String>] = [:]
        for o in owned {
            ownedByKey[o.equivalenceKey, default: 0] += o.qty
            ownedIdsByKey[o.equivalenceKey, default: []].insert(o.cardId)
        }

        let bridge = errataIndex(requiredByKey: requiredByKey, ownedByKey: ownedByKey,
                                 ownedIdsByKey: ownedIdsByKey, catalog: catalog)

        // ---- one entry per required equivalence group ----
        var entries: [GapEntry] = []
        for (key, required) in requiredByKey {
            guard let rep = repByKey[key] else { continue }
            let owned = ownedByKey[key] ?? 0

            // Only reach for the bridge when the exact group can't cover the line.
            var errataQty = 0
            var errataPrintings: [CatalogCard] = []
            if owned < required, let group = ErrataBridge.groupKey(rep) {
                for candidate in bridge[group] ?? [] where candidate.key != key {
                    errataQty += candidate.qty
                    errataPrintings.append(contentsOf: candidate.cards)
                }
                errataPrintings = errataPrintings.orderedNewestFirst()
            }

            let effective = owned + errataQty
            let short = max(0, required - effective)
            let status: CardStatus = effective == 0 ? .missing : (short == 0 ? .have : .short)

            let requiredIds = requiredIdsByKey[key] ?? []
            let ownedIds = ownedIdsByKey[key] ?? []
            let differentPrinting = owned > 0 && !requiredIds.isSubset(of: ownedIds)

            var ownedNoLegal = false
            if let lens, effective > 0 {
                // A bridged printing is a copy you could sleeve, so it counts here too.
                let bridgedIds = Set(errataPrintings.map(\.cardId))
                let anyLegal = ownedIds.union(bridgedIds).contains { id in
                    guard let c = catalog.card(byId: id) else { return false }
                    return lens == .standard ? c.standardLegal : c.expandedLegal
                }
                ownedNoLegal = !anyLegal
            }

            entries.append(GapEntry(
                name: rep.name, equivalenceKey: key,
                requiredQty: required, ownedQty: owned, shortQty: short,
                status: status, differentPrinting: differentPrinting,
                ownedNoLegalPrinting: ownedNoLegal, representative: rep,
                errataOwnedQty: errataQty, errataPrintings: errataPrintings
            ))
        }

        // gap-first ordering: missing → short → have, then by name
        entries.sort { a, b in
            if rank(a.status) != rank(b.status) { return rank(a.status) < rank(b.status) }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        let coverable = entries.reduce(0) { $0 + min($1.requiredQty, $1.effectiveOwnedQty) }
        let shortTotal = entries.reduce(0) { $0 + $1.shortQty }

        return GapReport(
            entries: entries, unidentified: unidentified, basicEnergyQty: basicEnergyQty,
            deckTotal: deckTotal, buildableQty: basicEnergyQty + coverable,
            shortTotal: shortTotal, legalityLens: lens
        )
    }

    /// Owned copies indexed by `ErrataBridge` group — the lookup that lets an
    /// under-covered line find the same card printed with different wording.
    ///
    /// Built only when some line is actually under-covered, and only over keys you
    /// *own*, so it costs one catalog read per owned group in the worst case and
    /// nothing at all for a deck you can already build.
    ///
    /// Caveat: if a decklist cites two wordings of the same card as separate lines,
    /// both entries see the same owned copies. That over-counts, but it needs a list
    /// that already breaks the four-of rule, and it can only under-report a gap.
    private static func errataIndex(
        requiredByKey: [String: Int],
        ownedByKey: [String: Int],
        ownedIdsByKey: [String: Set<String>],
        catalog: CatalogLookup
    ) -> [String: [(key: String, qty: Int, cards: [CatalogCard])]] {
        let underCovered = requiredByKey.contains { key, need in (ownedByKey[key] ?? 0) < need }
        guard underCovered else { return [:] }

        var index: [String: [(key: String, qty: Int, cards: [CatalogCard])]] = [:]
        for (key, qty) in ownedByKey where qty > 0 {
            // Every printing in an equivalence group shares a name and card type, so
            // any of them settles the group. Display, though, has to name the printings
            // actually in the binder — not the group's newest.
            guard let rep = catalog.cards(equivalenceKey: key).first,
                  let group = ErrataBridge.groupKey(rep) else { continue }
            let ownedCards = (ownedIdsByKey[key] ?? []).compactMap { catalog.card(byId: $0) }
            index[group, default: []].append((
                key: key, qty: qty,
                // A linked promo's `manual:` id resolves nowhere; fall back to the group.
                cards: ownedCards.isEmpty ? [rep] : ownedCards
            ))
        }
        return index
    }

    private static func rank(_ s: CardStatus) -> Int {
        switch s { case .missing: return 0; case .short: return 1; case .have: return 2 }
    }
}
