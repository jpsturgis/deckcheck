import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var catalog: Catalog
    @EnvironmentObject var inventory: InventoryStore
    @EnvironmentObject var outbox: Outbox
    @EnvironmentObject var sheets: GoogleSheetsService

    @State private var syncing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        SheetsOnboardingView()
                    } label: {
                        Label("Inventory Sheet", systemImage: "tablecells")
                    }
                } footer: {
                    Text("Connect the Google Sheet that stores your inventory — sign in with Google; the app sets up your Sheet.")
                }

                Section("Status") {
                    LabeledContent("Catalog", value: catalog.status)
                    LabeledContent("Inventory rows", value: "\(inventory.rows.count)")
                    LabeledContent("Pending sync", value: "\(outbox.count)")
                    if let synced = inventory.lastSyncedAt {
                        LabeledContent("Last synced", value: synced.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let e = outbox.lastError ?? inventory.lastError {
                        LabeledContent("Last error", value: e).foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        syncing = true
                        Task { await model.syncNow(); syncing = false }
                    } label: {
                        HStack {
                            Text("Sync now")
                            if syncing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(!model.canSync || syncing)
                } footer: {
                    Text("Flushes the outbox, then refreshes the read-cache from your Sheet.")
                }

                if sheets.sheetRef != nil {
                    Section {
                        Button {
                            Task {
                                await sheets.migrateDerivedColumns(catalog: catalog.lookup,
                                                                   normVersion: catalog.normVersion)
                                await model.syncNow()
                            }
                        } label: {
                            HStack {
                                Label("Re-check card grouping", systemImage: "arrow.triangle.merge")
                                if sheets.busy { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(sheets.busy || !catalog.isLoaded)
                    } header: {
                        Text("Card grouping")
                    } footer: {
                        Text("Your Sheet stores which cards count as copies of each other. Rows written by an older version — or by poke-check, which left the version blank — can be grouped by an out-of-date rule, so a card you own reads as missing in a gap-check. This re-derives that from the current catalog. It only touches the two machine columns, and it's safe to run any time.")
                    }

                    Section {
                        if sheets.browserGapCheckEnabled {
                            Button {
                                Task { await sheets.refreshCatalogIndex(catalog: catalog.lookup) }
                            } label: {
                                Label("Refresh catalog index", systemImage: "arrow.clockwise")
                            }
                            .disabled(sheets.busy || !catalog.isLoaded)
                            Button(role: .destructive) {
                                Task { await sheets.disableBrowserGapCheck() }
                            } label: {
                                Label("Turn off in-browser gap-check", systemImage: "xmark.circle")
                            }
                            .disabled(sheets.busy)
                        } else {
                            Button {
                                Task { await sheets.enableBrowserGapCheck(catalog: catalog.lookup) }
                            } label: {
                                HStack {
                                    Label("Enable in-browser gap-check", systemImage: "globe")
                                    if sheets.busy { Spacer(); ProgressView() }
                                }
                            }
                            .disabled(sheets.busy || !catalog.isLoaded)
                        }
                        if !sheets.status.isEmpty {
                            Text(sheets.status).font(.footnote).foregroundStyle(.secondary)
                        }
                        if let e = sheets.lastError {
                            Text(e).font(.footnote).foregroundStyle(.red)
                        }
                    } header: {
                        Text("In-browser gap-check")
                    } footer: {
                        Text("Optional. Deploys a small Apps Script into your own Sheet so a decklist gap-check runs in the browser with the app closed — edit column A of the Gap Check tab and the report updates itself. Turning it on asks for the Apps Script permission and adds a hidden Catalog tab. See docs/setup/browser-gap-check.md.")
                    }
                }

                if outbox.count > 0 {
                    Section {
                        Button(role: .destructive) { outbox.clear() } label: {
                            Text("Clear pending (\(outbox.count))")
                        }
                    } footer: {
                        Text("Discards queued writes without sending them. Use to recover if a sync got stuck.")
                    }
                }
            }
            .navigationTitle("Settings")
            .scrollDismissesKeyboard(.interactively)
            .keyboardDoneButton()
        }
    }
}
