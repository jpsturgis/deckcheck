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
    func cards(name: String) -> [CatalogCard] {
        all.filter { Normalize.name($0.name) == Normalize.name(name) }
    }

    func searchByName(_ query: String, rowLimit: Int) -> [CatalogCard] {
        let tokens = SearchMatch.tokens(query)
        return Array(all.filter { SearchMatch.matches($0, tokens: tokens) }.prefix(rowLimit))
    }
}

extension FakeCatalog: CatalogSearching {}

/// Sets are derived from whatever cards the fake was given, so a test can define a set
/// just by adding printings to `all` — there's no second fixture to keep in step. A set
/// is legal in a format when any of its printings is, which is how the real snapshot's
/// per-set flags are built.
extension FakeCatalog: CatalogSetBrowsing {
    func sets() -> [CatalogSet] {
        var out: [CatalogSet] = []
        for setId in NSOrderedSet(array: all.map(\.setId)).array as! [String] {
            let inSet = all.filter { $0.setId == setId }
            guard let first = inSet.first else { continue }
            out.append(CatalogSet(
                setId: setId,
                name: first.setName,
                ptcgoCode: first.ptcgoCode,
                releaseDate: first.releaseDate,
                printedTotal: first.printedTotal,
                catalogCount: inSet.count,
                standardLegal: inSet.contains(where: \.standardLegal),
                expandedLegal: inSet.contains(where: \.expandedLegal)
            ))
        }
        return out
    }

    func cards(setId: String) -> [CatalogCard] {
        all.filter { $0.setId == setId }
            .sorted { $0.number.localizedStandardCompare($1.number) == .orderedAscending }
    }
}

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
        printedTotal: 193, releaseDate: "2023/06/09", subtypes: ["Supporter"])
    static let ionoPAF = CatalogCard(cardId: "ptcg:paf-237", setId: "paf", setName: "Paldean Fates",
        ptcgoCode: "PAF", number: "237", name: "Iono", supertype: .trainer,
        equivalenceKey: "iono", standardLegal: true, expandedLegal: true, regulationMark: "H",
        releaseDate: "2024/01/26", subtypes: ["Supporter"])

    // Boss's Orders — same key "boss": one rotated (not standard-legal), one legal reprint
    static let bossRCL = CatalogCard(cardId: "ptcg:rcl-154", setId: "rcl", setName: "Rebel Clash",
        ptcgoCode: "RCL", number: "154", name: "Boss's Orders", supertype: .trainer,
        equivalenceKey: "boss", standardLegal: false, expandedLegal: true, regulationMark: nil,
        releaseDate: "2020/05/01", subtypes: ["Supporter"])
    static let bossPAL = CatalogCard(cardId: "ptcg:pal-172", setId: "pal", setName: "Paldea Evolved",
        ptcgoCode: "PAL", number: "172", name: "Boss's Orders", supertype: .trainer,
        equivalenceKey: "boss", standardLegal: true, expandedLegal: true, regulationMark: "G",
        printedTotal: 193, releaseDate: "2023/06/09", subtypes: ["Supporter"])

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
        regulationMark: nil, printedTotal: 8, releaseDate: "2025/09/25", subtypes: ["Normal"])

    // Special energy IS tracked — it must never be mistaken for basic energy.
    static let reversalEnergy = CatalogCard(cardId: "ptcg:par-192", setId: "par",
        setName: "Paradox Rift", ptcgoCode: "PAR", number: "192", name: "Reversal Energy",
        supertype: .energy, equivalenceKey: "energy-reversal", standardLegal: true,
        expandedLegal: true, regulationMark: "H", printedTotal: 182, releaseDate: "2023/11/03",
        subtypes: ["Special"])

    // ── errata splits: same card, reworded, so the hash puts them in different groups ──
    // Both pairs are real. Energy Retrieval AOR 99 reads "Put 2 basic Energy cards…"
    // while SVI 171 reads "Put **up to** 2…"; Air Balloon SSH 213's text spells the
    // energy symbol out as "ColorlessColorless" where the modern reprint uses "{C}{C}".
    static let energyRetrievalAOR = CatalogCard(cardId: "ptcg:aor-99", setId: "aor",
        setName: "Ancient Origins", ptcgoCode: "AOR", number: "99", name: "Energy Retrieval",
        supertype: .trainer, equivalenceKey: "eretr-old", standardLegal: false, expandedLegal: true,
        regulationMark: nil, printedTotal: 98, releaseDate: "2015/08/12", subtypes: ["Item"])
    static let energyRetrievalSVI = CatalogCard(cardId: "ptcg:svi-171", setId: "svi",
        setName: "Scarlet & Violet", ptcgoCode: "SVI", number: "171", name: "Energy Retrieval",
        supertype: .trainer, equivalenceKey: "eretr-new", standardLegal: true, expandedLegal: true,
        regulationMark: "G", printedTotal: 198, releaseDate: "2023/03/31", subtypes: ["Item"])

    /// A second, *newer* printing in the same reworded group — so a test that owns the
    /// SVI copy can prove the report names the printing in the binder rather than
    /// whichever one the group happens to sort first.
    static let energyRetrievalCRI = CatalogCard(cardId: "ptcg:cri-108", setId: "cri",
        setName: "Chaos Rising", ptcgoCode: "CRI", number: "108", name: "Energy Retrieval",
        supertype: .trainer, equivalenceKey: "eretr-new", standardLegal: true, expandedLegal: true,
        regulationMark: "I", printedTotal: 86, releaseDate: "2026/05/22", subtypes: ["Item"])

    static let airBalloonSSH = CatalogCard(cardId: "ptcg:ssh-213", setId: "ssh",
        setName: "Sword & Shield", ptcgoCode: "SSH", number: "213", name: "Air Balloon",
        supertype: .trainer, equivalenceKey: "balloon-old", standardLegal: false, expandedLegal: true,
        regulationMark: nil, printedTotal: 202, releaseDate: "2020/02/07", subtypes: ["Tool"])
    static let airBalloonMEG = CatalogCard(cardId: "ptcg:meg-166", setId: "meg",
        setName: "Mega Evolution", ptcgoCode: "MEG", number: "166", name: "Air Balloon",
        supertype: .trainer, equivalenceKey: "balloon-new", standardLegal: true, expandedLegal: true,
        regulationMark: "I", printedTotal: 132, releaseDate: "2025/09/26", subtypes: ["Tool"])

    // ── deck-order fixtures: a 3-stage evolution family, an ace spec, a Stadium ──

    static let squirtle = CatalogCard(cardId: "ptcg:tst-1", setId: "tst", setName: "Test Set",
        ptcgoCode: "TST", number: "1", name: "Squirtle", supertype: .pokemon,
        equivalenceKey: "squirtle", standardLegal: true, expandedLegal: true,
        subtypes: ["Basic"])
    static let wartortle = CatalogCard(cardId: "ptcg:tst-2", setId: "tst", setName: "Test Set",
        ptcgoCode: "TST", number: "2", name: "Wartortle", supertype: .pokemon,
        equivalenceKey: "wartortle", standardLegal: true, expandedLegal: true,
        subtypes: ["Stage1"], evolvesFrom: "Squirtle")
    static let blastoise = CatalogCard(cardId: "ptcg:tst-3", setId: "tst", setName: "Test Set",
        ptcgoCode: "TST", number: "3", name: "Blastoise", supertype: .pokemon,
        equivalenceKey: "blastoise", standardLegal: true, expandedLegal: true,
        subtypes: ["Stage2"], evolvesFrom: "Wartortle")

    /// Same family, but its `evolvesFrom` chain is missing (the ~3% of legacy-format
    /// printings the real snapshot has) — exercises the `stage` subtype fallback.
    static let legacyStage2NoChain = CatalogCard(cardId: "ptcg:tst-9", setId: "tst",
        setName: "Test Set", ptcgoCode: "TST", number: "9", name: "Legacy Stage 2",
        supertype: .pokemon, equivalenceKey: "legacy-stage2", standardLegal: true,
        expandedLegal: true, subtypes: ["Stage2"])

    static let aceSpecItem = CatalogCard(cardId: "ptcg:tst-4", setId: "tst", setName: "Test Set",
        ptcgoCode: "TST", number: "4", name: "Prime Catcher", supertype: .trainer,
        equivalenceKey: "prime-catcher", standardLegal: true, expandedLegal: true,
        subtypes: ["Item"], isAceSpec: true)

    static let testStadium = CatalogCard(cardId: "ptcg:tst-5", setId: "tst", setName: "Test Set",
        ptcgoCode: "TST", number: "5", name: "Test Stadium", supertype: .trainer,
        equivalenceKey: "test-stadium", standardLegal: true, expandedLegal: true,
        subtypes: ["Stadium"])

    static let catalog = FakeCatalog(all: [
        charOBF, charPAF, ionoPAL, ionoPAF, bossRCL, bossPAL, dupA, dupB, ralts,
        fireEnergyMEE, reversalEnergy,
        energyRetrievalAOR, energyRetrievalSVI, energyRetrievalCRI, airBalloonSSH, airBalloonMEG,
        squirtle, wartortle, blastoise, legacyStage2NoChain, aceSpecItem, testStadium,
    ])
}
