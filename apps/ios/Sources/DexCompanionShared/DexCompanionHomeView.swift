import SwiftUI

struct DexCompanionHomeView: View {
    @State private var savedSessions: [DexCompanionSavedSession] = DexCompanionSessionStore.load()
    @State private var activeSession: DexCompanionBrowserSession?
    @State private var showScanner = false
    @State private var errorMessage: String?
    @State private var pendingDeleteSession: DexCompanionSavedSession?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan Dex Companion QR", systemImage: "qrcode.viewfinder")
                    }
                    .accessibilityIdentifier("dexCompanion.scanQrButton")
                }

                Section("Saved Companions") {
                    if savedSessions.isEmpty {
                        Text("No saved Dex companions yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(savedSessions) { session in
                            Button {
                                open(session)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.serverLabel)
                                        .font(.headline)
                                    Text(session.httpBaseUrl)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityIdentifier("dexCompanion.savedSession.\(session.environmentId)")
                            .contextMenu {
                                Button(role: .destructive) {
                                    pendingDeleteSession = session
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Dex Companion")
        }
        .sheet(isPresented: $showScanner) {
            DexCompanionScannerView(
                onScan: { payload in
                    Task {
                        await handle(payload)
                        showScanner = false
                    }
                },
                onClose: { showScanner = false }
            )
        }
        .sheet(item: $activeSession) { session in
            DexCompanionWebScreen(session: session)
        }
        .alert("Dex Companion Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .alert("Remove Companion", isPresented: Binding(
            get: { pendingDeleteSession != nil },
            set: { if !$0 { pendingDeleteSession = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingDeleteSession = nil }
            Button("Delete", role: .destructive) {
                if let session = pendingDeleteSession {
                    DexCompanionSessionStore.remove(environmentId: session.environmentId)
                    savedSessions = DexCompanionSessionStore.load()
                }
                pendingDeleteSession = nil
            }
        } message: {
            Text("Remove this saved Dex companion session from your iPhone?")
        }
    }

    @MainActor
    private func handle(_ payload: DexCompanionPairingPayload) async {
        do {
            let paired = try await DexCompanionPairingClient().redeem(payload)
            DexCompanionSessionStore.upsert(from: paired)
            savedSessions = DexCompanionSessionStore.load()
            activeSession = paired
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func open(_ saved: DexCompanionSavedSession) {
        guard let session = saved.makeBrowserSession() else {
            errorMessage = "This companion session no longer has a valid Dex token. Pair again from desktop."
            DexCompanionSessionStore.remove(environmentId: saved.environmentId)
            savedSessions = DexCompanionSessionStore.load()
            return
        }
        activeSession = session
    }
}
