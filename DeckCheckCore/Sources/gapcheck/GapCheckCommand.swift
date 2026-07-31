import Foundation
import DeckCheckCore
import DeckCheckSQLite

// The default subcommand: gap-check a decklist.

struct GapOptions {
    var catalog = "catalog.sqlite"
    var deck: String?          // nil / "-" → stdin
    var inventory: String?
    var format: LegalityFormat?
    var buylist = false
}

let gapUsage = """
gapcheck — decklist gap-check against a catalog + your inventory

USAGE:
  swift run gapcheck [--catalog <catalog.sqlite>] [--deck <file>] [--inventory <file>]
                     [--format standard|expanded] [--buylist]

OPTIONS:
  --catalog <path>    SQLite snapshot from tools/build-catalog (default: ./catalog.sqlite)
  --deck <path>       decklist text file (TCG Live / Limitless). Omit or "-" for stdin.
  --inventory <path>  owned inventory: Apps Script doGet JSON, or a Sheet CSV export.
                      Omit to treat inventory as empty (a "buy the whole deck" report).
  --format <fmt>      legality lens: standard | expanded (off by default)
  --buylist           also print a one-paste TCGplayer Mass Entry buy list

(Run `gapcheck search --help` for catalog search)
"""

func parseGapOptions(_ argv: [String]) throws -> GapOptions {
    var o = GapOptions()
    var i = 0
    func next(_ flag: String) throws -> String {
        i += 1
        guard i < argv.count else { throw CLIError.usage("\(flag) needs a value\n\n\(gapUsage)") }
        return argv[i]
    }
    while i < argv.count {
        switch argv[i] {
        case "--catalog": o.catalog = try next("--catalog")
        case "--deck": o.deck = try next("--deck")
        case "--inventory": o.inventory = try next("--inventory")
        case "--format":
            let v = try next("--format")
            guard let f = LegalityFormat(rawValue: v.lowercased()) else {
                throw CLIError.usage("--format must be 'standard' or 'expanded'")
            }
            o.format = f
        case "--buylist": o.buylist = true
        case "-h", "--help": throw CLIError.usage(gapUsage)
        default: throw CLIError.usage("unknown argument: \(argv[i])\n\n\(gapUsage)")
        }
        i += 1
    }
    return o
}

func readDeck(_ path: String?) throws -> String {
    if let path, path != "-" {
        return try String(contentsOfFile: path, encoding: .utf8)
    }
    return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
}

func gapCheckMain(_ argv: [String]) throws {
    let opts = try parseGapOptions(argv)
    let catalog = try openCatalog(opts.catalog)
    let deckText = try readDeck(opts.deck)
    let owned = try opts.inventory.map { try InventoryLoader.load(path: $0, catalog: catalog) } ?? []
    let report = GapChecker.check(decklist: deckText, owned: owned, catalog: catalog, lens: opts.format)
    print(ReportFormatter.format(report, showBuylist: opts.buylist))
}

/// Shared catalog opener with a friendly not-found message.
func openCatalog(_ path: String) throws -> SQLiteCatalog {
    guard FileManager.default.fileExists(atPath: path) else {
        throw CLIError.usage("""
        catalog not found at \(path)
        Build one first:  (cd tools/build-catalog && npm run build)  then pass --catalog <path>.
        """)
    }
    return try SQLiteCatalog(path: path)
}
