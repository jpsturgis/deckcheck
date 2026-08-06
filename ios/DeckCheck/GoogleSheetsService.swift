import Foundation
import DeckCheckCore

// High-level v2 Sheets service: the onboarding/connection object the
// beta screen drives. It owns the per-user client id + the connected SheetRef
// (UserDefaults; not secret), delegates tokens to GoogleAuthService (Keychain), and
// composes the tested core request-builders (GoogleSheets) with the URLSession
// executor. This is the seam the real intake/removal flows will call in milestone 3;
// for now it also offers a read + write-round-trip self-test to prove the wiring.
//
// NOTE: the app's own read-cache row type is `ReadCacheRow` (Models.swift) — distinct
// from `InventoryRow` here, so no qualification is needed for either.
//
// The in-browser gap-check bound-script feature lives in its own
// BrowserGapCheckManager, built on this connection's `token()` + `sheetRef` — a
// separate concern with its own OAuth scope and its own persisted state.
//
// Column re-derivation ("Re-check card grouping") lives in its own InventoryMigrator,
// built on this connection's `token()` / `loadInventory()` / `apply()` — a separate
// concern (one caller, no live-sync knowledge needed) that happens to reuse the same
// read/plan/apply shape the outbox flush already uses.

@MainActor
final class GoogleSheetsService: ObservableObject {
    @Published var clientId: String { didSet { defaults.set(clientId, forKey: Keys.clientId) } }
    @Published private(set) var sheetRef: SheetRef?
    @Published var status: String = ""
    @Published var busy = false
    @Published var lastError: String?

    private let defaults = UserDefaults.standard
    private let http = SheetsAPIHTTP()

    private enum Keys {
        static let clientId = "v2.google.clientId"
        static let spreadsheetId = "v2.google.spreadsheetId"
        static let sheetId = "v2.google.sheetId"
    }

    init() {
        clientId = defaults.string(forKey: Keys.clientId) ?? ""
        if let ssid = defaults.string(forKey: Keys.spreadsheetId) {
            let sid = defaults.integer(forKey: Keys.sheetId)
            sheetRef = SheetRef(spreadsheetId: ssid, sheetId: sid)
        }
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
            let probe = InventoryRow(
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
    func fetchInventory() async throws -> [ReadCacheRow] {
        let table = try await loadInventory()
        return table.rows.map { placed in
            let r = placed.row
            return ReadCacheRow(card_id: r.cardId, name: r.name, set: r.set, code: r.code ?? "",
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

    /// Replace a deck tab's contents with `text`, one line per row in column A.
    ///
    /// **Write first, then clear the tail.** The obvious implementation — clear the
    /// column, then write — has a window where a dropped connection leaves the user
    /// with an empty deck tab and no way back. Writing the new lines over the old ones
    /// first means an interrupted update leaves a *superset* of the deck: possibly a
    /// few stale rows at the bottom, never a lost decklist. Those trailing rows are
    /// cleared in a second call, and if that one fails the next successful save fixes
    /// it. Only column A is touched, so anything in B onward is left alone.
    func writeDeck(_ deck: DeckList, text: String) async throws {
        guard let ref = sheetRef else { throw Fail("Connect your Inventory sheet first.") }
        let token = try await self.token()

        let existing = try await http.execute(GoogleSheets.readTabRequest(
            spreadsheetId: ref.spreadsheetId, title: deck.tabTitle, accessToken: token))
        let previousRows = try GoogleSheets.parseValues(existing).count

        let rows = text.components(separatedBy: "\n").map { [$0] }
        _ = try await http.execute(GoogleSheets.writeRangeRequest(
            spreadsheetId: ref.spreadsheetId,
            range: "'\(deck.tabTitle)'!A1",
            values: rows, accessToken: token))

        if previousRows > rows.count {
            _ = try await http.execute(GoogleSheets.clearRangeRequest(
                spreadsheetId: ref.spreadsheetId,
                range: "'\(deck.tabTitle)'!A\(rows.count + 1):A\(previousRows)",
                accessToken: token))
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
            decks.append(DeckList(name: name, text: text, tabTitle: title))
        }
        return decks
    }

    /// Flip a deck's `#built:` directive in its own tab — the Sheet is the source of
    /// truth for it, so this survives a reinstall and is editable by hand.
    ///
    /// Writes one cell rather than rewriting the tab: read column A, find the existing
    /// directive line, and overwrite it (or append past the last row if there isn't
    /// one). That keeps the decklist itself untouched and the revision history quiet.
    func setDeckBuilt(_ deck: DeckList, built: Bool) async throws {
        guard let ref = sheetRef else { throw Fail("Connect your Inventory sheet first.") }
        let token = try await self.token()
        let data = try await http.execute(GoogleSheets.readTabRequest(
            spreadsheetId: ref.spreadsheetId, title: deck.tabTitle, accessToken: token))
        let columnA = try GoogleSheets.parseValues(data).map { $0.first ?? "" }

        // 1-based A1 row: the existing directive, else one past the last used row.
        let row = (DeckDirectives.lineIndex(of: DeckDirectives.builtKey, in: columnA) ?? columnA.count) + 1
        _ = try await http.execute(GoogleSheets.writeRangeRequest(
            spreadsheetId: ref.spreadsheetId,
            range: "'\(deck.tabTitle)'!A\(row)",
            values: [[DeckDirectives.builtLine(built)]],
            accessToken: token))
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

    /// Flush an outbox batch to the Sheet: convert ops → InventoryChanges,
    /// plan against the current grid, execute. Returns the ids of ops acknowledged
    /// (all, on success — the whole batch is applied atomically enough for a single
    /// user, so a throw leaves everything queued for retry).
    func applyOutbox(_ ops: [OutboxOp]) async throws -> Set<String> {
        guard let ref = sheetRef else { throw Fail("Connect your Inventory sheet first.") }
        let changes: [InventoryChange] = ops.map { op in
            switch op.op {
            case .intake:
                let row = InventoryRow(
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

    /// Not private: `BrowserGapCheckManager` and `InventoryMigrator` reuse this
    /// connection's plain (non-`script.projects`) token rather than each holding
    /// their own `GoogleAuthService`.
    func token() async throws -> String {
        guard let auth = self.auth else { throw Fail("Enter your OAuth Client ID first.") }
        return try await auth.validAccessToken()
    }

    /// Not private: `InventoryMigrator` reads the same table shape to plan its own
    /// writes against, rather than duplicating the read + parse.
    func loadInventory(token: String? = nil) async throws -> SheetTable {
        guard let ref = sheetRef else { throw Fail("Create the Inventory sheet first.") }
        let t: String
        if let token { t = token } else { t = try await self.token() }
        let data = try await http.execute(GoogleSheets.readRequest(ref: ref, accessToken: t))
        let grid = try GoogleSheets.parseValues(data)
        guard let table = SheetTable.parse(values: grid) else { throw Fail("The sheet has no header row.") }
        return table
    }

    /// Not private: `InventoryMigrator`'s column re-derivation is itself a `Plan` of
    /// cell writes, which is exactly what this executes.
    func apply(_ plan: SyncPlanner.Plan, ref: SheetRef, layout: SheetLayout, token: String) async throws {
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
