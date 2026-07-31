import Foundation

// deckcheck laptop CLI. Two subcommands over the tools/build-catalog catalog snapshot:
//   (default)  gap-check a decklist           (GapCheckCommand.swift)
//   search     search the catalog by name     (SearchCommand.swift)

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case badInventory(String)
    var description: String {
        switch self {
        case .usage(let m): return m
        case .badInventory(let m): return "bad inventory: \(m)"
        }
    }
}

let rawArgs = Array(CommandLine.arguments.dropFirst())
do {
    if rawArgs.first == "search" {
        try searchMain(Array(rawArgs.dropFirst()))
    } else {
        try gapCheckMain(rawArgs)
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
