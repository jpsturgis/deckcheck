import Foundation

// Loads the bundled Apps Script sources (Resources/Code.gs + gapcheck.gs) that the
// app deploys into the user's sheet for in-browser gap-check (spec §7.4 PART 2).
// Kept out of AppsScript.swift so those request builders stay pure/Bundle-free and
// unit-testable without resources; this loader is exercised via Bundle.module.
public enum BoundScriptAssets {
    public enum AssetError: Error, Equatable { case missing(String) }

    /// Read a bundled `.gs` source by base name.
    public static func source(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "gs", subdirectory: "Resources") else {
            throw AssetError.missing("\(name).gs")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The bound gap-check project's file set, ready for `AppsScript.updateContentRequest`.
    public static func gapCheckFiles() throws -> [AppsScript.ScriptFile] {
        AppsScript.gapCheckFiles(codeSource: try source("Code"),
                                 gapcheckSource: try source("gapcheck"))
    }
}
