import Foundation

/// The catalog read surface set-completion needs: enumerate sets, and list a set's
/// printings. Separate from `CatalogLookup` for the same reason `CatalogSearching` is —
/// it's a distinct capability, and a backend that can't enumerate (an in-memory test
/// double, say) shouldn't be forced to pretend it can.
public protocol CatalogSetBrowsing {
    /// Every set in the snapshot.
    func sets() -> [CatalogSet]
    /// Every printing in a set, by collector number.
    func cards(setId: String) -> [CatalogCard]
    /// Just the printing ids in a set.
    ///
    /// Counting is the hot path — it runs for every set on every inventory change —
    /// and it only ever needs identity. Going through `cards(setId:)` would
    /// materialize a full `CatalogCard` per row across the whole snapshot, parsing
    /// the subtypes JSON and extracting HP for ~23k cards to then look at one field.
    /// A backend that can do better should; the default keeps conformance free.
    func cardIds(setId: String) -> [String]
}

public extension CatalogSetBrowsing {
    func cardIds(setId: String) -> [String] { cards(setId: setId).map(\.cardId) }
}

/// A set as the snapshot carries it, plus the count of printings **actually in this
/// catalog**.
///
/// `catalogCount` is deliberately not the set's official `total`. The snapshot is built
/// from a third-party source that may not carry every printing, and a denominator you
/// can't reach makes a progress bar that never fills. Counting the rows you have keeps
/// "owned / total" honest and bounded — it can't read 192/191 because you own a secret
/// rare, and it can't stall at 99% because of a card the catalog never had.
public struct CatalogSet: Equatable {
    public let setId: String
    public let name: String
    public let ptcgoCode: String?
    public let releaseDate: String?      // "YYYY/MM/DD" — string compare is chronological
    public let printedTotal: Int?        // the printed "/191", for display only
    public let catalogCount: Int         // printings in this snapshot — the denominator
    public let standardLegal: Bool
    public let expandedLegal: Bool

    public init(setId: String, name: String, ptcgoCode: String?, releaseDate: String?,
                printedTotal: Int?, catalogCount: Int,
                standardLegal: Bool, expandedLegal: Bool) {
        self.setId = setId; self.name = name; self.ptcgoCode = ptcgoCode
        self.releaseDate = releaseDate; self.printedTotal = printedTotal
        self.catalogCount = catalogCount
        self.standardLegal = standardLegal; self.expandedLegal = expandedLegal
    }
}

/// How far through a set you are.
///
/// (`catalogSet`, not `set` — a stored property called `set` can't be read from inside
/// a computed property, because the parser takes it for the start of a setter.)
public struct SetProgress: Equatable, Identifiable {
    public let catalogSet: CatalogSet
    /// Distinct printings of this set you own at least one copy of.
    public let ownedCount: Int

    public var id: String { catalogSet.setId }
    public var setId: String { catalogSet.setId }
    public var name: String { catalogSet.name }
    public var ptcgoCode: String? { catalogSet.ptcgoCode }
    public var totalCount: Int { catalogSet.catalogCount }
    public var missingCount: Int { max(0, totalCount - ownedCount) }
    public var isComplete: Bool { totalCount > 0 && ownedCount >= totalCount }
    /// 0…1. A set with no rows reads as 0 rather than dividing by zero.
    public var fraction: Double {
        totalCount > 0 ? Double(ownedCount) / Double(totalCount) : 0
    }

    public init(catalogSet: CatalogSet, ownedCount: Int) {
        self.catalogSet = catalogSet; self.ownedCount = ownedCount
    }
}

/// Set completion — "you have 142 of the 191 cards in Surging Sparks".
///
/// **This is the one place in the app where equivalence groups are the wrong lens.**
/// Everywhere else, a reprint counts as the card it plays as: owning Iono PAF 237
/// satisfies a deck asking for Iono PAL 185. Set completion is about the physical
/// printings in a binder, so owning the PAF copy does nothing for your PAL page.
/// Matching is therefore by `cardId`, never by `equivalenceKey`.
public enum SetCompletion {

    /// Per-set progress, newest set first.
    ///
    /// `lens` filters which *sets* are listed (a Standard-only view shouldn't offer to
    /// sell you a completion goal in a rotated set); it never changes the counting
    /// inside a set, because a set's contents don't rotate independently of the set.
    public static func progress(owned: [OwnedCard],
                                catalog: any CatalogSetBrowsing,
                                lens: LegalityFormat? = nil) -> [SetProgress] {
        let ownedIds = ownedPrintingIds(owned)
        return catalog.sets()
            .filter { legal($0, lens) }
            .map { candidate in
                let count = catalog.cardIds(setId: candidate.setId).reduce(0) {
                    ownedIds.contains($1) ? $0 + 1 : $0
                }
                return SetProgress(catalogSet: candidate, ownedCount: count)
            }
            .sorted(by: newestFirst)
    }

    /// The printings in `setId` you don't own, by collector number — the buy list for
    /// finishing a set. Feed it to `TCGplayerExport` the same way a gap report is.
    public static func missing(inSet setId: String,
                               owned: [OwnedCard],
                               catalog: any CatalogSetBrowsing) -> [CatalogCard] {
        let ownedIds = ownedPrintingIds(owned)
        return catalog.cards(setId: setId).filter { !ownedIds.contains($0.cardId) }
    }

    /// Progress for one set, or nil when the catalog doesn't have it.
    public static func progress(forSet setId: String,
                                owned: [OwnedCard],
                                catalog: any CatalogSetBrowsing) -> SetProgress? {
        guard let found = catalog.sets().first(where: { $0.setId == setId }) else { return nil }
        let ownedIds = ownedPrintingIds(owned)
        let count = catalog.cardIds(setId: setId).reduce(0) {
            ownedIds.contains($1) ? $0 + 1 : $0
        }
        return SetProgress(catalogSet: found, ownedCount: count)
    }

    // MARK: -

    /// Printings held in quantity ≥ 1. A row that fell to zero is still in the Sheet —
    /// it must not count as owned.
    private static func ownedPrintingIds(_ owned: [OwnedCard]) -> Set<String> {
        Set(owned.lazy.filter { $0.qty > 0 }.map(\.cardId))
    }

    private static func legal(_ candidate: CatalogSet, _ lens: LegalityFormat?) -> Bool {
        switch lens {
        case .none:      return true
        case .standard:  return candidate.standardLegal
        case .expanded:  return candidate.expandedLegal
        }
    }

    /// Newest release first; undated sets sort last, name-ordered so the list is stable.
    private static func newestFirst(_ a: SetProgress, _ b: SetProgress) -> Bool {
        let ra = a.catalogSet.releaseDate ?? "", rb = b.catalogSet.releaseDate ?? ""
        if ra != rb { return ra > rb }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}
