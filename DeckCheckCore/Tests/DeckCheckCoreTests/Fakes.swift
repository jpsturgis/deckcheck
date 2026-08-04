import Foundation
@testable import DeckCheckCore

/// In-memory CatalogLookup for tests — no SQLite, no network.
struct FakeCatalog: CatalogLookup {
    var all: [CatalogCard]

    func cards(setCode: String, number: String) -> [CatalogCard] {
        all.filter { $0.ptcgoCode?.caseInsensitiveCompare(setCode) == .orderedSame && $0.number == number }
    }
    func cards(number: String) -> [CatalogCard] {
        all.filter { $0.number == number }
    }
    func cards(printedTotal: Int, number: String) -> [CatalogCard] {
        all.filter { $0.printedTotal == printedTotal && $0.number == number }
    }
    func card(byId cardId: String) -> CatalogCard? {
        all.first { $0.cardId == cardId }
    }
    func cards(equivalenceKey: String) -> [CatalogCard] {
        all.filter { $0.equivalenceKey == equivalenceKey }
    }

    func searchByName(_ query: String, rowLimit: Int) -> [CatalogCard] {
        let tokens = SearchMatch.tokens(query)
        return Array(all.filter { SearchMatch.matches($0, tokens: tokens) }.prefix(rowLimit))
    }
}

extension FakeCatalog: CatalogSearching {}

/// A small fixture catalog with deliberate reprints (same equivalence key across
/// printings) and a rotated card, so the tests can exercise functional ownership
/// and the legality lens.
enum Fixture {
    // Charizard ex — two printings, same gameplay → same key "char". PAF is the newer set.
    static let charOBF = CatalogCard(cardId: "ptcg:obf-125", setId: "obf", setName: "Obsidian Flames",
        ptcgoCode: "OBF", number: "125", name: "Charizard ex", supertype: .pokemon,
        equivalenceKey: "char", standardLegal: true, expandedLegal: true, regulationMark: "G",
        printedTotal: 197, releaseDate: "2023/08/11")
    static let charPAF = CatalogCard(cardId: "ptcg:paf-234", setId: "paf", setName: "Paldean Fates",
        ptcgoCode: "PAF", number: "234", name: "Charizard ex", supertype: .pokemon,
        equivalenceKey: "char", standardLegal: true, expandedLegal: true, regulationMark: "H",
        releaseDate: "2024/01/26")

    // Iono — two printings, same key "iono". PAF is the newer set.
    static let ionoPAL = CatalogCard(cardId: "ptcg:pal-185", setId: "pal", setName: "Paldea Evolved",
        ptcgoCode: "PAL", number: "185", name: "Iono", supertype: .trainer,
        equivalenceKey: "iono", standardLegal: true, expandedLegal: true, regulationMark: "G",
        printedTotal: 193, releaseDate: "2023/06/09")
    static let ionoPAF = CatalogCard(cardId: "ptcg:paf-237", setId: "paf", setName: "Paldean Fates",
        ptcgoCode: "PAF", number: "237", name: "Iono", supertype: .trainer,
        equivalenceKey: "iono", standardLegal: true, expandedLegal: true, regulationMark: "H",
        releaseDate: "2024/01/26")

    // Boss's Orders — same key "boss": one rotated (not standard-legal), one legal reprint
    static let bossRCL = CatalogCard(cardId: "ptcg:rcl-154", setId: "rcl", setName: "Rebel Clash",
        ptcgoCode: "RCL", number: "154", name: "Boss's Orders", supertype: .trainer,
        equivalenceKey: "boss", standardLegal: false, expandedLegal: true, regulationMark: nil,
        releaseDate: "2020/05/01")
    static let bossPAL = CatalogCard(cardId: "ptcg:pal-172", setId: "pal", setName: "Paldea Evolved",
        ptcgoCode: "PAL", number: "172", name: "Boss's Orders", supertype: .trainer,
        equivalenceKey: "boss", standardLegal: true, expandedLegal: true, regulationMark: "G",
        printedTotal: 193, releaseDate: "2023/06/09")

    // Low collector number to exercise zero-padding: "5" + total 132 → "005/132".
    static let ralts = CatalogCard(cardId: "ptcg:meg-5", setId: "meg", setName: "Mega Evolution",
        ptcgoCode: "MEG", number: "5", name: "Ralts", supertype: .pokemon,
        equivalenceKey: "ralts", standardLegal: true, expandedLegal: true, regulationMark: nil,
        printedTotal: 132)

    // Two same-name, same-number, DIFFERENT-key cards → ambiguous by name+number.
    // Distinct HP lets the recognizer break the tie.
    static let dupA = CatalogCard(cardId: "ptcg:aaa-100", setId: "aaa", setName: "Set A",
        ptcgoCode: "AAA", number: "100", name: "Dup Mon", supertype: .pokemon,
        equivalenceKey: "dupA", standardLegal: true, expandedLegal: true, regulationMark: nil,
        printedTotal: 500, hp: "110")
    static let dupB = CatalogCard(cardId: "ptcg:bbb-100", setId: "bbb", setName: "Set B",
        ptcgoCode: "BBB", number: "100", name: "Dup Mon", supertype: .pokemon,
        equivalenceKey: "dupB", standardLegal: true, expandedLegal: true, regulationMark: nil,
        printedTotal: 500, hp: "60")

    // Basic energy as the *catalog* carries it — canonical name, supertype .energy.
    // A decklist can spell the same card "Basic {R} Energy MEE 2"; either way it must
    // auto-satisfy rather than resolve to this row and be reported as a gap.
    static let fireEnergyMEE = CatalogCard(cardId: "ptcg:mee-2", setId: "mee",
        setName: "Mega Evolution Energy", ptcgoCode: "MEE", number: "2", name: "Fire Energy",
        supertype: .energy, equivalenceKey: "energy-fire", standardLegal: true, expandedLegal: true,
        regulationMark: nil, printedTotal: 8, releaseDate: "2025/09/25")

    // Special energy IS tracked — it must never be mistaken for basic energy.
    static let reversalEnergy = CatalogCard(cardId: "ptcg:par-192", setId: "par",
        setName: "Paradox Rift", ptcgoCode: "PAR", number: "192", name: "Reversal Energy",
        supertype: .energy, equivalenceKey: "energy-reversal", standardLegal: true,
        expandedLegal: true, regulationMark: "H", printedTotal: 182, releaseDate: "2023/11/03")

    static let catalog = FakeCatalog(all: [
        charOBF, charPAF, ionoPAL, ionoPAF, bossRCL, bossPAL, dupA, dupB, ralts,
        fireEnergyMEE, reversalEnergy,
    ])
}
