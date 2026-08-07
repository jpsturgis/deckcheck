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

        // gap-first ordering: missing → short → have, then the deck-order comparator
        // (Pokémon in evolution order → Item → Tool → Supporter → Stadium → other
        // Trainer → Special Energy → Basic Energy, ace specs first within their type).
        let orderKeys = Self.deckOrderKeys(for: entries, catalog: catalog)
        entries.sort { a, b in
            if rank(a.status) != rank(b.status) { return rank(a.status) < rank(b.status) }
            guard let ka = orderKeys[a.equivalenceKey], let kb = orderKeys[b.equivalenceKey] else {
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            if ka.category != kb.category { return ka.category < kb.category }
            if ka.aceSpec != kb.aceSpec { return ka.aceSpec < kb.aceSpec }
            let familyOrder = ka.familyRoot.localizedCaseInsensitiveCompare(kb.familyRoot)
            if familyOrder != .orderedSame { return familyOrder == .orderedAscending }
            if ka.stageDepth != kb.stageDepth { return ka.stageDepth < kb.stageDepth }
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

    // MARK: - deck order (Pokémon evolution order → Trainer tiers → Energy)

    private struct DeckOrderKey {
        let category: Int      // 0 Pokémon, 1 Item, 2 Tool, 3 Supporter, 4 Stadium,
                                // 5 other Trainer, 6 Special Energy, 7 Basic Energy, 8 unknown
        let aceSpec: Int       // 0 = ace spec (sorts first within its tier), 1 = everything else
        let familyRoot: String // Pokémon: the family's base name; everything else: its own name
        let stageDepth: Int    // hops below familyRoot (0 = Basic / non-Pokémon)
    }

    private static func deckOrderKeys(for entries: [GapEntry], catalog: CatalogLookup) -> [String: DeckOrderKey] {
        var keys: [String: DeckOrderKey] = [:]
        for entry in entries {
            keys[entry.equivalenceKey] = deckOrderKey(entry.representative, catalog: catalog)
        }
        return keys
    }

    private static func deckOrderKey(_ card: CatalogCard, catalog: CatalogLookup) -> DeckOrderKey {
        let category: Int
        switch card.supertype {
        case .pokemon: category = 0
        case .trainer:
            switch card.subtypes.first {
            case "Item": category = 1
            case "Tool": category = 2
            case "Supporter": category = 3
            case "Stadium": category = 4
            default: category = 5   // e.g. Technical Machine, Rocket's Secret Machine
            }
        case .energy: category = card.subtypes.first == "Special" ? 6 : 7
        case .unknown: category = 8
        }

        let (root, depth) = card.supertype == .pokemon
            ? evolutionPosition(card, catalog: catalog) : (card.name, 0)
        return DeckOrderKey(category: category, aceSpec: card.isAceSpec ? 0 : 1,
                            familyRoot: root, stageDepth: depth)
    }

    /// Walks a Pokémon's `evolvesFrom` chain (capped at 5 hops, guarding against bad or
    /// cyclic data) to find its family's root name and this printing's depth below it —
    /// the signal behind "evolution order, where applicable". A card whose chain can't
    /// be walked (no `evolvesFrom`, or an ancestor name the catalog doesn't have — a
    /// real gap in some older/legacy-format printings) is its own family of one: it
    /// still sorts into the Pokémon tier, just not clustered with any relatives.
    private static func evolutionPosition(_ card: CatalogCard, catalog: CatalogLookup) -> (root: String, depth: Int) {
        var current = card
        var depth = 0
        var visited: Set<String> = [Normalize.name(card.name)]
        while let ancestorName = current.evolvesFrom, depth < 5 {
            guard let ancestor = catalog.cards(name: ancestorName).first,
                  visited.insert(Normalize.name(ancestor.name)).inserted else { break }
            current = ancestor
            depth += 1
        }
        return (current.name, depth)
    }
}
