import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// Apps Script API translation layer (spec §7.4 PART 2 — in-browser/app-closed
// gap-check). The pure, testable half of the deploy client: turn "create a
// container-bound script on the user's sheet and push the gap-check code" into
// concrete HTTPRequestSpecs against the Apps Script REST API
// (https://script.googleapis.com/v1), and parse the responses. The iOS shell
// (URLSession) just fires these.
//
// Only reachable when the user opts into the feature and grants the extra
// `script.projects` scope (OAuthConfig.scriptProjectsScope). The deployed project is
// bound to the user's *own* sheet; it contains only the trimmed gap-check code
// (Resources/Code.gs + gapcheck.gs), never the retired v1 web-app surface.
// ─────────────────────────────────────────────────────────────────────────────

public enum AppsScriptError: Error, Equatable {
    case malformedResponse
}

public enum AppsScript {
    static let base = "https://script.googleapis.com/v1"

    /// One file in an Apps Script project. `type` is "SERVER_JS" for code or "JSON"
    /// for the `appsscript` manifest; `name` carries no extension.
    public struct ScriptFile: Equatable {
        public let name: String
        public let type: String
        public let source: String
        public init(name: String, type: String, source: String) {
            self.name = name; self.type = type; self.source = source
        }
    }

    /// The project manifest. V8 runtime; no `oauthScopes` and no trigger declarations
    /// are needed because the deployed script uses only *simple* triggers (onOpen /
    /// onEdit) that touch nothing but their own container spreadsheet.
    public static let manifestSource = """
    {
      "timeZone": "Etc/UTC",
      "exceptionLogging": "STACKDRIVER",
      "runtimeVersion": "V8"
    }
    """

    /// Assemble the file set for a bound gap-check project from the two bundled
    /// sources: the manifest, the trimmed `Code.gs`, and the `gapcheck.gs` engine.
    /// Apps Script shares one global scope across files, so `Code` calls `gapcheck`'s
    /// functions directly (no import) — exactly as Code.gs does.
    public static func gapCheckFiles(codeSource: String, gapcheckSource: String) -> [ScriptFile] {
        [
            ScriptFile(name: "appsscript", type: "JSON", source: manifestSource),
            ScriptFile(name: "Code", type: "SERVER_JS", source: codeSource),
            ScriptFile(name: "gapcheck", type: "SERVER_JS", source: gapcheckSource),
        ]
    }

    /// A trigger-free file set that reliably neutralizes a deployed project when the
    /// user turns the feature off. The Apps Script API has no delete, and Drive-delete
    /// of an API-created project file can 403 — but overwriting content with no
    /// onEdit/onOpen (using the `script.projects` scope we already hold) always stops
    /// the triggers. The leftover empty project is invisible and inert.
    public static let neutralizedFiles: [ScriptFile] = [
        ScriptFile(name: "appsscript", type: "JSON", source: manifestSource),
        ScriptFile(name: "Code", type: "SERVER_JS",
                   source: "// In-browser gap-check turned off from the app. No triggers.\n"),
    ]

    /// Create a **container-bound** script project attached to the user's sheet
    /// (`parentId` = the spreadsheet id). Returns a project whose `scriptId` the app
    /// persists. Requires the Apps Script API to be enabled on the user's account
    /// (script.google.com/home/usersettings) — see docs/setup/browser-gap-check.md.
    public static func createBoundProjectRequest(title: String, parentSpreadsheetId: String,
                                                 accessToken: String) -> HTTPRequestSpec {
        jsonRequest(.post, url("\(base)/projects"), accessToken: accessToken,
                    json: ["title": title, "parentId": parentSpreadsheetId])
    }

    /// Replace the project's content with `files` (a full overwrite — the API has no
    /// partial update, so we always send the complete set). Used both for the initial
    /// push and to refresh the code on later app versions.
    public static func updateContentRequest(scriptId: String, files: [ScriptFile],
                                            accessToken: String) -> HTTPRequestSpec {
        let payload = files.map { ["name": $0.name, "type": $0.type, "source": $0.source] }
        return jsonRequest(.put, url("\(base)/projects/\(encode(scriptId))/content"),
                           accessToken: accessToken, json: ["files": payload])
    }

    /// Fetch the project (`projects.get`) — used to confirm a persisted scriptId still
    /// resolves before reusing it.
    public static func getProjectRequest(scriptId: String, accessToken: String) -> HTTPRequestSpec {
        HTTPRequestSpec(method: .get, url: url("\(base)/projects/\(encode(scriptId))"),
                        headers: ["Authorization": "Bearer \(accessToken)"])
    }

    /// Pull the `scriptId` out of a projects.create / projects.get response.
    public static func parseScriptId(_ data: Data) throws -> String {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["scriptId"] as? String, !id.isEmpty else {
            throw AppsScriptError.malformedResponse
        }
        return id
    }

    // ── helpers (self-contained; GoogleSheets' equivalents are private) ──────────

    private static func url(_ s: String) -> URL { URL(string: s)! }
    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }
    private static func jsonRequest(_ method: HTTPRequestSpec.Method, _ url: URL,
                                    accessToken: String, json: [String: Any]) -> HTTPRequestSpec {
        HTTPRequestSpec(
            method: method,
            url: url,
            headers: ["Authorization": "Bearer \(accessToken)", "Content-Type": "application/json"],
            body: try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        )
    }
}
