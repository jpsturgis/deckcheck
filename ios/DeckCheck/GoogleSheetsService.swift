import Foundation
import DeckCheckCore

// High-level v2 Sheets service: the onboarding/connection object the
// beta screen drives. It owns the per-user client id + the connected SheetRef
// (UserDefaults; not secret), delegates tokens to GoogleAuthService (Keychain), and
// composes the tested core request-builders (GoogleSheets) with the URLSession
// executor. This is the seam the real intake/removal flows will call in milestone 3;
// for now it also offers a read + write-round-trip self-test to prove the wiring.
//
// NOTE: the app defines its own `InventoryRow` (Models.swift, the v1 Apps Script
// shape), so the v2 code qualifies the core row type as `DeckCheckCore.InventoryRow`.

@MainActor
final class GoogleSheetsService: ObservableObject {
    @Published var clientId: String { didSet { defaults.set(clientId, forKey: Keys.clientId) } }
    @Published private(set) var sheetRef: SheetRef?
    @Published var status: String = ""
    @Published var busy = false
    @Published var lastError: String?

    /// In-browser / app-closed gap-check. Off by default; on only after
    /// the user opts in, grants `script.projects`, and the bound script is deployed.
    @Published private(set) var browserGapCheckEnabled = false
    private var scriptId: String?
    private var catalogSheetId: Int?

    private let defaults = UserDefaults.standard
    private let http = SheetsAPIHTTP()

    private enum Keys {
        static let clientId = "v2.google.clientId"
        static let spreadsheetId = "v2.google.spreadsheetId"
        static let sheetId = "v2.google.sheetId"
        static let browserGapCheck = "v2.google.browserGapCheck"
        static let scriptId = "v2.google.scriptId"
        static let catalogSheetId = "v2.google.catalogSheetId"
    }

    init() {
        clientId = defaults.string(forKey: Keys.clientId) ?? ""
        if let ssid = defaults.string(forKey: Keys.spreadsheetId) {
            let sid = defaults.integer(forKey: Keys.sheetId)
            sheetRef = SheetRef(spreadsheetId: ssid, sheetId: sid)
        }
        browserGapCheckEnabled = defaults.bool(forKey: Keys.browserGapCheck)
        scriptId = defaults.string(forKey: Keys.scriptId)
        catalogSheetId = defaults.object(forKey: Keys.catalogSheetId) as? Int
    }

    var isConfigured: Bool { !clientId.trimmingCharacters(in: .whitespaces).isEmpty }
    var auth: GoogleAuthService? {
        guard isConfigured else { return nil }
        return GoogleAuthService(config: .iOS(clientId: clientId.trimmingCharacters(in: .whitespaces)))
    }
    var isSignedIn: Bool { auth?.isSignedIn ?? false }
    var spreadsheetURL: URL? {
        sheetRef.flatMap { URL(string: "https://docs.google.com/spreadsheets/d/\($0.spreadsheetId)/edit") }
    }

    // MARK: intents (each wraps busy/status/error for the view)

    func signIn() async {
        await run("Signing in…") {
            guard let auth = self.auth else { throw Fail("Enter your OAuth Client ID first.") }
            try await auth.signIn()
            self.status = "Signed in."
        }
    }

    func signOut() {
        auth?.signOut()
        status = "Signed out."
        objectWillChange.send()
    }

    func createInventorySheet() async {
        await run("Creating your Inventory sheet…") {
            let token = try await self.token()
            let created = try await self.http.execute(GoogleSheets.createSpreadsheetRequest(accessToken: token))
            let ref = try GoogleSheets.parseSpreadsheet(created)
            _ = try await self.http.execute(GoogleSheets.writeHeaderRequest(ref: ref, accessToken: token))
            _ = try await self.http.execute(GoogleSheets.formatInventoryColumnsRequest(ref: ref, accessToken: token))
            _ = try await self.http.execute(GoogleSheets.seedGapCheckRequest(spreadsheetId: ref.spreadsheetId, accessToken: token))
            self.setSheetRef(ref)
            self.status = "Created — Inventory + Gap Check tabs are ready."
        }
    }

    func testRead() async {
        await run("Reading the Inventory sheet…") {
            let table = try await self.loadInventory()
            self.status = "Read OK — \(table.rows.count) data row(s), \(table.layout.columns.count) columns."
        }
    }

    /// Prove the full write path (append → verify → delete → verify) with a probe row.
    /// Safe: it removes what it adds. Point v2 at a COPY of your sheet regardless.
    func testWriteRoundTrip() async {
        await run("Write self-test…") {
            guard let ref = self.sheetRef else { throw Fail("Create the Inventory sheet first.") }
            let probe = DeckCheckCore.InventoryRow(
                name: "SELF-TEST (safe to delete)", set: "—", code: nil, number: "0", qty: 1,
                location: nil, cardId: "selftest-0", equivalenceKey: "selftest", normVersion: "v1")

            var token = try await self.token()
            let before = try await self.loadInventory(token: token)
            let appendPlan = SyncPlanner.plan(current: before, changes: [.intake(probe)])
            try await self.apply(appendPlan, ref: ref, layout: before.layout, token: token)

            token = try await self.token()
            let mid = try await self.loadInventory(token: token)
            guard mid.rows.contains(where: { $0.row.cardId == "selftest-0" }) else {
                throw Fail("Append didn't land — the probe row wasn't found after write.")
            }

            let deletePlan = SyncPlanner.plan(current: mid, changes: [.removal(cardId: "selftest-0")])
            try await self.apply(deletePlan, ref: ref, layout: mid.layout, token: token)

            token = try await self.token()
            let after = try await self.loadInventory(token: token)
            guard !after.rows.contains(where: { $0.row.cardId == "selftest-0" }) else {
                throw Fail("Delete didn't land — the probe row is still there.")
            }
            self.status = "Write self-test passed — append + delete round-tripped."
        }
    }

    // MARK: live sync (milestone 3) — the real read-cache + outbox path

    /// True once the v2 backend can serve the app: client id set, signed in, and an
    /// Inventory sheet connected. AppModel prefers this over the v1 Apps Script path.
    var isConnected: Bool { isConfigured && isSignedIn && sheetRef != nil }

    /// Read the whole Inventory tab into the app's read-cache rows.
    func fetchInventory() async throws -> [InventoryRow] {
        let table = try await loadInventory()
        return table.rows.map { placed in
            let r = placed.row
            return InventoryRow(card_id: r.cardId, name: r.name, set: r.set, code: r.code ?? "",
                                number: r.number, qty: r.qty, location: r.location ?? "",
                                equivalence_key: r.equivalenceKey, norm_version: r.normVersion)
        }
    }

    /// Save a decklist as a new `Deck: <name>` tab (used by "Add as deck" from the
    /// gap-checker). Fails if a tab with that title already exists.
    func createDeck(name: String, decklist: String) async throws {
        guard let ref = sheetRef else { throw Fail("Connect your Inventory sheet first.") }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw Fail("Enter a deck name.") }
        let title = "\(GoogleSheets.deckTabPrefix) \(clean)" // "Deck: <name>"
        let token = try await self.token()
        _ = try await http.execute(GoogleSheets.addSheetRequest(spreadsheetId: ref.spreadsheetId, title: title, accessToken: token))
        let rows = decklist.split(whereSeparator: \.isNewline).map { [String($0)] }
        if !rows.isEmpty {
            _ = try await http.execute(GoogleSheets.writeRangeRequest(
                spreadsheetId: ref.spreadsheetId, range: "'\(title)'!A1", values: rows, accessToken: token))
        }
    }

    /// Read the hand-maintained "Deck: <name>" tabs into decklists (the in-use
    /// feature). Each tab's rows are joined back into TCG Live decklist text.
    func fetchDecks() async throws -> [DeckList] {
        guard let ref = sheetRef else { return [] }
        let token = try await self.token()
        let info = try await http.execute(GoogleSheets.sheetTitlesRequest(ref: ref, accessToken: token))
        let titles = try GoogleSheets.parseSheetTitles(info).filter { $0.hasPrefix(GoogleSheets.deckTabPrefix) }
        var decks: [DeckList] = []
        for title in titles {
            let data = try await http.execute(
                GoogleSheets.readTabRequest(spreadsheetId: ref.spreadsheetId, title: title, accessToken: token))
            let grid = try GoogleSheets.parseValues(data)
            let text = grid
                .map { $0.joined(separator: " ").trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let name = String(title.dropFirst(GoogleSheets.deckTabPrefix.count)).trimmingCharacters(in: .whitespaces)
            decks.append(DeckList(name: name, text: text))
        }
        return decks
    }

    // ── sheet gap-check (app-driven) ──────────────────────────────

    /// Read the decklist pasted into column A of the Gap Check tab. If the tab is
    /// missing (a sheet created before this feature), create + seed it and return "".
    func readGapCheckDecklist() async throws -> String {
        guard let ref = sheetRef else { return "" }
        let token = try await self.token()
        do {
            let data = try await http.execute(
                GoogleSheets.readTabRequest(spreadsheetId: ref.spreadsheetId, title: GoogleSheets.gapCheckTitle, accessToken: token))
            let grid = try GoogleSheets.parseValues(data)
            return grid.map { $0.first ?? "" }.joined(separator: "\n") // column A
        } catch {
            try? await ensureGapCheckTab(token: token)
            return ""
        }
    }

    /// Write the gap report into column C of the Gap Check tab (clears the old one).
    func writeGapCheckReport(_ report: GapReport) async throws {
        guard let ref = sheetRef else { return }
        let token = try await self.token()
        // Clear C rightward (not just C:D): the bound Apps Script (in-browser
        // gap-check) writes a wider 7-column report, so a narrow clear would leave its
        // residue when the app later writes its compact report over the top.
        _ = try await http.execute(
            GoogleSheets.clearRangeRequest(spreadsheetId: ref.spreadsheetId, range: "'\(GoogleSheets.gapCheckTitle)'!C:Z", accessToken: token))
        _ = try await http.execute(
            GoogleSheets.writeRangeRequest(spreadsheetId: ref.spreadsheetId, range: "'\(GoogleSheets.gapCheckTitle)'!C1",
                                           values: GoogleSheets.gapCheckReportRows(report), accessToken: token, userEntered: true))
    }

    private func ensureGapCheckTab(token: String) async throws {
        guard let ref = sheetRef else { return }
        let info = try await http.execute(GoogleSheets.sheetTitlesRequest(ref: ref, accessToken: token))
        let titles = try GoogleSheets.parseSheetTitles(info)
        guard !titles.contains(GoogleSheets.gapCheckTitle) else { return }
        _ = try await http.execute(GoogleSheets.addSheetRequest(spreadsheetId: ref.spreadsheetId, title: GoogleSheets.gapCheckTitle, accessToken: token))
        _ = try await http.execute(GoogleSheets.seedGapCheckRequest(spreadsheetId: ref.spreadsheetId, accessToken: token))
    }

    // ── in-browser / app-closed gap-check ─────────────────────

    /// An auth service that requests the extra `script.projects` scope (a fresh consent
    /// showing the Apps Script permission). Same client id / stored token as `auth`.
    private var authWithScript: GoogleAuthService? {
        let id = clientId.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }
        return GoogleAuthService(config: .iOS(clientId: id, scopes: OAuthConfig.scopesWithScript))
    }

    /// Turn the feature on: grant `script.projects`, push the slim catalog resolution
    /// index into a hidden `Catalog` tab, and deploy the container-bound gap-check
    /// script into the user's own sheet. `catalog` is the app's loaded snapshot.
    func enableBrowserGapCheck(catalog: (any CatalogLookup)?) async {
        await run("Enabling in-browser gap-check…") {
            guard let ref = self.sheetRef else { throw Fail("Connect your Inventory sheet first.") }
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

            self.setBrowserGapCheck(scriptId: sid, catalogSheetId: catId)
            self.status = "In-browser gap-check is on — edit your decklist in the browser."
        }
    }

    /// Re-push the resolution index after a catalog rebuild (no new scope needed —
    /// writing the Catalog tab uses the `spreadsheets` scope you already have).
    func refreshCatalogIndex(catalog: (any CatalogLookup)?) async {
        await run("Refreshing catalog index…") {
            guard self.browserGapCheckEnabled, let ref = self.sheetRef else {
                throw Fail("In-browser gap-check isn't on.")
            }
            let cards = catalog?.allCards() ?? []
            guard !cards.isEmpty else { throw Fail("The catalog isn't loaded yet.") }
            let token = try await self.token()
            let catId = try await self.ensureCatalogTab(ref: ref, token: token)
            try await self.pushCatalogIndex(cards: cards, ref: ref, sheetId: catId, token: token)
            self.status = "Catalog index refreshed."
        }
    }

    /// Turn the feature off: trash the bound script (so its onEdit trigger stops) and
    /// remove the hidden Catalog tab. Both are best-effort; local state is cleared
    /// regardless so the toggle always reflects "off".
    func disableBrowserGapCheck() async {
        await run("Turning off in-browser gap-check…") {
            let token = try? await self.token() // stored token still carries script.projects
            if let token {
                if let sid = self.scriptId {
                    // Reliably stop the onEdit/onOpen triggers by overwriting the project
                    // with trigger-free content; then best-effort trash the (now inert)
                    // project file. Drive-delete alone can 403 on an API-created project.
                    _ = try? await self.http.execute(
                        AppsScript.updateContentRequest(scriptId: sid, files: AppsScript.neutralizedFiles, accessToken: token))
                    _ = try? await self.http.execute(GoogleDrive.deleteFileRequest(fileId: sid, accessToken: token))
                }
                if let ref = self.sheetRef, let catId = self.catalogSheetId {
                    _ = try? await self.http.execute(
                        GoogleSheets.deleteSheetRequest(spreadsheetId: ref.spreadsheetId, sheetId: catId, accessToken: token))
                }
            }
            self.clearBrowserGapCheck()
            self.status = "In-browser gap-check turned off."
        }
    }

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

    private func setBrowserGapCheck(scriptId: String, catalogSheetId: Int) {
        self.scriptId = scriptId
        self.catalogSheetId = catalogSheetId
        browserGapCheckEnabled = true
        defaults.set(scriptId, forKey: Keys.scriptId)
        defaults.set(catalogSheetId, forKey: Keys.catalogSheetId)
        defaults.set(true, forKey: Keys.browserGapCheck)
    }

    private func clearBrowserGapCheck() {
        scriptId = nil
        catalogSheetId = nil
        browserGapCheckEnabled = false
        defaults.removeObject(forKey: Keys.scriptId)
        defaults.removeObject(forKey: Keys.catalogSheetId)
        defaults.set(false, forKey: Keys.browserGapCheck)
    }

    /// Flush an outbox batch to the Sheet: convert ops → InventoryChanges,
    /// plan against the current grid, execute. Returns the ids of ops acknowledged
    /// (all, on success — the whole batch is applied atomically enough for a single
    /// user, so a throw leaves everything queued for retry).
    func applyOutbox(_ ops: [OutboxOp]) async throws -> Set<String> {
        guard let ref = sheetRef else { throw Fail("Connect your Inventory sheet first.") }
        let changes: [InventoryChange] = ops.map { op in
            switch op.op {
            case .intake:
                let row = DeckCheckCore.InventoryRow(
                    name: op.name, set: op.set, code: op.code.isEmpty ? nil : op.code,
                    number: op.number, qty: 1, location: op.location.isEmpty ? nil : op.location,
                    cardId: op.card_id, equivalenceKey: op.equivalence_key, normVersion: op.norm_version)
                return .intake(row, quantity: 1)
            case .removal:
                return .removal(cardId: op.card_id, quantity: 1)
            }
        }
        let token = try await self.token()
        let table = try await loadInventory(token: token)
        let plan = SyncPlanner.plan(current: table, changes: changes)
        try await apply(plan, ref: ref, layout: table.layout, token: token)
        return Set(ops.map { $0.id })
    }

    // MARK: plumbing

    private func token() async throws -> String {
        guard let auth = self.auth else { throw Fail("Enter your OAuth Client ID first.") }
        return try await auth.validAccessToken()
    }

    private func loadInventory(token: String? = nil) async throws -> SheetTable {
        guard let ref = sheetRef else { throw Fail("Create the Inventory sheet first.") }
        let t: String
        if let token { t = token } else { t = try await self.token() }
        let data = try await http.execute(GoogleSheets.readRequest(ref: ref, accessToken: t))
        let grid = try GoogleSheets.parseValues(data)
        guard let table = SheetTable.parse(values: grid) else { throw Fail("The sheet has no header row.") }
        return table
    }

    private func apply(_ plan: SyncPlanner.Plan, ref: SheetRef, layout: SheetLayout, token: String) async throws {
        for req in GoogleSheets.applyRequests(plan: plan, ref: ref, layout: layout, accessToken: token) {
            _ = try await http.execute(req)
        }
    }

    private func setSheetRef(_ ref: SheetRef) {
        sheetRef = ref
        defaults.set(ref.spreadsheetId, forKey: Keys.spreadsheetId)
        defaults.set(ref.sheetId, forKey: Keys.sheetId)
    }

    private func run(_ starting: String, _ work: @escaping () async throws -> Void) async {
        busy = true; lastError = nil; status = starting
        do { try await work() }
        catch { lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; status = "" }
        busy = false
    }

    struct Fail: LocalizedError { let msg: String; init(_ m: String) { msg = m }; var errorDescription: String? { msg } }
}
