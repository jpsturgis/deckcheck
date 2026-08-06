import Foundation

// Inventory search: catalog-wide, by card name, equivalence-grouped,
// read-only. Each result shows the owned count **including 0** (any printing) plus
// the specific owned printings, with an optional off-by-default legality lens. Owned
// cards surface first. Shares the CatalogLookup catalog + equivalence grouping with
// the gap-check.

/// Catalog name-search surface. Separate from `CatalogLookup` so a backend needn't
/// implement search unless it offers it (the SQLite snapshot does; the app reuses it).
public protocol CatalogSearching {
    /// Catalog printings matching `query` — a multi-term match (see `SearchMatch`):
    /// each whitespace token must be a case-insensitive substring of the name, set
    /// name, set code, number, or number/printedTotal, and all tokens must match.
    /// `rowLimit` bounds the rows returned — a safety cap, not a per-group limit.
    /// (Name kept for source stability; matching is no longer name-only.)
    func searchByName(_ query: String, rowLimit: Int) -> [CatalogCard]
}

/// A specific owned printing within a search group.
public struct OwnedPrinting: Equatable {
    public let card: CatalogCard
    public let qty: Int
    public init(card: CatalogCard, qty: Int) { self.card = card; self.qty = qty }
}

/// One functional-equivalence group in the search results.
public struct SearchResultGroup: Equatable {
    public let name: String
    public let equivalenceKey: String
    public let ownedCount: Int                  // Σ qty across the group — 0 for unowned (a definitive "0", not empty)
    public let printings: [CatalogCard]         // catalog printings in the group (from the name match)
    public let ownedPrintings: [OwnedPrinting]  // the specific printings you own (expandable in the app)
    public let formatLegal: Bool?               // any printing legal in the lens format; nil if no lens
    public let representative: CatalogCard

    public init(name: String, equivalenceKey: String, ownedCount: Int,
                printings: [CatalogCard], ownedPrintings: [OwnedPrinting],
                formatLegal: Bool?, representative: CatalogCard) {
        self.name = name; self.equivalenceKey = equivalenceKey; self.ownedCount = ownedCount
        self.printings = printings; self.ownedPrintings = ownedPrintings
        self.formatLegal = formatLegal; self.representative = representative
    }
}

/// One owned printing within an Owned-scope group: the Sheet row plus its catalog
/// resolution — `card` is nil for a hand-entered promo the catalog doesn't carry.
public struct OwnedRowPrinting: Equatable {
    public let row: InventoryRow
    public let card: CatalogCard?
    public init(row: InventoryRow, card: CatalogCard?) { self.row = row; self.card = card }
}

/// One equivalence-group of owned printings — the Owned scope's browse unit.
public struct OwnedGroup: Equatable {
    public let equivalenceKey: String
    public let name: String
    public let ownedCount: Int              // Σ qty across the group's rows
    public let printings: [OwnedRowPrinting] // newest catalog printing first
    public init(equivalenceKey: String, name: String, ownedCount: Int, printings: [OwnedRowPrinting]) {
        self.equivalenceKey = equivalenceKey; self.name = name
        self.ownedCount = ownedCount; self.printings = printings
    }
}

public enum SearchService {
    /// How the result groups are ordered (owned always sort first either way).
    public enum GroupOrder {
        case ownedThenName     // A→Z — the browse default (Cards tab)
        case ownedThenNewest   // newest set first — surfaces the current printing (scan picker)
    }

    /// Search the catalog and fold results into equivalence groups, owned first.
    /// Matching is multi-term (see `SearchMatch`). `maxGroups` caps the returned
    /// groups; `rowLimit` caps the match rows scanned before grouping.
    public static func search(query: String,
                              owned: [OwnedCard],
                              catalog: CatalogSearching,
                              lens: LegalityFormat? = nil,
                              order: GroupOrder = .ownedThenName,
                              maxGroups: Int = 50,
                              rowLimit: Int = 5000) -> [SearchResultGroup] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        // owned copies, by exact printing and by functional group
        var ownedQtyById: [String: Int] = [:]
        var ownedQtyByKey: [String: Int] = [:]
        for o in owned {
            ownedQtyById[o.cardId, default: 0] += o.qty
            ownedQtyByKey[o.equivalenceKey, default: 0] += o.qty
        }

        // group matched printings by equivalence key, preserving first-seen order
        var keyOrder: [String] = []
        var byKey: [String: [CatalogCard]] = [:]
        for c in catalog.searchByName(q, rowLimit: rowLimit) {
            if byKey[c.equivalenceKey] == nil { keyOrder.append(c.equivalenceKey) }
            byKey[c.equivalenceKey, default: []].append(c)
        }

        var groups: [SearchResultGroup] = []
        for key in keyOrder {
            // Newest printing first so the representative is the current one.
            guard let printings = byKey[key]?.orderedNewestFirst(), let rep = printings.first else { continue }
            let ownedPrintings = printings.compactMap { p -> OwnedPrinting? in
                guard let n = ownedQtyById[p.cardId], n > 0 else { return nil }
                return OwnedPrinting(card: p, qty: n)
            }
            let formatLegal: Bool? = lens.map { l in
                printings.contains { l == .standard ? $0.standardLegal : $0.expandedLegal }
            }
            groups.append(SearchResultGroup(
                name: rep.name, equivalenceKey: key,
                ownedCount: ownedQtyByKey[key] ?? 0,   // functional-group total
                printings: printings, ownedPrintings: ownedPrintings,
                formatLegal: formatLegal, representative: rep))
        }

        // owned first, then the requested order. `representative` is the group's newest
        // printing, so its release date orders the groups newest-first; undated
        // groups sort last, name breaks ties.
        groups.sort { a, b in
            if (a.ownedCount > 0) != (b.ownedCount > 0) { return a.ownedCount > 0 }
            if case .ownedThenNewest = order {
                let ra = a.representative.releaseDate ?? "", rb = b.representative.releaseDate ?? ""
                if ra != rb { return ra > rb }
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return Array(groups.prefix(maxGroups))
    }

    /// Group the owned Sheet rows matching `query` by equivalence key — the Owned
    /// scope's source of groups. Unlike `search`, this starts from the rows you
    /// actually have rather than a catalog query, so a hand-entered promo with no
    /// catalog printing of its own still appears, grouped by its equivalence key.
    ///
    /// `resolved` is the caller's own row-id → `CatalogCard` lookup (the app keeps one
    /// memoized per inventory revision) — this never resolves a card itself, so it
    /// costs no catalog reads beyond what the caller already paid for. It must come
    /// from `catalog`: a row missing from `resolved` is treated as uncataloged (its
    /// legality falls back to its equivalence group) regardless of whether `catalog`
    /// could actually resolve it.
    public static func ownedGroups(query: String, rows: [InventoryRow],
                                   resolved: [String: CatalogCard],
                                   catalog: (any CatalogLookup)?,
                                   lens: LegalityFormat? = nil) -> [OwnedGroup] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var keyOrder: [String] = []
        var byKey: [String: [InventoryRow]] = [:]
        for row in rows where row.qty > 0 {
            if !q.isEmpty && !row.name.lowercased().contains(q) { continue }
            if byKey[row.equivalenceKey] == nil { keyOrder.append(row.equivalenceKey) }
            byKey[row.equivalenceKey, default: []].append(row)
        }

        // Every key in keyOrder was added the moment its bucket got a first row, so
        // `byKey[key]!` is never empty here.
        let groups: [OwnedGroup] = keyOrder.compactMap { key in
            let printings = byKey[key]!
                .map { OwnedRowPrinting(row: $0, card: resolved[$0.cardId]) }
                .sorted { a, b in
                    let da = a.card?.releaseDate ?? "", db = b.card?.releaseDate ?? ""
                    if da != db { return da > db }
                    return (a.row.set, a.row.number) < (b.row.set, b.row.number)
                }
            guard groupIsLegal(printings, equivalenceKey: key, catalog: catalog, lens: lens) else { return nil }
            return OwnedGroup(equivalenceKey: key, name: printings[0].row.name,
                              ownedCount: printings.reduce(0) { $0 + $1.row.qty },
                              printings: printings)
        }
        return groups.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// A group passes the lens if any owned printing is legal. A promo with no
    /// catalog printing of its own is judged by its equivalence group instead — the
    /// same fallback `search`'s per-printing `formatLegal` doesn't need, because
    /// there every printing comes from the catalog already.
    private static func groupIsLegal(_ printings: [OwnedRowPrinting], equivalenceKey: String,
                                     catalog: (any CatalogLookup)?, lens: LegalityFormat?) -> Bool {
        guard let lens else { return true }
        func legal(_ c: CatalogCard) -> Bool { lens == .standard ? c.standardLegal : c.expandedLegal }
        return printings.contains { p in
            if let c = p.card { return legal(c) }
            return (catalog?.cards(equivalenceKey: equivalenceKey) ?? []).contains(where: legal)
        }
    }
}
