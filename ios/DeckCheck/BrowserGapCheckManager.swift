import Foundation
import DeckCheckCore

/// Optional, off-by-default: deploys a small Apps Script into the user's own Sheet so
/// the decklist gap-check runs in the browser with the app closed — edit column A of
/// the Gap Check tab and the report updates itself. See docs/setup/browser-gap-check.md.
///
/// Split out of `GoogleSheetsService`: this is its own concern with its own extra OAuth
/// consent (`script.projects`, requested only when turning this on) and its own
/// persisted state (which bound script + hidden Catalog tab it deployed) — none of
/// which the live-sync path needs to know about. Built on `sheets`'s connection
/// (`sheetRef` + a plain token) rather than holding a second one of its own.
@MainActor
final class BrowserGapCheckManager: ObservableObject {
    @Published private(set) var enabled = false
    @Published var status = ""
    @Published var busy = false
    @Published var lastError: String?

    private var scriptId: String?
    private var catalogSheetId: Int?

    private let sheets: GoogleSheetsService
    private let http = SheetsAPIHTTP()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let enabled = "v2.google.browserGapCheck"
        static let scriptId = "v2.google.scriptId"
        static let catalogSheetId = "v2.google.catalogSheetId"
    }

    init(sheets: GoogleSheetsService) {
        self.sheets = sheets
        enabled = defaults.bool(forKey: Keys.enabled)
        scriptId = defaults.string(forKey: Keys.scriptId)
        catalogSheetId = defaults.object(forKey: Keys.catalogSheetId) as? Int
    }

    /// An auth service that requests the extra `script.projects` scope (a fresh consent
    /// showing the Apps Script permission). Same client id / stored token as `sheets`'s.
    private var authWithScript: GoogleAuthService? {
        let id = sheets.clientId.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }
        return GoogleAuthService(config: .iOS(clientId: id, scopes: OAuthConfig.scopesWithScript))
    }

    /// Turn the feature on: grant `script.projects`, push the slim catalog resolution
    /// index into a hidden `Catalog` tab, and deploy the container-bound gap-check
    /// script into the user's own sheet. `catalog` is the app's loaded snapshot.
    func enable(catalog: (any CatalogLookup)?) async {
        await run("Enabling in-browser gap-check…") {
            guard let ref = self.sheets.sheetRef else { throw Fail("Connect your Inventory sheet first.") }
            let cards = catalog?.allCards() ?? []
            guard !cards.isEmpty else {
                throw Fail("The catalog isn't loaded yet — try again once it finishes loading.")
            }
            guard let scoped = self.authWithScript else { throw Fail("Enter your OAuth Client ID first.") }

            // 1) Grant the extra scope (interactive consent).
            try await scoped.signIn()
            let token = try await scoped.validAccessToken()

            // 2) Ensure the hidden Catalog tab exists, then push the index.
            let catId = try await self.ensureCatalogTab(ref: ref, token: token)
            self.status = "Pushing catalog index…"
            try await self.pushCatalogIndex(cards: cards, ref: ref, sheetId: catId, token: token)

            // 3) Create + push the bound gap-check script.
            self.status = "Deploying the gap-check script…"
            let sid = try await self.deployBoundScript(ref: ref, token: token)

            self.persist(scriptId: sid, catalogSheetId: catId)
            self.status = "In-browser gap-check is on — edit your decklist in the browser."
        }
    }

    /// Re-push the resolution index after a catalog rebuild (no new scope needed —
    /// writing the Catalog tab uses the `spreadsheets` scope already granted).
    func refreshCatalogIndex(catalog: (any CatalogLookup)?) async {
        await run("Refreshing catalog index…") {
            guard self.enabled, let ref = self.sheets.sheetRef else {
                throw Fail("In-browser gap-check isn't on.")
            }
            let cards = catalog?.allCards() ?? []
            guard !cards.isEmpty else { throw Fail("The catalog isn't loaded yet.") }
            let token = try await self.sheets.token()
            let catId = try await self.ensureCatalogTab(ref: ref, token: token)
            try await self.pushCatalogIndex(cards: cards, ref: ref, sheetId: catId, token: token)
            self.status = "Catalog index refreshed."
        }
    }

    /// Turn the feature off: trash the bound script (so its onEdit trigger stops) and
    /// remove the hidden Catalog tab. Both are best-effort; local state is cleared
    /// regardless so the toggle always reflects "off".
    func disable() async {
        await run("Turning off in-browser gap-check…") {
            let token = try? await self.sheets.token() // stored token still carries script.projects
            if let token {
                if let sid = self.scriptId {
                    // Reliably stop the onEdit/onOpen triggers by overwriting the project
                    // with trigger-free content; then best-effort trash the (now inert)
                    // project file. Drive-delete alone can 403 on an API-created project.
                    _ = try? await self.http.execute(
                        AppsScript.updateContentRequest(scriptId: sid, files: AppsScript.neutralizedFiles, accessToken: token))
                    _ = try? await self.http.execute(GoogleDrive.deleteFileRequest(fileId: sid, accessToken: token))
                }
                if let ref = self.sheets.sheetRef, let catId = self.catalogSheetId {
                    _ = try? await self.http.execute(
                        GoogleSheets.deleteSheetRequest(spreadsheetId: ref.spreadsheetId, sheetId: catId, accessToken: token))
                }
            }
            self.clearPersisted()
            self.status = "In-browser gap-check turned off."
        }
    }

    // MARK: -

    /// Find the hidden Catalog tab's sheetId, creating (and hiding) it if absent.
    private func ensureCatalogTab(ref: SheetRef, token: String) async throws -> Int {
        let info = try await http.execute(GoogleSheets.sheetPropertiesRequest(spreadsheetId: ref.spreadsheetId, accessToken: token))
        let idsByTitle = try GoogleSheets.parseSheetIds(info)
        if let existing = idsByTitle[GoogleSheets.catalogTitle] { return existing }
        let added = try await http.execute(
            GoogleSheets.addSheetRequest(spreadsheetId: ref.spreadsheetId, title: GoogleSheets.catalogTitle, accessToken: token))
        let sheetId = try GoogleSheets.parseAddedSheetId(added)
        _ = try? await http.execute(GoogleSheets.hideSheetRequest(spreadsheetId: ref.spreadsheetId, sheetId: sheetId, accessToken: token))
        return sheetId
    }

    /// Write the full slim resolution index (header + every card) into the Catalog tab.
    /// Pre-sizes the grid to the row count first, so the chunked writes (which start at
    /// explicit `A{n}` offsets) all land in-bounds.
    private func pushCatalogIndex(cards: [CatalogCard], ref: SheetRef, sheetId: Int, token: String) async throws {
        let block = CatalogIndexExport.valueBlock(cards)
        _ = try await http.execute(
            GoogleSheets.resizeSheetRequest(spreadsheetId: ref.spreadsheetId, sheetId: sheetId, rows: block.count, accessToken: token))
        for req in GoogleSheets.writeCatalogIndexRequests(spreadsheetId: ref.spreadsheetId, values: block, accessToken: token) {
            _ = try await http.execute(req)
        }
    }

    /// Reuse the persisted bound-script project if it still resolves, else create a new
    /// one; then overwrite its content with the current bundled gap-check code.
    private func deployBoundScript(ref: SheetRef, token: String) async throws -> String {
        let files = try BoundScriptAssets.gapCheckFiles()
        var sid: String
        if let existing = scriptId,
           (try? await http.execute(AppsScript.getProjectRequest(scriptId: existing, accessToken: token))) != nil {
            sid = existing
        } else {
            let created = try await http.execute(
                AppsScript.createBoundProjectRequest(title: "DeckCheck gap-check",
                                                     parentSpreadsheetId: ref.spreadsheetId, accessToken: token))
            sid = try AppsScript.parseScriptId(created)
        }
        _ = try await http.execute(AppsScript.updateContentRequest(scriptId: sid, files: files, accessToken: token))
        return sid
    }

    private func persist(scriptId: String, catalogSheetId: Int) {
        self.scriptId = scriptId
        self.catalogSheetId = catalogSheetId
        enabled = true
        defaults.set(scriptId, forKey: Keys.scriptId)
        defaults.set(catalogSheetId, forKey: Keys.catalogSheetId)
        defaults.set(true, forKey: Keys.enabled)
    }

    private func clearPersisted() {
        scriptId = nil
        catalogSheetId = nil
        enabled = false
        defaults.removeObject(forKey: Keys.scriptId)
        defaults.removeObject(forKey: Keys.catalogSheetId)
        defaults.set(false, forKey: Keys.enabled)
    }

    private func run(_ starting: String, _ work: @escaping () async throws -> Void) async {
        busy = true; lastError = nil; status = starting
        do { try await work() }
        catch { lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; status = "" }
        busy = false
    }

    private struct Fail: LocalizedError { let msg: String; init(_ m: String) { msg = m }; var errorDescription: String? { msg } }
}
