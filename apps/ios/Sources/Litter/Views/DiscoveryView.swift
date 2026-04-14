import SwiftUI
import Network

struct DiscoveryView: View {
    var onServerSelected: ((DiscoveredServer) -> Void)?
    @Environment(AppModel.self) private var appModel
    @State private var discovery: NetworkDiscovery
    @State private var sshServer: DiscoveredServer?
    @State private var connectionChoiceServer: DiscoveredServer?
    @State private var pendingSSHServer: DiscoveredServer?
    @State private var showManualEntry = false
    @State private var manualConnectionMode: ManualConnectionMode = .ssh
    @State private var manualCodexURL = ""
    @State private var manualHost = ""
    @State private var manualSSHPort = "22"
    @State private var manualWakeMAC = ""
    @State private var autoSSHStarted = false
    @State private var connectingServer: DiscoveredServer?
    @State private var wakingServer: DiscoveredServer?
    @State private var pendingAutoNavigateServerId: String?
    @State private var pendingAutoNavigateServer: DiscoveredServer?
    @State private var connectError: String?
    @State private var renameTarget: DiscoveredServer?
    @State private var renameText = ""
    @State private var pairingTarget: DiscoveredServer?
    @State private var pairingCode = ""
    @State private var pairingSuccessMessage: String?
    @State private var manualPairingHost = ""
    @State private var manualPairingCode = ""
    @State private var showManualPairingAlert = false
    @State private var showQRPairingSheet = false
    @State private var showDexCompanionSheet = false
    @State private var activeDexCompanionSession: DexCompanionBrowserSession?
    @Environment(AppState.self) private var appState
    private let autoStartDiscovery: Bool
    private let initialServers: [DiscoveredServer]
    private let macPairingClient = MacPairingClient()

    init(
        onServerSelected: ((DiscoveredServer) -> Void)? = nil,
        discovery: NetworkDiscovery? = nil,
        autoStartDiscovery: Bool = true,
        initialServers: [DiscoveredServer] = []
    ) {
        self.onServerSelected = onServerSelected
        _discovery = State(initialValue: discovery ?? NetworkDiscovery())
        self.autoStartDiscovery = autoStartDiscovery
        self.initialServers = initialServers
    }

    private var localServers: [DiscoveredServer] {
        discovery.servers.filter { $0.source == .local }
    }

    private var pairableMacBridges: [DiscoveredServer] {
        discovery.servers.filter(\.isPairableMacBridge)
    }

    private var networkServers: [DiscoveredServer] {
        discovery.servers.filter { $0.source != .local && !$0.isPairableMacBridge }
    }

    private func applyInitialServersIfNeeded() {
        guard !initialServers.isEmpty, discovery.servers.isEmpty else { return }
        discovery.servers = initialServers
        discovery.isScanning = false
    }

    private func refreshDiscovery() {
        guard autoStartDiscovery else {
            applyInitialServersIfNeeded()
            return
        }
        discovery.startScanning()
    }

    private func handleAppear() {
        refreshDiscovery()
        guard autoStartDiscovery else { return }
        maybeStartSimulatorAutoSSH()
    }

    private func handleDisappear() {
        guard autoStartDiscovery else { return }
        discovery.stopScanning()
    }

    @MainActor
    private func handleScannedPairingPayload(_ payload: ScannedPairingPayload) async {
        switch payload {
        case .dexCompanion(let dexPayload):
            await pairWithDexCompanionPayload(dexPayload)
        case .macBridge(let macPayload):
            await pairWithPayload(macPayload, displayName: "Litter Mac", host: nil, localPairingMode: "qr")
        }
    }

    @MainActor
    private func pairWithDexCompanionPayload(_ payload: DexCompanionPairingPayload) async {
        do {
            let session = try await DexCompanionPairingClient().redeem(payload)
            DexCompanionSessionStore.upsert(from: session)
            activeDexCompanionSession = session
        } catch {
            connectError = error.localizedDescription
        }
    }

    var body: some View {
        discoveryRoot
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { discoveryToolbar }
            .onAppear { handleAppear() }
            .onDisappear { handleDisappear() }
            .sheet(item: $sshServer) { server in
                SSHLoginSheet(server: server) { target in
                    sshServer = nil
                    Task { await connectToServer(server, targetOverride: target) }
                }
            }
            .confirmationDialog(
                connectionChoiceServer.map { "Connect to \($0.name)" } ?? "Choose Connection",
                isPresented: connectionChoicePresented,
                titleVisibility: .visible
            ) {
                connectionChoiceActions
            } message: {
                if let server = connectionChoiceServer {
                    Text(connectionChoiceMessage(for: server))
                }
            }
            .sheet(isPresented: $showManualEntry) {
                manualEntrySheet
            }
            .sheet(isPresented: $showQRPairingSheet) {
                MacPairingScannerView(
                    onScan: { payload in
                        Task {
                            await handleScannedPairingPayload(payload)
                            showQRPairingSheet = false
                        }
                    },
                    onClose: { showQRPairingSheet = false }
                )
            }
            .sheet(isPresented: $showDexCompanionSheet) {
                DexCompanionHomeView()
            }
            .sheet(item: $activeDexCompanionSession) { session in
                DexCompanionWebScreen(session: session)
            }
            .onChange(of: showManualEntry) { _, isPresented in
                guard !isPresented, let pendingSSHServer else { return }
                self.pendingSSHServer = nil
                self.sshServer = pendingSSHServer
            }
            .onChange(of: appModel.snapshot) { _, _ in
                handleSnapshotChange()
            }
            .alert("Connection Failed", isPresented: showConnectError, actions: {
                Button("OK") { connectError = nil }
            }, message: {
                Text(connectError ?? "Unable to connect.")
            })
            .alert("Pair with Mac", isPresented: pairingAlertPresented) {
                pairingAlertActions
            } message: {
                Text("Enter the pairing code shown on your Mac.")
            }
            .alert("Mac Paired", isPresented: pairingSuccessPresented) {
                Button("OK", role: .cancel) { pairingSuccessMessage = nil }
            } message: {
                Text(pairingSuccessMessage ?? "")
            }
            .alert("Pair With Mac Code", isPresented: $showManualPairingAlert) {
                TextField("Mac IP or hostname", text: $manualPairingHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                TextField("Pairing code", text: $manualPairingCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled(true)
                Button("Cancel", role: .cancel) {
                    manualPairingHost = ""
                    manualPairingCode = ""
                }
                Button("Pair") {
                    Task { await pairWithMacCodeManually() }
                }
            } message: {
                Text("Enter your Mac's local IP/hostname and the pairing code from the bridge.")
            }
            .alert("Rename Server", isPresented: renameAlertPresented) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                if let server = renameTarget {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let newName = trimmed.isEmpty ? server.hostname : trimmed
                    SavedServerStore.upsert(DiscoveredServer(
                        id: server.id,
                        name: newName,
                        hostname: server.hostname,
                        port: server.port,
                        codexPorts: server.codexPorts,
                        sshPort: server.sshPort,
                        source: server.source,
                        hasCodexServer: server.hasCodexServer,
                        wakeMAC: server.wakeMAC,
                        preferredConnectionMode: server.preferredConnectionMode,
                        preferredCodexPort: server.preferredCodexPort,
                        os: server.os,
                        sshBanner: server.sshBanner,
                        metadata: server.metadata
                    ))
                    if let idx = discovery.servers.firstIndex(where: { $0.id == server.id }) {
                        discovery.servers[idx] = DiscoveredServer(
                            id: server.id,
                            name: newName,
                            hostname: server.hostname,
                            port: server.port,
                            codexPorts: server.codexPorts,
                            sshPort: server.sshPort,
                            source: server.source,
                            hasCodexServer: server.hasCodexServer,
                            wakeMAC: server.wakeMAC,
                            preferredConnectionMode: server.preferredConnectionMode,
                            preferredCodexPort: server.preferredCodexPort,
                            os: server.os,
                            sshBanner: server.sshBanner,
                            metadata: server.metadata
                        )
                    }
                }
                renameTarget = nil
            }
        } message: {
            Text("Enter a new name for this server.")
        }
        .alert(
            "Install Codex?",
            isPresented: pendingInstallPresented,
            presenting: pendingInstallServerSnapshot
        ) { snapshot in
            Button("Install") {
                Task {
                    LLog.trace(
                        "discovery",
                        "responding to install prompt",
                        fields: [
                            "serverId": snapshot.serverId,
                            "install": true,
                            "detail": snapshot.connectionProgressDetail ?? ""
                        ]
                    )
                    _ = try? await appModel.ssh.sshRespondToInstallPrompt(
                        serverId: snapshot.serverId,
                        install: true
                    )
                }
            }
            Button("Cancel", role: .cancel) {
                Task {
                    LLog.trace(
                        "discovery",
                        "responding to install prompt",
                        fields: [
                            "serverId": snapshot.serverId,
                            "install": false,
                            "detail": snapshot.connectionProgressDetail ?? ""
                        ]
                    )
                    _ = try? await appModel.ssh.sshRespondToInstallPrompt(
                        serverId: snapshot.serverId,
                        install: false
                    )
                }
            }
        } message: { snapshot in
            Text(snapshot.connectionProgressDetail ?? "Codex was not found on the remote host. Install the latest stable release into ~/.litter?")
        }
    }

    private var discoveryRoot: some View {
        ZStack {
            LitterTheme.backgroundGradient.ignoresSafeArea()
            List {
                macPairingSection
                serversSection
                manualSection
            }
            .scrollContentBackground(.hidden)
            .refreshable { refreshDiscovery() }
            .accessibilityIdentifier("discovery.list")
        }
    }

    @ToolbarContentBuilder
    private var discoveryToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { appState.showSettings = true } label: {
                Image(systemName: "gearshape")
                    .foregroundColor(LitterTheme.textSecondary)
            }
        }
        ToolbarItem(placement: .principal) {
            BrandLogo(size: 44)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                refreshDiscovery()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .foregroundColor(LitterTheme.accent)
            }
            .accessibilityIdentifier("discovery.refreshButton")
            .disabled(discovery.isScanning)
        }
    }

    @ViewBuilder
    private var connectionChoiceActions: some View {
        if let server = connectionChoiceServer {
            ForEach(server.availableDirectCodexPorts, id: \.self) { port in
                Button("Use Codex (\(port))") {
                    let preferredServer = server.withConnectionPreference(.directCodex, codexPort: port)
                    connectionChoiceServer = nil
                    Task { await connectToServer(preferredServer) }
                }
            }
            if server.canConnectViaSSH {
                Button("Connect via SSH") {
                    let preferredServer = server.withConnectionPreference(.ssh)
                    connectionChoiceServer = nil
                    sshServer = preferredServer
                }
            }
        }
        Button("Cancel", role: .cancel) {
            connectionChoiceServer = nil
        }
    }

    private var pairingAlertPresented: Binding<Bool> {
        Binding(
            get: { pairingTarget != nil },
            set: { if !$0 { pairingTarget = nil } }
        )
    }

    @ViewBuilder
    private var pairingAlertActions: some View {
        TextField("Pairing code", text: $pairingCode)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled(true)
        Button("Cancel", role: .cancel) {
            pairingTarget = nil
            pairingCode = ""
        }
        Button("Pair") {
            guard let server = pairingTarget else { return }
            Task {
                await requestPairingPayload(for: server, code: pairingCode)
                pairingTarget = nil
                pairingCode = ""
            }
        }
    }

    private var pairingSuccessPresented: Binding<Bool> {
        Binding(
            get: { pairingSuccessMessage != nil },
            set: { if !$0 { pairingSuccessMessage = nil } }
        )
    }

    private var renameAlertPresented: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }

    private func handleSnapshotChange() {
        guard let pendingAutoNavigateServerId else { return }
        guard let serverSnapshot = appModel.snapshot?.serverSnapshot(for: pendingAutoNavigateServerId) else {
            return
        }
        if serverSnapshot.health == .connected {
            self.pendingAutoNavigateServerId = nil
            if let server = pendingAutoNavigateServer
                ?? discovery.servers.first(where: { $0.id == pendingAutoNavigateServerId }) {
                self.pendingAutoNavigateServer = nil
                navigateAfterConnect(server)
            }
        } else if serverSnapshot.health == .disconnected,
                  let message = serverSnapshot.connectionProgress?.terminalMessage {
            self.pendingAutoNavigateServerId = nil
            self.pendingAutoNavigateServer = nil
            connectError = message
        }
    }

    // MARK: - Sections

    private var allServers: [DiscoveredServer] {
        localServers + networkServers
    }

    private var macPairingSection: some View {
        Group {
            if !pairableMacBridges.isEmpty {
                Section {
                    ForEach(pairableMacBridges) { server in
                        Button {
                            Task { await startMacPairing(for: server) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "laptopcomputer")
                                    .foregroundColor(LitterTheme.accent)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.name)
                                        .litterFont(.subheadline)
                                        .foregroundColor(LitterTheme.textPrimary)
                                    Text(macPairingSubtitle(for: server))
                                        .litterFont(.caption)
                                        .foregroundColor(LitterTheme.textSecondary)
                                }
                                Spacer()
                                Text("Pair")
                                    .litterFont(.caption2)
                                    .foregroundColor(LitterTheme.accent)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(LitterTheme.accent.opacity(0.14))
                                    .clipShape(Capsule())
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(connectingServer != nil || wakingServer != nil)
                    }
                } header: {
                    Text("Nearby Macs")
                        .foregroundColor(LitterTheme.textSecondary)
                }
                .listRowBackground(LitterTheme.surface.opacity(0.6))
            }
        }
    }

    private var serversSection: some View {
        Section {
            if allServers.isEmpty {
                if discovery.isInitialLoad {
                    HStack {
                        ProgressView().tint(LitterTheme.textMuted).scaleEffect(0.7)
                        Text("Scanning...")
                            .litterFont(.footnote)
                            .foregroundColor(LitterTheme.textMuted)
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No servers found")
                            .litterFont(.footnote)
                            .foregroundColor(LitterTheme.textMuted)
                        if discovery.isScanning {
                            Text("Still searching network...")
                                .litterFont(.caption)
                                .foregroundColor(LitterTheme.textSecondary)
                        }
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))
                }
            } else {
                ForEach(allServers) { server in
                    serverRow(server)
                }
            }

            if let notice = discovery.tailscaleDiscoveryNotice {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "network.slash")
                        .foregroundColor(LitterTheme.textSecondary)
                        .frame(width: 18, alignment: .top)
                    Text(notice)
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.textSecondary)
                }
                .listRowBackground(LitterTheme.surface.opacity(0.6))
            }
        } header: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Servers")
                        .foregroundColor(LitterTheme.textSecondary)
                    Spacer()
                    if discovery.isScanning, let label = discovery.scanProgressLabel {
                        Text(label)
                            .litterFont(.caption2)
                            .foregroundColor(LitterTheme.textMuted)
                    }
                }
                if discovery.isScanning {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(LitterTheme.surface)
                                .frame(height: 3)
                            Capsule()
                                .fill(LitterTheme.accent)
                                .frame(
                                    width: geo.size.width * CGFloat(discovery.scanProgress),
                                    height: 3
                                )
                                .animation(.easeInOut(duration: 0.25), value: discovery.scanProgress)
                        }
                    }
                    .frame(height: 3)
                }
            }
        }
        .listRowBackground(LitterTheme.surface.opacity(0.6))
    }

    private var manualSection: some View {
        Section {
            Button {
                showDexCompanionSheet = true
            } label: {
                HStack {
                    Image(systemName: "iphone.gen3.badge.waveform")
                        .foregroundColor(LitterTheme.accent)
                    Text("Open Dex Companion")
                        .litterFont(.subheadline)
                        .foregroundColor(LitterTheme.accent)
                }
            }
            .accessibilityIdentifier("discovery.openDexCompanionButton")
            .listRowBackground(LitterTheme.surface.opacity(0.6))

            Button {
                showQRPairingSheet = true
            } label: {
                HStack {
                    Image(systemName: "qrcode.viewfinder")
                        .foregroundColor(LitterTheme.accent)
                    Text("Scan Mac QR")
                        .litterFont(.subheadline)
                        .foregroundColor(LitterTheme.accent)
                }
            }
            .listRowBackground(LitterTheme.surface.opacity(0.6))

            Button {
                showManualPairingAlert = true
            } label: {
                HStack {
                    Image(systemName: "link.badge.plus")
                        .foregroundColor(LitterTheme.accent)
                    Text("Pair With Mac Code")
                        .litterFont(.subheadline)
                        .foregroundColor(LitterTheme.accent)
                }
            }
            .listRowBackground(LitterTheme.surface.opacity(0.6))

            Button {
                manualConnectionMode = .ssh
                showManualEntry = true
            } label: {
                HStack {
                    Image(systemName: "plus.circle")
                        .foregroundColor(LitterTheme.accent)
                    Text("Add Server")
                        .litterFont(.subheadline)
                        .foregroundColor(LitterTheme.accent)
                }
            }
            .accessibilityIdentifier("discovery.addServerButton")
            .listRowBackground(LitterTheme.surface.opacity(0.6))
        }
    }

    // MARK: - Row

    private func serverRow(_ server: DiscoveredServer) -> some View {
        let rowIdentifier = serverRowAccessibilityIdentifier(for: server)
        let serverSnapshot = appModel.snapshot?.servers.first(where: { $0.serverId == server.id })
        return Button {
            handleTap(server)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: serverIconName(for: server))
                    .foregroundColor(server.hasCodexServer ? LitterTheme.accent : LitterTheme.textSecondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .litterFont(.subheadline)
                        .foregroundColor(LitterTheme.textPrimary)
                    Text(serverSubtitle(server))
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.textSecondary)
                }
                Spacer()
                if serverSnapshot?.isIpcConnected == true, ExperimentalFeatures.shared.isEnabled(.ipc) {
                    statusTag(label: "ipc", color: LitterTheme.accentStrong)
                }
                if let progressTag = progressTag(for: serverSnapshot) {
                    statusTag(label: progressTag.label, color: progressTag.color)
                } else if let health = serverSnapshot?.health,
                          health != .disconnected {
                    statusTag(label: health.displayLabel.lowercased(), color: health.accentColor)
                } else if connectingServer?.id == server.id {
                    ProgressView().controlSize(.small).tint(LitterTheme.accent)
                } else if wakingServer?.id == server.id {
                    ProgressView().controlSize(.small).tint(LitterTheme.accent)
                } else {
                    Image(systemName: "chevron.right")
                        .foregroundColor(LitterTheme.textMuted)
                        .font(.caption)
                }
            }
        }
        .accessibilityIdentifier(rowIdentifier)
        .disabled(connectingServer != nil || wakingServer != nil)
        .contextMenu {
            if server.source != .local {
                Button {
                    renameText = server.name
                    renameTarget = server
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            }
        }
    }

    private func serverRowAccessibilityIdentifier(for server: DiscoveredServer) -> String {
        let kind = server.hasCodexServer ? "codex" : "ssh"
        let host = server.hostname
            .lowercased()
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return "discovery.server.\(kind).\(host)"
    }

    private func serverSubtitle(_ server: DiscoveredServer) -> String {
        if server.source == .local { return "This iPhone" }
        if server.isPairableMacBridge {
            return macPairingSubtitle(for: server)
        }
        let snapshot = connectedSnapshot(for: server)
        if let progressDetail = snapshot?.connectionProgressDetail,
           !progressDetail.isEmpty {
            return progressDetail
        }
        if !DebugSettings.shared.enabled {
            if server.hasCodexServer {
                if let os = server.os, !os.isEmpty {
                    return "\(os) ready to connect"
                }
                return "Ready to connect"
            }
            if server.canConnectViaSSH {
                return "Can be set up over SSH"
            }
            return "Available on this network"
        }
        let displayHost = snapshot?.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? snapshot!.host
            : server.hostname
        var parts = [displayHost]
        if let os = server.os {
            parts.append(" - \(os)")
        }
        let directPorts = server.availableDirectCodexPorts.map(String.init)
        if !directPorts.isEmpty {
            parts.append(" - codex \(directPorts.joined(separator: ", "))")
        }
        if server.canConnectViaSSH {
            parts.append(" - ssh \(server.resolvedSSHPort)")
        }
        if snapshot?.isIpcConnected == true, ExperimentalFeatures.shared.isEnabled(.ipc) {
            parts.append(" - ipc")
        }
        return parts.joined()
    }

    private func macPairingSubtitle(for server: DiscoveredServer) -> String {
        let mode = server.metadata["pairing_mode"] ?? "code"
        return mode == "auto" ? "Tap to pair" : "Requires code"
    }

    @ViewBuilder
    private func statusTag(label: String, color: Color) -> some View {
        Text(label)
            .litterFont(.caption2)
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .cornerRadius(4)
    }

    private func connectedSnapshot(for server: DiscoveredServer) -> AppServerSnapshot? {
        appModel.snapshot?.servers.first(where: { $0.serverId == server.id && !$0.isLocal })
    }

    // MARK: - Actions

    private func handleTap(_ server: DiscoveredServer) {
        Task { await handleTapAsync(server) }
    }

    private func navigateAfterConnect(_ server: DiscoveredServer) {
        guard let snapshot = appModel.snapshot?.servers.first(where: { $0.serverId == server.id }) else {
            onServerSelected?(server)
            return
        }
        if snapshot.isLocal, snapshot.account == nil {
            appState.showSettings = true
            return
        }
        onServerSelected?(server)
    }

    @MainActor
    private func handleTapAsync(_ server: DiscoveredServer) async {
        if server.isPairableMacBridge {
            await startMacPairing(for: server)
            return
        }
        if appModel.snapshot?.servers.first(where: { $0.serverId == server.id })?.health == .connected {
            navigateAfterConnect(server)
            return
        }

        let prepared = await prepareServerForSelection(server)
        if prepared.server.requiresConnectionChoice {
            connectionChoiceServer = prepared.server
        } else if prepared.server.hasCodexServer, prepared.server.connectionTarget != nil {
            await connectToServer(prepared.server)
        } else if prepared.canAttemptSSH {
            sshServer = prepared.server.withConnectionPreference(.ssh)
        } else {
            connectError = "Server did not respond after wake attempt. Enable Wake for network access on the Mac."
        }
    }

    private func prepareServerForSelection(_ server: DiscoveredServer) async -> (server: DiscoveredServer, canAttemptSSH: Bool) {
        guard server.source != .local else {
            return (server, true)
        }
        guard !server.isPairableMacBridge else {
            return (server, false)
        }

        wakingServer = server
        defer { wakingServer = nil }

        let wakeResult = await waitForWakeSignal(
            host: server.hostname,
            preferredCodexPort: server.hasCodexServer ? server.port : nil,
            preferredSSHPort: server.sshPort,
            timeout: server.hasCodexServer ? 12.0 : 18.0,
            wakeMAC: server.wakeMAC
        )

        switch wakeResult {
        case .codex(let port):
            return (
                DiscoveredServer(
                    id: server.id,
                    name: server.name,
                    hostname: server.hostname,
                    port: port,
                    codexPorts: [port] + server.codexPorts.filter { $0 != port },
                    sshPort: server.sshPort,
                    source: server.source,
                    hasCodexServer: true,
                    wakeMAC: server.wakeMAC,
                    sshPortForwardingEnabled: server.sshPortForwardingEnabled,
                    preferredConnectionMode: server.preferredConnectionMode,
                    preferredCodexPort: port,
                    metadata: server.metadata
                ),
                true
            )
        case .ssh(let sshPort):
            return (
                DiscoveredServer(
                    id: server.id,
                    name: server.name,
                    hostname: server.hostname,
                    port: nil,
                    codexPorts: server.codexPorts,
                    sshPort: sshPort,
                    source: server.source,
                    hasCodexServer: false,
                    wakeMAC: server.wakeMAC,
                    sshPortForwardingEnabled: server.sshPortForwardingEnabled,
                    preferredConnectionMode: .ssh,
                    metadata: server.metadata
                ),
                true
            )
        case .none:
            // Don't hard-block when wake probing is inconclusive; continue with
            // normal connect/SSH flow so users can still attempt recovery.
            return (server, true)
        }
    }

    private enum WakeSignalResult {
        case codex(UInt16)
        case ssh(UInt16)
        case none
    }

    private func waitForWakeSignal(
        host: String,
        preferredCodexPort: UInt16?,
        preferredSSHPort: UInt16?,
        timeout: TimeInterval,
        wakeMAC: String?
    ) async -> WakeSignalResult {
        let codexPorts = orderedCodexPorts(preferred: preferredCodexPort)
        let sshPorts = orderedSSHPorts(preferred: preferredSSHPort)
        let deadline = Date().addingTimeInterval(max(timeout, 0.5))
        var lastWakePacketAt = Date.distantPast

        while Date() < deadline {
            if let wakeMAC, Date().timeIntervalSince(lastWakePacketAt) >= 2.0 {
                sendWakeMagicPacket(to: wakeMAC, hostHint: host)
                lastWakePacketAt = Date()
            }

            for port in codexPorts {
                if await isPortOpen(host: host, port: port, timeout: 0.7) {
                    return .codex(port)
                }
            }

            for port in sshPorts {
                if await isPortOpen(host: host, port: port, timeout: 0.7) {
                    return .ssh(port)
                }
            }

            try? await Task.sleep(for: .milliseconds(350))
        }

        return .none
    }

    private func orderedCodexPorts(preferred: UInt16?) -> [UInt16] {
        var ports = [UInt16]()
        if let preferred {
            ports.append(preferred)
        }
        ports.append(contentsOf: [8390, 9234, 4222])

        var seen = Set<UInt16>()
        return ports.filter { seen.insert($0).inserted }
    }

    private func orderedSSHPorts(preferred: UInt16?) -> [UInt16] {
        var ports = [UInt16]()
        if let preferred {
            ports.append(preferred)
        }
        ports.append(22)

        var seen = Set<UInt16>()
        return ports.filter { seen.insert($0).inserted }
    }

    private func sendWakeMagicPacket(to wakeMAC: String, hostHint: String) {
        guard let macBytes = macBytes(from: wakeMAC) else { return }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 {
            packet.append(contentsOf: macBytes)
        }

        let targets = wakeBroadcastTargets(for: hostHint)
        for target in targets {
            sendBroadcastUDP(packet: packet, host: target, port: 9)
            sendBroadcastUDP(packet: packet, host: target, port: 7)
        }
    }

    private func macBytes(from normalizedMAC: String) -> [UInt8]? {
        let compact = normalizedMAC.replacingOccurrences(of: ":", with: "")
        guard compact.count == 12 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(6)
        var index = compact.startIndex
        for _ in 0..<6 {
            let next = compact.index(index, offsetBy: 2)
            let chunk = compact[index..<next]
            guard let byte = UInt8(chunk, radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private func wakeBroadcastTargets(for host: String) -> [String] {
        var targets = ["255.255.255.255"]
        let parts = host.split(separator: ".")
        if parts.count == 4,
           let _ = Int(parts[0]),
           let _ = Int(parts[1]),
           let _ = Int(parts[2]),
           let _ = Int(parts[3]) {
            targets.append("\(parts[0]).\(parts[1]).\(parts[2]).255")
        }
        return Array(Set(targets))
    }

    private func sendBroadcastUDP(packet: Data, host: String, port: UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var enabled: Int32 = 1
        withUnsafePointer(to: &enabled) { enabledPtr in
            _ = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, enabledPtr, socklen_t(MemoryLayout<Int32>.size))
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(port)
        host.withCString { cString in
            _ = inet_pton(AF_INET, cString, &addr.sin_addr)
        }

        packet.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var destination = addr
            withUnsafePointer(to: &destination) { destinationPtr in
                destinationPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    _ = sendto(fd, base, packet.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func isPortOpen(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
                continuation.resume(returning: false)
                return
            }

            let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
            let gate = WakeProbeResumeGate()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.markResumed() {
                        connection.stateUpdateHandler = nil
                        connection.cancel()
                        continuation.resume(returning: true)
                    }
                case .failed, .cancelled:
                    if gate.markResumed() {
                        connection.stateUpdateHandler = nil
                        connection.cancel()
                        continuation.resume(returning: false)
                    }
                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .utility))

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if gate.markResumed() {
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func connectToServer(_ server: DiscoveredServer, targetOverride: ConnectionTarget? = nil) async {
        guard connectingServer == nil else { return }
        connectingServer = server
        connectError = nil

        guard let target = targetOverride ?? server.connectionTarget else {
            connectError = "Server requires SSH login"
            connectingServer = nil
            return
        }

        let connectedServerId: String
        let startedAsyncBootstrap: Bool
        do {
            switch target {
            case .local:
                startedAsyncBootstrap = false
                connectedServerId = try await appModel.serverBridge.connectLocalServer(
                    serverId: server.id,
                    displayName: server.name,
                    host: "127.0.0.1",
                    port: 0
                )
                await appModel.restoreStoredLocalChatGPTAuth(serverId: server.id)
                SavedServerStore.remember(server)
            case .remote(let host, let port):
                startedAsyncBootstrap = false
                connectedServerId = try await appModel.serverBridge.connectRemoteServer(
                    serverId: server.id,
                    displayName: server.name,
                    host: host,
                    port: port
                )
                SavedServerStore.remember(server.withConnectionPreference(.directCodex, codexPort: port))
            case .remoteURL(let url):
                startedAsyncBootstrap = false
                connectedServerId = try await appModel.serverBridge.connectRemoteUrlServer(
                    serverId: server.id,
                    displayName: server.name,
                    websocketUrl: url.absoluteString
                )
                SavedServerStore.remember(server)
            case .sshThenRemote(let host, let credentials):
                startedAsyncBootstrap = true
                connectedServerId = try await connectViaSSH(server: server, host: host, credentials: credentials)
            }
        } catch {
            connectingServer = nil
            connectError = error.localizedDescription
            return
        }
        await appModel.refreshSnapshot()

        connectingServer = nil
        if startedAsyncBootstrap {
            pendingAutoNavigateServerId = connectedServerId
            pendingAutoNavigateServer = server
            return
        }
        if appModel.snapshot?.servers.first(where: { $0.serverId == connectedServerId })?.health == .connected {
            navigateAfterConnect(server)
        } else {
            connectError = "Failed to connect"
        }
    }

    private func connectViaSSH(
        server: DiscoveredServer,
        host: String,
        credentials: SSHCredentials
    ) async throws -> String {
        let serverId = try await sshConnectAndConnectServer(
            serverId: server.id,
            displayName: server.name,
            host: host,
            credentials: credentials,
            port: server.resolvedSSHPort
        )
        SavedServerStore.remember(
            server.withConnectionPreference(.ssh)
        )
        return serverId
    }

    private func sshConnectAndConnectServer(
        serverId: String,
        displayName: String,
        host: String,
        credentials: SSHCredentials,
        port: UInt16
    ) async throws -> String {
        let authMethod: String = switch credentials {
        case .password:
            "password"
        case .key:
            "private_key"
        }
        LLog.trace(
            "discovery",
            "starting guided SSH connect",
            fields: [
                "serverId": serverId,
                "host": host,
                "sshPort": Int(port),
                "authMethod": authMethod
            ]
        )
        let ipcSocketPathOverride = ExperimentalFeatures.shared.ipcSocketPathOverride()
        switch credentials {
        case .password(let username, let password):
            return try await appModel.ssh.sshStartRemoteServerConnect(
                serverId: serverId,
                displayName: displayName,
                host: host,
                port: port,
                username: username,
                password: password,
                privateKeyPem: nil,
                passphrase: nil,
                acceptUnknownHost: true,
                workingDir: nil,
                ipcSocketPathOverride: ipcSocketPathOverride
            )
        case .key(let username, let privateKey, let passphrase):
            return try await appModel.ssh.sshStartRemoteServerConnect(
                serverId: serverId,
                displayName: displayName,
                host: host,
                port: port,
                username: username,
                password: nil,
                privateKeyPem: privateKey,
                passphrase: passphrase,
                acceptUnknownHost: true,
                workingDir: nil,
                ipcSocketPathOverride: ipcSocketPathOverride
            )
        }
    }

    // MARK: - Manual Entry

    private var manualEntrySheet: some View {
        NavigationStack {
            ZStack {
                LitterTheme.backgroundGradient.ignoresSafeArea()
                Form {
                    Section {
                        Picker("Connection Type", selection: $manualConnectionMode) {
                            ForEach(ManualConnectionMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("Connection")
                            .foregroundColor(LitterTheme.textSecondary)
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))

                    Section {
                        if manualConnectionMode == .codex {
                            TextField("ws://host:port or wss://...", text: $manualCodexURL)
                                .litterFont(.footnote)
                                .foregroundColor(LitterTheme.textPrimary)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .keyboardType(.URL)
                        } else {
                            TextField("hostname or IP", text: $manualHost)
                                .litterFont(.footnote)
                                .foregroundColor(LitterTheme.textPrimary)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                            TextField("ssh port", text: $manualSSHPort)
                                .litterFont(.footnote)
                                .foregroundColor(LitterTheme.textPrimary)
                                .keyboardType(.numberPad)
                            TextField("wake MAC (optional)", text: $manualWakeMAC)
                                .litterFont(.footnote)
                                .foregroundColor(LitterTheme.textPrimary)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                        }
                    } header: {
                        Text(manualConnectionMode.formHeader)
                            .foregroundColor(LitterTheme.textSecondary)
                    } footer: {
                        if manualConnectionMode == .codex {
                            Text("Run: codex app-server --listen ws://0.0.0.0:8390\nFor reverse proxies: wss://example.com/ws?token=SECRET\nDo not expose directly to the internet unless you know what you are doing.")
                                .litterFont(.caption2)
                                .foregroundColor(LitterTheme.textMuted)
                        }
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))

                    Section {
                        Button(manualConnectionMode.primaryButtonTitle) {
                            submitManualEntry()
                        }
                        .foregroundColor(LitterTheme.accent)
                        .litterFont(.subheadline)
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { showManualEntry = false }
                        .foregroundColor(LitterTheme.accent)
                }
            }
        }
    }

    private func maybeStartSimulatorAutoSSH() {
#if DEBUG
        guard !autoSSHStarted else { return }
        let env = ProcessInfo.processInfo.environment
        guard env["CODEXIOS_SIM_AUTO_SSH"] == "1",
              let host = env["CODEXIOS_SIM_AUTO_SSH_HOST"], !host.isEmpty,
              let user = env["CODEXIOS_SIM_AUTO_SSH_USER"], !user.isEmpty else {
            return
        }
        let password = env["CODEXIOS_SIM_AUTO_SSH_PASS"]
        let keyPath = env["CODEXIOS_SIM_AUTO_SSH_KEY_PATH"]
        let keyPem: String? = keyPath.flatMap { path -> String? in
            guard !path.isEmpty else { return nil }
            return try? String(contentsOfFile: path, encoding: .utf8)
        }
        guard (password?.isEmpty == false) || (keyPem?.isEmpty == false) else { return }
        autoSSHStarted = true

        Task {
            NSLog("[AUTO_SSH] connecting to %@ as %@ (method=%@)", host, user, keyPem == nil ? "password" : "key")
            let server = DiscoveredServer(
                id: "auto-ssh-\(host)",
                name: host,
                hostname: host,
                port: nil,
                sshPort: 22,
                source: .ssh,
                hasCodexServer: false,
                sshPortForwardingEnabled: false,
                preferredConnectionMode: .ssh
            )
            let credentials: SSHCredentials
            if let keyPem, !keyPem.isEmpty {
                credentials = .key(
                    username: user,
                    privateKey: keyPem,
                    passphrase: env["CODEXIOS_SIM_AUTO_SSH_PASSPHRASE"]
                )
            } else {
                credentials = .password(username: user, password: password ?? "")
            }
            await connectToServer(
                server,
                targetOverride: .sshThenRemote(
                    host: host,
                    credentials: credentials
                )
            )
        }
#endif
    }

    private var showConnectError: Binding<Bool> {
        Binding(
            get: { connectError != nil },
            set: { newValue in
                if !newValue {
                    connectError = nil
                }
            }
        )
    }

    @MainActor
    private func startMacPairing(for server: DiscoveredServer) async {
        LLog.info(
            "pairing",
            "start nearby mac pairing",
            fields: [
                "serverId": server.id,
                "host": server.hostname,
                "name": server.name,
                "metadata": server.metadata
            ]
        )
        do {
            let status = try await macPairingClient.fetchStatus(for: server)
            if status.pairingMode == "auto" {
                LLog.info("pairing", "pairing mode auto", fields: ["serverId": server.id])
                await requestPairingPayload(for: server, code: nil)
            } else {
                LLog.info("pairing", "pairing mode requires code", fields: ["serverId": server.id])
                pairingTarget = server
                pairingCode = ""
            }
        } catch {
            LLog.error("pairing", "start nearby mac pairing failed", error: error, fields: ["serverId": server.id])
            connectError = error.localizedDescription
        }
    }

    @MainActor
    private func requestPairingPayload(for server: DiscoveredServer, code: String?) async {
        LLog.info(
            "pairing",
            "request pairing payload and start proxy",
            fields: [
                "serverId": server.id,
                "host": server.hostname,
                "hasCode": !(code?.isEmpty ?? true)
            ]
        )
        do {
            let payload = try await macPairingClient.requestPairingPayload(for: server, code: code)
            await pairWithPayload(
                payload,
                displayName: server.name,
                host: server.hostname,
                localPairingMode: server.metadata["pairing_mode"] ?? "code"
            )
        } catch {
            LLog.error("pairing", "pairing payload/proxy flow failed", error: error, fields: ["serverId": server.id])
            connectError = error.localizedDescription
        }
    }

    @MainActor
    private func pairWithMacCodeManually() async {
        let host = manualPairingHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = manualPairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !code.isEmpty else {
            connectError = "Enter both your Mac's IP/hostname and the pairing code."
            return
        }

        do {
            let payload = try await macPairingClient.requestPairingPayload(host: host, code: code)
            await pairWithPayload(
                payload,
                displayName: host,
                host: host,
                localPairingMode: "code"
            )
            manualPairingHost = ""
            manualPairingCode = ""
        } catch {
            connectError = error.localizedDescription
        }
    }

    @MainActor
    private func pairWithPayload(
        _ payload: MacBridgePairingPayload,
        displayName: String,
        host: String?,
        localPairingMode: String
    ) async {
        do {
            let currentPhoneIdentity = try? SecureRelayBridgeClient(identityPath: nil).phoneIdentity()
            let existingPairing = PairedMacStore.record(
                macDeviceId: payload.macDeviceId,
                macIdentityPublicKey: payload.macIdentityPublicKey
            )
            let trustedReconnect = existingPairing?.matchesCurrentPhoneIdentity(currentPhoneIdentity)
                ?? false
            let pairedRecord = PairedMacRecord(
                displayName: displayName,
                host: host ?? payload.macDeviceId,
                relayURL: payload.relay,
                relaySessionId: payload.sessionId,
                macDeviceId: payload.macDeviceId,
                macIdentityPublicKey: payload.macIdentityPublicKey,
                trustedPhoneDeviceId: currentPhoneIdentity?.phoneDeviceId,
                trustedPhoneIdentityPublicKey: currentPhoneIdentity?.phoneIdentityPublicKey,
                pairedAt: Date(),
                localPairingMode: localPairingMode
            )
            PairedMacStore.upsert(pairedRecord)
            LLog.info(
                "pairing",
                "paired mac record saved",
                fields: [
                    "macDeviceId": pairedRecord.macDeviceId,
                    "relayURL": pairedRecord.relayURL,
                    "relaySessionId": pairedRecord.relaySessionId
                ]
            )

            let localProxyURL: String
            do {
                localProxyURL = try await appModel.secureRelayProxy.startPairedMacProxy(
                    relayUrl: pairedRecord.relayURL,
                    relaySessionId: pairedRecord.relaySessionId,
                    macDeviceId: pairedRecord.macDeviceId,
                    macIdentityPublicKey: pairedRecord.macIdentityPublicKey,
                    trustedReconnect: trustedReconnect
                )
            } catch {
                let shouldRetryBootstrap = trustedReconnect && isTrustedReconnectSignatureError(error)
                if shouldRetryBootstrap {
                    LLog.warn(
                        "pairing",
                        "trusted reconnect rejected; retrying qr bootstrap",
                        fields: [
                            "macDeviceId": pairedRecord.macDeviceId,
                            "relaySessionId": pairedRecord.relaySessionId
                        ]
                    )
                    localProxyURL = try await appModel.secureRelayProxy.startPairedMacProxy(
                        relayUrl: pairedRecord.relayURL,
                        relaySessionId: pairedRecord.relaySessionId,
                        macDeviceId: pairedRecord.macDeviceId,
                        macIdentityPublicKey: pairedRecord.macIdentityPublicKey,
                        trustedReconnect: false
                    )
                } else {
                    throw error
                }
            }
            LLog.info(
                "pairing",
                "secure relay proxy started",
                fields: [
                    "macDeviceId": pairedRecord.macDeviceId,
                    "localProxyURL": localProxyURL,
                    "trustedReconnect": trustedReconnect
                ]
            )
            let proxyServer = DiscoveredServer(
                id: "paired-mac-\(pairedRecord.macDeviceId)",
                name: pairedRecord.displayName,
                hostname: "127.0.0.1",
                port: nil,
                codexPorts: [],
                sshPort: nil,
                source: .manual,
                hasCodexServer: true,
                websocketURL: localProxyURL,
                preferredConnectionMode: .directCodex,
                os: "macOS",
                metadata: [
                    "paired_mac": "true",
                    "paired_mac_device_id": pairedRecord.macDeviceId,
                ]
            )
            await connectToServer(proxyServer)
            pairingSuccessMessage = "Paired with \(displayName) and started a secure bridge connection."
        } catch {
            connectError = error.localizedDescription
        }
    }

    private func isTrustedReconnectSignatureError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("trusted session resolve failed")
            && (message.contains("invalid_signature")
                || message.contains("trusted-session resolve signature is invalid"))
    }

    private func submitManualEntry() {
        switch manualConnectionMode {
        case .codex:
            submitManualCodexEntry()
        case .ssh:
            submitManualSSHEntry()
        }
    }

    private func submitManualCodexEntry() {
        let raw = manualCodexURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        // Full URL: ws:// or wss://
        if let url = URL(string: raw),
           let scheme = url.scheme?.lowercased(),
           (scheme == "ws" || scheme == "wss"),
           let host = url.host, !host.isEmpty {
            let port = url.port.flatMap { UInt16(exactly: $0) }
            let server = DiscoveredServer(
                id: "manual-url-\(raw)",
                name: host,
                hostname: host,
                port: port,
                codexPorts: port.map { [$0] } ?? [],
                sshPort: nil,
                source: .manual,
                hasCodexServer: true,
                websocketURL: raw,
                preferredConnectionMode: .directCodex,
                preferredCodexPort: port
            )
            showManualEntry = false
            Task { await connectToServer(server) }
            return
        }

        // Bare host:port (e.g. "192.168.1.5:8390" or "myhost:8390")
        let parts = raw.split(separator: ":", maxSplits: 1)
        let host: String
        let port: UInt16
        if parts.count == 2, let p = UInt16(parts[1]) {
            host = String(parts[0])
            port = p
        } else if parts.count == 1 {
            host = raw
            port = 8390
        } else {
            connectError = "Enter a ws:// URL or host:port"
            return
        }

        guard !host.isEmpty else { return }
        let server = DiscoveredServer(
            id: "manual-\(host):\(port)",
            name: host,
            hostname: host,
            port: port,
            codexPorts: [port],
            sshPort: nil,
            source: .manual,
            hasCodexServer: true,
            preferredConnectionMode: .directCodex,
            preferredCodexPort: port
        )
        showManualEntry = false
        Task { await connectToServer(server) }
    }

    private func submitManualSSHEntry() {
        let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }

        let wakeInput = manualWakeMAC.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedWakeMAC = DiscoveredServer.normalizeWakeMAC(wakeInput)
        if !wakeInput.isEmpty && normalizedWakeMAC == nil {
            connectError = "Wake MAC must look like aa:bb:cc:dd:ee:ff"
            return
        }

        guard let sshPort = UInt16(manualSSHPort) else {
            connectError = "SSH port must be a valid number"
            return
        }
        pendingSSHServer = DiscoveredServer(
            id: "manual-ssh-\(host):\(sshPort)",
            name: host,
            hostname: host,
            port: nil,
            sshPort: sshPort,
            source: .manual,
            hasCodexServer: false,
            wakeMAC: normalizedWakeMAC,
            preferredConnectionMode: .ssh
        )
        showManualEntry = false
    }

    private var connectionChoicePresented: Binding<Bool> {
        Binding(
            get: { connectionChoiceServer != nil },
            set: { newValue in
                if !newValue {
                    connectionChoiceServer = nil
                }
            }
        )
    }

    private var pendingInstallServerSnapshot: AppServerSnapshot? {
        appModel.snapshot?.servers.first(where: { $0.connectionProgress?.pendingInstall == true })
    }

    private var pendingInstallPresented: Binding<Bool> {
        Binding(
            get: { pendingInstallServerSnapshot != nil },
            set: { _ in }
        )
    }

    private func connectionChoiceMessage(for server: DiscoveredServer) -> String {
        let directPorts = server.availableDirectCodexPorts.map(String.init)
        if directPorts.isEmpty {
            return "Use SSH to bootstrap Codex on \(server.hostname)."
        }
        if server.canConnectViaSSH {
            return "Codex is available on ports \(directPorts.joined(separator: ", ")) and SSH is also available on port \(server.resolvedSSHPort)."
        }
        return "Choose a Codex app-server port on \(server.hostname)."
    }

    private func progressTag(
        for serverSnapshot: AppServerSnapshot?
    ) -> (label: String, color: Color)? {
        guard let serverSnapshot,
              let label = serverSnapshot.connectionProgressLabel,
              let step = serverSnapshot.currentConnectionStep else {
            return nil
        }

        let color: Color
        switch step.state {
        case .failed:
            color = .red
        case .completed where step.kind == .connected:
            color = LitterTheme.accentStrong
        case .awaitingUserInput:
            color = .orange
        default:
            color = LitterTheme.accent
        }

        return (label, color)
    }
}

private final class WakeProbeResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func markResumed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed {
            return false
        }
        resumed = true
        return true
    }
}

private enum ManualConnectionMode: String, CaseIterable, Identifiable {
    case codex
    case ssh

    var id: String { rawValue }

    var label: String {
        switch self {
        case .codex:
            return "Codex"
        case .ssh:
            return "SSH"
        }
    }

    var formHeader: String {
        switch self {
        case .codex:
            return "Codex Server"
        case .ssh:
            return "SSH Bootstrap"
        }
    }

    var primaryButtonTitle: String {
        switch self {
        case .codex:
            return "Connect"
        case .ssh:
            return "Continue to SSH Login"
        }
    }
}

#if DEBUG
#Preview("Discovery") {
    LitterPreviewScene(
        appModel: LitterPreviewData.makeDiscoveryAppModel(),
        includeBackground: false
    ) {
        NavigationStack {
            DiscoveryView(
                autoStartDiscovery: false,
                initialServers: LitterPreviewData.sampleDiscoveryServers
            )
        }
    }
}
#endif
