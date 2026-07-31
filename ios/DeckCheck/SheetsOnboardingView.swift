import SwiftUI
import DeckCheckCore

// v2 onboarding screen (spec §8.2): "Sign in with Google, we set up your Sheet."
// The inventory-connection surface reached from Settings. Paste your OAuth Client ID,
// sign in, create the Inventory sheet, and run the read / write self-tests to
// confirm the whole 2a–2c pipeline works on-device before milestone 3 wires it into
// the real intake/removal flows.

struct SheetsOnboardingView: View {
    // The shared instance AppModel owns — so the connection the app syncs through is
    // the same one you set up here.
    @EnvironmentObject private var svc: GoogleSheetsService

    var body: some View {
        Form {
            Section {
                TextField("…apps.googleusercontent.com", text: $svc.clientId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.callout.monospaced())
            } header: {
                Text("Your OAuth Client ID")
            } footer: {
                Text(svc.isConfigured
                     ? "From your own Google Cloud project — see the setup guide (docs/setup/google-oauth-client.md). No client secret is needed."
                     : "Paste your OAuth Client ID to unlock the steps below. It comes from your own Google Cloud project — see docs/setup/google-oauth-client.md. No client secret is needed.")
            }

            Section("1 · Sign in") {
                Button {
                    Task { await svc.signIn() }
                } label: {
                    Label(svc.isSignedIn ? "Re-sign in with Google" : "Sign in with Google", systemImage: "person.badge.key")
                }
                .disabled(!svc.isConfigured || svc.busy)

                if svc.isSignedIn {
                    Label("Signed in", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    Button("Sign out", role: .destructive) { svc.signOut() }
                }
            }
            .disabled(!svc.isConfigured) // whole flow is gated on the Client ID

            Section("2 · Your Inventory sheet") {
                if let url = svc.spreadsheetURL {
                    Label("Connected", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    Link("Open in Google Sheets", destination: url)
                } else {
                    Button {
                        Task { await svc.createInventorySheet() }
                    } label: {
                        Label("Create my Inventory sheet", systemImage: "plus.rectangle.on.folder")
                    }
                    .disabled(!svc.isSignedIn || svc.busy)
                }
            }
            .disabled(!svc.isConfigured)

            Section {
                Button { Task { await svc.testRead() } } label: {
                    Label("Test read", systemImage: "arrow.down.doc")
                }
                .disabled(svc.sheetRef == nil || svc.busy)

                Button { Task { await svc.testWriteRoundTrip() } } label: {
                    Label("Test write (append + delete a probe row)", systemImage: "arrow.up.arrow.down")
                }
                .disabled(svc.sheetRef == nil || svc.busy)
            } header: {
                Text("3 · Self-test")
            } footer: {
                Text("Optional. The write test adds one row then removes it — it's safe, but if you like you can point DeckCheck at a copy of your live sheet while testing.")
            }
            .disabled(!svc.isConfigured)

            if svc.busy || !svc.status.isEmpty || svc.lastError != nil {
                Section("Status") {
                    if svc.busy { HStack { ProgressView(); Text(svc.status.isEmpty ? "Working…" : svc.status) } }
                    else if let e = svc.lastError { Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                    else if !svc.status.isEmpty { Label(svc.status, systemImage: "info.circle").foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle("Inventory Sheet")
        .navigationBarTitleDisplayMode(.inline)
    }
}
