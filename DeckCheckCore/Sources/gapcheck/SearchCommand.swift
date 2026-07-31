import Foundation
import DeckCheckCore
import DeckCheckSQLite

// The `search` subcommand: catalog-wide, name-based, equivalence-grouped, owned
// count including 0 (spec §7.3).

struct SearchOptions {
    var catalog = "catalog.sqlite"
    var query: String?
    var inventory: String?
    var format: LegalityFormat?
    var limit = 50
    var ownedOnly = false
}

let searchUsage = """
gapcheck search — catalog search, grouped by functional equivalence (spec §7.3)

USAGE:
  swift run gapcheck search [--catalog <catalog.sqlite>] --query <text>
                            [--inventory <file>] [--format standard|expanded]
                            [--limit N] [--owned-only]

OPTIONS:
  --query <text>      card name (case-insensitive substring). Required.
  --catalog <path>    SQLite snapshot from tools/build-catalog (default: ./catalog.sqlite)
  --inventory <path>  owned inventory (Apps Script doGet JSON or Sheet CSV) — drives
                      the owned count and "owned first" ordering. Omit for catalog-only.
  --format <fmt>      legality lens: standard | expanded (annotates format-legal)
  --limit N           max groups to show (default 50)
  --owned-only        only show cards you own
"""

func parseSearchOptions(_ argv: [String]) throws -> SearchOptions {
    var o = SearchOptions()
    var i = 0
    func next(_ flag: String) throws -> String {
        i += 1
        guard i < argv.count else { throw CLIError.usage("\(flag) needs a value\n\n\(searchUsage)") }
        return argv[i]
    }
    while i < argv.count {
        switch argv[i] {
        case "--catalog": o.catalog = try next("--catalog")
        case "--query", "-q": o.query = try next("--query")
        case "--inventory": o.inventory = try next("--inventory")
        case "--format":
            let v = try next("--format")
            guard let f = LegalityFormat(rawValue: v.lowercased()) else {
                throw CLIError.usage("--format must be 'standard' or 'expanded'")
            }
            o.format = f
        case "--limit":
            guard let n = Int(try next("--limit")), n > 0 else {
                throw CLIError.usage("--limit must be a positive integer")
            }
            o.limit = n
        case "--owned-only": o.ownedOnly = true
        case "-h", "--help": throw CLIError.usage(searchUsage)
        default: throw CLIError.usage("unknown argument: \(argv[i])\n\n\(searchUsage)")
        }
        i += 1
    }
    return o
}

func searchMain(_ argv: [String]) throws {
    let opts = try parseSearchOptions(argv)
    guard let query = opts.query, !query.isEmpty else {
        throw CLIError.usage("search needs --query <text>\n\n\(searchUsage)")
    }
    let catalog = try openCatalog(opts.catalog)
    let owned = try opts.inventory.map { try InventoryLoader.load(path: $0, catalog: catalog) } ?? []

    var groups = SearchService.search(query: query, owned: owned, catalog: catalog,
                                      lens: opts.format, maxGroups: opts.limit)
    if opts.ownedOnly { groups = groups.filter { $0.ownedCount > 0 } }
    print(SearchFormatter.format(groups, query: query, lens: opts.format))
}
