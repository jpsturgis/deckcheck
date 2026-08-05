import Foundation
import DeckCheckCore
import DeckCheckSQLite

// `gapcheck migrate` — preview a normalization migration against a catalog snapshot.
//
// The migration itself runs in the app, because only the app holds the Google
// credentials to write the Sheet. This is the read-only half: it plans exactly what
// the app would do, from a CSV export of the Inventory tab, and prints it. Nothing
// here writes anything.
//
// The point is to be able to answer "what would this change?" before letting anything
// touch the database of record — particularly how many rows are silently mis-grouped
// today, which is invisible until a gap-check reports a card you own as missing.

private let migrateUsage = """
gapcheck migrate — preview re-deriving the Sheet's equivalence_key / norm_version

USAGE:
  swift run gapcheck migrate --inventory <inventory.csv> [--catalog <catalog.sqlite>]
                             [--list]

  --inventory  CSV export of the Inventory tab (File → Download → CSV in Sheets).
               Needs its header row; column order doesn't matter.
  --catalog    Catalog snapshot (default: ios/DeckCheck/catalog.sqlite).
  --list       Also list every affected row, not just the counts.

Read-only. Applying the plan is the app's job (Settings → Re-check card grouping).
"""

func migrateMain(_ args: [String]) throws {
    var inventoryPath: String?
    var catalogPath = "ios/DeckCheck/catalog.sqlite"
    var list = false

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--inventory": i += 1; inventoryPath = i < args.count ? args[i] : nil
        case "--catalog":   i += 1; if i < args.count { catalogPath = args[i] }
        case "--list":      list = true
        case "-h", "--help": print(migrateUsage); return
        default: throw CLIError.usage("unknown option \(args[i])\n\n\(migrateUsage)")
        }
        i += 1
    }
    guard let inventoryPath else { throw CLIError.usage("migrate needs --inventory <file>\n\n\(migrateUsage)") }

    let catalog = try SQLiteCatalog(path: catalogPath)
    guard let normVersion = catalog.normVersion else {
        throw CLIError.usage("""
        \(catalogPath) has no meta.norm_version — it predates the versioned catalog.
        Rebuild it with tools/build-catalog.
        """)
    }

    let grid = try readCSVGrid(path: inventoryPath)
    guard let table = SheetTable.parse(values: grid) else {
        throw CLIError.badInventory("\(inventoryPath) has no header row")
    }

    let plan = InventoryMigration.plan(table: table, catalog: catalog, normVersion: normVersion)

    // How the rows are stamped right now — the "before" picture, which is what makes
    // the plan legible (a blank stamp is not the same problem as a wrong one).
    let stamps = table.rows.reduce(into: [String: Int]()) { counts, placed in
        let stamp = placed.row.normVersion.isEmpty ? "(blank)" : placed.row.normVersion
        counts[stamp, default: 0] += 1
    }

    print("catalog   \(catalogPath)  ·  norm_version \(normVersion)")
    print("inventory \(inventoryPath)  ·  \(table.rows.count) rows")
    print("")
    print("stamped:")
    for (stamp, n) in stamps.sorted(by: { $0.key < $1.key }) {
        print("  \(stamp.padded(to: 10)) \(n)")
    }
    print("")
    print("plan:")
    print("  regrouped   \(plan.rekeyed.count)   equivalence_key was wrong — these are mis-grouped today")
    print("  restamped   \(plan.restamped.count)   key already correct, only the version stamp was stale")
    print("  re-link     \(plan.needsRelink.count)   linked promos whose key no longer exists — needs a person")
    print("  unknown     \(plan.unresolved.count)   card_id not in this catalog — left untouched")
    print("  ─────────")
    print("  writes      \(plan.ops.count) cell pair(s)")

    if list {
        func show(_ title: String, _ ids: [String]) {
            guard !ids.isEmpty else { return }
            print("\n\(title):")
            for id in ids { print("  \(id)") }
        }
        show("regrouped", plan.rekeyed)
        show("needs re-linking", plan.needsRelink)
        show("not in this catalog", plan.unresolved)
    }

    if plan.isEmpty {
        print("\nNothing to do — this Sheet already matches this catalog.")
    } else {
        print("\nApply it in the app: Settings → Re-check card grouping.")
    }
}

private extension String {
    func padded(to n: Int) -> String { count >= n ? self : self + String(repeating: " ", count: n - count) }
}

/// Minimal RFC 4180 reader — enough for a Sheets CSV export (quoted fields, doubled
/// quotes inside them, newlines inside quotes).
private func readCSVGrid(path: String) throws -> [[String]] {
    // Sheets exports CRLF, and Swift counts "\r\n" as ONE Character (it's a single
    // grapheme cluster) — so matching on "\r" or "\n" separately never fires and the
    // whole file reads as one enormous field. Normalize line endings up front.
    let text = try String(contentsOfFile: path, encoding: .utf8)
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    var grid: [[String]] = []
    var row: [String] = []
    var field = ""
    var inQuotes = false
    var chars = Array(text)
    var i = 0

    func endField() { row.append(field); field = "" }
    func endRow() {
        endField()
        if !(row.count == 1 && row[0].isEmpty) { grid.append(row) }
        row = []
    }

    while i < chars.count {
        let c = chars[i]
        if inQuotes {
            if c == "\"" {
                if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 }
                else { inQuotes = false }
            } else {
                field.append(c)
            }
        } else {
            switch c {
            case "\"": inQuotes = true
            case ",":  endField()
            case "\n": endRow()
            default:   field.append(c)
            }
        }
        i += 1
    }
    if !field.isEmpty || !row.isEmpty { endRow() }
    return grid
}
