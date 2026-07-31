import XCTest
@testable import DeckCheckCore

final class AppsScriptTests: XCTestCase {
    let token = "at-xyz"

    func json(_ spec: HTTPRequestSpec) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: spec.body ?? Data())) as? [String: Any] ?? [:]
    }

    func testCreateBoundProjectPostsTitleAndParent() {
        let req = AppsScript.createBoundProjectRequest(title: "DeckCheck gap-check",
                                                       parentSpreadsheetId: "SS1", accessToken: token)
        XCTAssertEqual(req.method, .post)
        XCTAssertEqual(req.url.absoluteString, "https://script.googleapis.com/v1/projects")
        XCTAssertEqual(req.headers["Authorization"], "Bearer at-xyz")
        let body = json(req)
        XCTAssertEqual(body["title"] as? String, "DeckCheck gap-check")
        XCTAssertEqual(body["parentId"] as? String, "SS1")
    }

    func testUpdateContentPutsFilesAtScriptId() {
        let files = AppsScript.gapCheckFiles(codeSource: "function onEdit(){}", gapcheckSource: "function f(){}")
        let req = AppsScript.updateContentRequest(scriptId: "SCRIPT9", files: files, accessToken: token)
        XCTAssertEqual(req.method, .put)
        XCTAssertEqual(req.url.absoluteString, "https://script.googleapis.com/v1/projects/SCRIPT9/content")
        let body = json(req)
        let sent = body["files"] as? [[String: Any]]
        XCTAssertEqual(sent?.count, 3)
        XCTAssertEqual(sent?.map { $0["name"] as? String }, ["appsscript", "Code", "gapcheck"])
        XCTAssertEqual(sent?.map { $0["type"] as? String }, ["JSON", "SERVER_JS", "SERVER_JS"])
    }

    func testManifestDeclaresV8AndNoScopes() throws {
        let manifest = try JSONSerialization.jsonObject(with: Data(AppsScript.manifestSource.utf8)) as? [String: Any]
        XCTAssertEqual(manifest?["runtimeVersion"] as? String, "V8")
        // Simple triggers only → no deployed OAuth scopes.
        XCTAssertNil(manifest?["oauthScopes"])
    }

    func testNeutralizedFilesHaveNoTriggers() {
        let code = AppsScript.neutralizedFiles.first { $0.name == "Code" }?.source ?? "x"
        XCTAssertFalse(code.contains("function onEdit"))
        XCTAssertFalse(code.contains("function onOpen"))
        XCTAssertEqual(AppsScript.neutralizedFiles.map(\.name), ["appsscript", "Code"])
    }

    func testParseScriptId() throws {
        let data = Data(#"{"scriptId":"ABC123","title":"t","parentId":"SS1"}"#.utf8)
        XCTAssertEqual(try AppsScript.parseScriptId(data), "ABC123")
    }

    func testParseScriptIdThrowsOnMissing() {
        XCTAssertThrowsError(try AppsScript.parseScriptId(Data(#"{"title":"t"}"#.utf8))) {
            XCTAssertEqual($0 as? AppsScriptError, .malformedResponse)
        }
    }

    // The `script.projects` scope is opt-in only — never in the onboarding scope set.
    func testScriptScopeIsIncrementalNotDefault() {
        XCTAssertFalse(OAuthConfig.requiredScopes.contains(OAuthConfig.scriptProjectsScope))
        XCTAssertTrue(OAuthConfig.scopesWithScript.contains(OAuthConfig.scriptProjectsScope))
        XCTAssertTrue(OAuthConfig.scopesWithScript.contains("https://www.googleapis.com/auth/spreadsheets"))
    }
}
