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

        // ---- one entry per required equivalence group ----
        var entries: [GapEntry] = []
        for (key, required) in requiredByKey {
            guard let rep = repByKey[key] else { continue }
            let owned = ownedByKey[key] ?? 0
            let short = max(0, required - owned)
            let status: CardStatus = owned == 0 ? .missing : (short == 0 ? .have : .short)

            let requiredIds = requiredIdsByKey[key] ?? []
            let ownedIds = ownedIdsByKey[key] ?? []
            let differentPrinting = owned > 0 && !requiredIds.isSubset(of: ownedIds)

            var ownedNoLegal = false
            if let lens, owned > 0 {
                let anyLegal = ownedIds.contains { id in
                    guard let c = catalog.card(byId: id) else { return false }
                    return lens == .standard ? c.standardLegal : c.expandedLegal
                }
                ownedNoLegal = !anyLegal
            }

            entries.append(GapEntry(
                name: rep.name, equivalenceKey: key,
                requiredQty: required, ownedQty: owned, shortQty: short,
                status: status, differentPrinting: differentPrinting,
                ownedNoLegalPrinting: ownedNoLegal, representative: rep
            ))
        }

        // gap-first ordering: missing → short → have, then by name
        entries.sort { a, b in
            if rank(a.status) != rank(b.status) { return rank(a.status) < rank(b.status) }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        let coverable = requiredByKey.reduce(0) { $0 + min($1.value, ownedByKey[$1.key] ?? 0) }
        let shortTotal = requiredByKey.reduce(0) { $0 + max(0, $1.value - (ownedByKey[$1.key] ?? 0)) }

        return GapReport(
            entries: entries, unidentified: unidentified, basicEnergyQty: basicEnergyQty,
            deckTotal: deckTotal, buildableQty: basicEnergyQty + coverable,
            shortTotal: shortTotal, legalityLens: lens
        )
    }

    private static func rank(_ s: CardStatus) -> Int {
        switch s { case .missing: return 0; case .short: return 1; case .have: return 2 }
    }
}
