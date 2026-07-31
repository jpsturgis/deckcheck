import XCTest
@testable import DeckCheckCore

final class BoundScriptAssetsTests: XCTestCase {
    func testCodeSourceLoadsAndHasEntryPoints() throws {
        let code = try BoundScriptAssets.source("Code")
        XCTAssertTrue(code.contains("function onOpen("))
        XCTAssertTrue(code.contains("function onEdit("))       // PART 2: live recompute
        XCTAssertTrue(code.contains("function runGapCheck("))
        // The retired v1 web-app surface must NOT be deployed.
        XCTAssertFalse(code.contains("function doPost("))
        XCTAssertFalse(code.contains("function doGet("))
    }

    func testEngineSourceLoadsAndHasCheckDecklist() throws {
        let engine = try BoundScriptAssets.source("gapcheck")
        XCTAssertTrue(engine.contains("function checkDecklist("))
        XCTAssertTrue(engine.contains("function buildCatalogIndex("))
    }

    func testGapCheckFilesAssembleThreeNamedFiles() throws {
        let files = try BoundScriptAssets.gapCheckFiles()
        XCTAssertEqual(files.map(\.name), ["appsscript", "Code", "gapcheck"])
        XCTAssertFalse(files[1].source.isEmpty)
        XCTAssertFalse(files[2].source.isEmpty)
    }

    func testCatalogColumnsInCodeMatchExportHeader() throws {
        // Guard against the two schemas drifting: Code.gs CATALOG_COLUMNS lists the
        // same seven columns CatalogIndexExport.header emits.
        let code = try BoundScriptAssets.source("Code")
        for col in CatalogIndexExport.header {
            XCTAssertTrue(code.contains("\"\(col)\""), "Code.gs missing catalog column \(col)")
        }
    }

    func testMissingAssetThrows() {
        XCTAssertThrowsError(try BoundScriptAssets.source("nope")) {
            XCTAssertEqual($0 as? BoundScriptAssets.AssetError, .missing("nope.gs"))
        }
    }
}
