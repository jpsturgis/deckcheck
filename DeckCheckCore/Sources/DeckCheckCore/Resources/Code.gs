// ─────────────────────────────────────────────────────────────────────────────
// Code.gs — the container-bound gap-check for in-browser / app-closed checking
// (spec §7.4 PART 2). Deployed into the user's OWN sheet by the app (Apps Script
// API, `script.projects` scope) when they opt in.
//
// This is a gap-check-ONLY container-bound script: it carries no inventory-write
// surface (DeckCheck uses the Sheets API directly for that) — just the Sheet-native
// gap-check the app used to require being open for. Two simple triggers, so nothing but the container sheet is
// ever touched and no extra OAuth scope is deployed:
//   • onOpen  → adds a "DeckCheck ▸ Run gap-check" menu (manual fallback).
//   • onEdit  → re-runs the check when the decklist (column A) changes (live).
//
// Resolution uses the hidden `Catalog` tab the app pushes (the slim resolution index
// — CatalogIndexExport, 7 columns). Ownership comes from the `Inventory` tab's
// equivalence_key/qty. The diff engine is gapcheck.gs — a JS port of the pure,
// unit-tested Swift engine (GapChecker/DecklistParser/LineResolver); keep in sync.
// ─────────────────────────────────────────────────────────────────────────────

var SHEET_NAME = "Inventory";
var GAPCHECK_SHEET = "Gap Check";
var CATALOG_SHEET = "Catalog";
// MUST match CatalogIndexExport.header (DeckCheckCore).
var CATALOG_COLUMNS = ["card_id", "name", "set_name", "code", "number", "printed_total", "equivalence_key"];
// The pasted decklist lives in column A; the report is written from column C
// rightward (7 wide), so re-running never clobbers the input.
var GAPCHECK_INPUT_COL = 1; // A
var GAPCHECK_REPORT_COL = 3; // C
var GAPCHECK_REPORT_WIDTH = 7;

/** Adds the custom menu when the spreadsheet is opened (simple trigger). */
function onOpen() {
  SpreadsheetApp.getUi()
    .createMenu("DeckCheck")
    .addItem("Run gap-check", "runGapCheck")
    .addToUi();
}

/**
 * Live recompute: when the decklist (Gap Check tab, column A) is edited, re-run the
 * gap-check. A simple trigger, so it fires only on manual edits (not the app's API
 * writes) and may touch only this spreadsheet — which is all gap-check needs. Writing
 * the report into column C is a *script* edit, so it never re-triggers onEdit.
 */
function onEdit(e) {
  try {
    if (!e || !e.range) return;
    var edited = e.range.getSheet();
    if (edited.getName() !== GAPCHECK_SHEET) return;
    // React only to edits that touch column A (the decklist input), not the report.
    if (e.range.getColumn() > GAPCHECK_INPUT_COL) return;
    runGapCheck();
  } catch (err) {
    // Simple triggers can't surface a UI error; swallow so a stray edit never throws.
  }
}

/**
 * Read the pasted decklist (Gap Check tab, column A), resolve it against the Catalog
 * tab, diff against owned inventory, and write the gap-first report back to the tab
 * (highlighted, with TCGplayer links + a Mass Entry buy list).
 */
function runGapCheck() {
  var sheet = getGapCheckSheet();

  var catalogRows = readCatalogRows();
  if (catalogRows.length === 0) {
    writeGapMessage(
      sheet,
      "The Catalog tab is empty. Open the app, turn on “In-browser gap-check” in " +
        "Settings to push the catalog index, then edit the decklist again.",
    );
    return;
  }

  var text = readDecklistText(sheet);
  if (text.replace(/\s+/g, "") === "") {
    writeGapMessage(sheet, "Paste a decklist into column A (TCG Live “Copy List”), then edit to run.");
    return;
  }

  var owned = readOwnedFromInventory();
  var report = checkDecklist(text, catalogRows, owned); // gapcheck.gs
  writeGapReport(sheet, report);
}

// ── Sheet adapters ───────────────────────────────────────────────────────────

function getCatalogSheet() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(CATALOG_SHEET);
  if (!sheet) {
    sheet = ss.insertSheet(CATALOG_SHEET);
    sheet.getRange(1, 1, 1, CATALOG_COLUMNS.length).setValues([CATALOG_COLUMNS]);
    sheet.setFrozenRows(1);
  }
  return sheet;
}

function getGapCheckSheet() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(GAPCHECK_SHEET);
  if (!sheet) sheet = ss.insertSheet(GAPCHECK_SHEET);
  // (Re)assert the column-A input label so the tab is self-explanatory.
  var label = sheet.getRange(1, GAPCHECK_INPUT_COL);
  if (String(label.getValue()) === "") {
    label.setValue("Paste decklist below ↓").setFontWeight("bold");
  }
  return sheet;
}

/**
 * Read the Catalog tab into row objects keyed by header name, so column order in the
 * Sheet doesn't matter. Skips rows missing an equivalence_key.
 */
function readCatalogRows() {
  var sheet = getCatalogSheet();
  var lastRow = sheet.getLastRow();
  var lastCol = sheet.getLastColumn();
  if (lastRow < 2) return [];
  var values = sheet.getRange(1, 1, lastRow, lastCol).getValues();
  var header = values[0];
  var idx = {};
  for (var c = 0; c < header.length; c++) idx[String(header[c])] = c;
  var rows = [];
  for (var r = 1; r < values.length; r++) {
    var v = values[r];
    var key = idx.equivalence_key != null ? v[idx.equivalence_key] : "";
    if (String(key) === "") continue;
    rows.push({
      card_id: cell(v, idx.card_id),
      name: cell(v, idx.name),
      set_name: cell(v, idx.set_name),
      code: cell(v, idx.code),
      number: cell(v, idx.number),
      printed_total: cell(v, idx.printed_total),
      equivalence_key: cell(v, idx.equivalence_key),
    });
  }
  return rows;
}

/**
 * Owned copies for the diff: { card_id, equivalence_key, qty } from the Inventory
 * tab. Header-driven (finds card_id/equivalence_key/qty by name), so a hand-reordered
 * sheet still reads correctly. qty ≤ 0 rows are skipped.
 */
function readOwnedFromInventory() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(SHEET_NAME);
  if (!sheet) return [];
  var lastRow = sheet.getLastRow();
  var lastCol = sheet.getLastColumn();
  if (lastRow < 2) return [];
  var values = sheet.getRange(1, 1, lastRow, lastCol).getValues();
  var header = values[0];
  var idCol = -1, keyCol = -1, qtyCol = -1;
  for (var c = 0; c < header.length; c++) {
    var h = String(header[c]).replace(/^\s+|\s+$/g, "").toLowerCase();
    if (h === "card_id") idCol = c;
    else if (h === "equivalence_key") keyCol = c;
    else if (h === "qty") qtyCol = c;
  }
  if (keyCol < 0 || qtyCol < 0) return [];
  var owned = [];
  for (var r = 1; r < values.length; r++) {
    var v = values[r];
    var qty = Number(v[qtyCol]) || 0;
    if (qty <= 0) continue;
    owned.push({
      card_id: idCol >= 0 ? String(v[idCol]) : "",
      equivalence_key: String(v[keyCol]),
      qty: qty,
    });
  }
  return owned;
}

function cell(row, i) {
  return i == null ? "" : row[i] == null ? "" : String(row[i]);
}

// ── report rendering ─────────────────────────────────────────────────────────

var GAP_RED = "#f4cccc"; // Missing
var GAP_AMBER = "#fce5cd"; // Short
var GAP_GREEN = "#d9ead3"; // Have

/** Clear the report region (column C rightward) and reset its backgrounds. */
function clearReportRegion(sheet) {
  var maxRows = sheet.getMaxRows();
  var maxCols = sheet.getMaxColumns();
  var width = maxCols - GAPCHECK_REPORT_COL + 1;
  if (width < 1) return;
  var region = sheet.getRange(1, GAPCHECK_REPORT_COL, maxRows, width);
  region.clearContent();
  region.setBackground(null);
  region.setFontWeight("normal");
}

/** Write a single status line into the report region (empty deck / missing catalog). */
function writeGapMessage(sheet, message) {
  clearReportRegion(sheet);
  sheet.getRange(1, GAPCHECK_REPORT_COL).setValue(message).setFontWeight("bold");
}

/**
 * Render a GapReport into the tab: headline, a gap-first table (Missing red / Short
 * amber / Have green) with per-gap TCGplayer links, an unidentified-lines list, and a
 * copy-ready TCGplayer Mass Entry block. All writes are batched.
 */
function writeGapReport(sheet, report) {
  clearReportRegion(sheet);

  var rows = []; // 2D values, width GAPCHECK_REPORT_WIDTH
  var backgrounds = []; // matching 2D backgrounds
  var W = GAPCHECK_REPORT_WIDTH;
  function push(cells, bg) {
    var row = cells.slice();
    while (row.length < W) row.push("");
    rows.push(row);
    var b = [];
    for (var i = 0; i < W; i++) b.push(bg || null);
    backgrounds.push(b);
  }

  // headline
  var groupsMissing = missingEntries(report).length;
  var groupsShort = shortEntries(report).length;
  var headline =
    "Buildable " + report.buildableQty + "/" + report.deckTotal +
    " · " + report.shortTotal + " short" +
    " · " + groupsMissing + " missing, " + groupsShort + " short " +
    (groupsMissing + groupsShort === 1 ? "group" : "groups");
  push([headline], null);
  push([""], null);

  // table
  push(["Status", "Need", "Have", "Short", "Card", "Set", "TCGplayer"], null);
  for (var i = 0; i < report.entries.length; i++) {
    var e = report.entries[i];
    var statusLabel =
      e.status === "missing" ? "❌ Missing" :
      e.status === "short" ? "⚠️ Short" :
      "✅ Have" + (e.differentPrinting ? " 🔁" : "");
    var bg = e.status === "missing" ? GAP_RED : e.status === "short" ? GAP_AMBER : GAP_GREEN;
    var link = "";
    if (e.status !== "have") {
      var url = tcgplayerSearchUrl(e.representative.name, e.representative.set_name, e.representative.number);
      if (url) link = '=HYPERLINK("' + url + '","TCGplayer")';
    }
    push([statusLabel, e.requiredQty, e.ownedQty, e.shortQty, e.name, e.representative.set_name, link], bg);
  }

  // unidentified lines
  if (report.unidentified.length > 0) {
    push([""], null);
    push(["❓ Unidentified lines (excluded from buildable):"], null);
    for (var u = 0; u < report.unidentified.length; u++) {
      push([report.unidentified[u].raw], null);
    }
  }

  // basic energy note
  if (report.basicEnergyQty > 0) {
    push([""], null);
    push(["🔋 Basic Energy auto-satisfied: " + report.basicEnergyQty], null);
  }

  // Mass Entry buy list (one cell, copy-ready)
  var buyList = massEntry(report);
  push([""], null);
  push(["TCGplayer Mass Entry (copy the cell below):"], null);
  push([buyList === "" ? "(nothing to buy — deck is buildable)" : buyList], null);

  // batch write
  var range = sheet.getRange(1, GAPCHECK_REPORT_COL, rows.length, W);
  range.setValues(rows);
  range.setBackgrounds(backgrounds);
  // bold the headline + table header rows
  sheet.getRange(1, GAPCHECK_REPORT_COL, 1, W).setFontWeight("bold");
  sheet.getRange(3, GAPCHECK_REPORT_COL, 1, W).setFontWeight("bold");
}

// ── read the pasted decklist from column A ───────────────────────────────────

function readDecklistText(sheet) {
  var lastRow = sheet.getLastRow();
  if (lastRow < 2) return "";
  // Row 1 col A is the input label; the decklist starts at row 2.
  var values = sheet.getRange(2, GAPCHECK_INPUT_COL, lastRow - 1, 1).getValues();
  var lines = [];
  for (var i = 0; i < values.length; i++) lines.push(String(values[i][0]));
  return lines.join("\n");
}
