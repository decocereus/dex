import SwiftUI

struct HomeDashboardView: View {
    let workspaces: [HomeDashboardWorkspace]
    let recentSessions: [HomeDashboardRecentSession]
    let connectedServers: [HomeDashboardServer]
    let dexDesktopConnectionNotice: DexDesktopConnectionNotice?
    let openingRecentSessionKey: ThreadKey?
    let isStartingNewSession: Bool
    let onOpenRecentSession: @MainActor (HomeDashboardRecentSession) async -> Void
    let onOpenServerSessions: (HomeDashboardServer) -> Void
    let onOpenWorkspaceSessions: (HomeDashboardWorkspace) -> Void
    let onNewSession: () -> Void
    let onOpenConnectionPicker: () -> Void
    let onShowSettings: () -> Void
    var onDeleteThread: ((ThreadKey) async -> Void)? = nil
    var onReconnectLegacyServer: ((HomeDashboardServer) -> Void)? = nil
    var onDisconnectLegacyServer: ((String) -> Void)? = nil
    var onRenameLegacyServer: ((String, String) -> Void)? = nil
    var onForgetDexDesktop: ((String) -> Void)? = nil
    var onOpenRecording: ((URL) -> Void)? = nil
    @State private var deleteTargetThread: HomeDashboardRecentSession?
    @State private var disconnectTargetServer: HomeDashboardServer?
    @State private var renameTargetServer: HomeDashboardServer?
    @State private var renameText = ""
    @State private var dismissedNoticeId: String?

    private var allConnectedAreDexCompanion: Bool {
        !connectedServers.isEmpty && connectedServers.allSatisfy(\.isDexCompanion)
    }

    private var connectMacButtonTitle: String {
        allConnectedAreDexCompanion ? "Pair Dex Desktop" : "Connect Mac"
    }

    private var appVersionLabel: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        switch (version, build) {
        case let (version?, build?) where !version.isEmpty && !build.isEmpty:
            return "v\(version) (\(build))"
        case let (version?, _ ) where !version.isEmpty:
            return "v\(version)"
        case let (_, build?) where !build.isEmpty:
            return "build \(build)"
        default:
            return ""
        }
    }

    var body: some View {
        GeometryReader { geo in
            let recentLimit = max(3, Int((geo.size.height - 300) / 82))
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    workspacesSection(recentLimit: recentLimit)
                    if DebugSettings.shared.enabled {
                        recentSessionsSection(limit: recentLimit)
                        connectedServersSection
                        recordingsSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 144)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(LitterTheme.backgroundGradient.ignoresSafeArea())
        .alert("Delete Session?", isPresented: Binding(
            get: { deleteTargetThread != nil },
            set: { if !$0 { deleteTargetThread = nil } }
        )) {
            Button("Cancel", role: .cancel) { deleteTargetThread = nil }
            Button("Delete", role: .destructive) {
                if let thread = deleteTargetThread {
                    Task { await onDeleteThread?(thread.key) }
                }
                deleteTargetThread = nil
            }
        } message: {
            Text("This will permanently delete \"\(deleteTargetThread?.sessionTitle ?? "this session")\".")
        }
        .alert("Disconnect Server?", isPresented: Binding(
            get: { disconnectTargetServer != nil },
            set: { if !$0 { disconnectTargetServer = nil } }
        )) {
            Button("Cancel", role: .cancel) { disconnectTargetServer = nil }
            Button(disconnectTargetServer?.isDexCompanion == true ? "Forget" : "Disconnect", role: .destructive) {
                if let server = disconnectTargetServer {
                    if server.isDexCompanion {
                        onForgetDexDesktop?(server.id)
                    } else {
                        onDisconnectLegacyServer?(server.id)
                    }
                }
                disconnectTargetServer = nil
            }
        } message: {
            if disconnectTargetServer?.isDexCompanion == true {
                Text("Forget the paired Dex desktop for \"\(disconnectTargetServer?.displayName ?? "this project")\" on this iPhone?")
            } else {
                Text("Disconnect from \"\(disconnectTargetServer?.displayName ?? "this server")\"?")
            }
        }
        .alert("Rename Server", isPresented: Binding(
            get: { renameTargetServer != nil },
            set: { if !$0 { renameTargetServer = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTargetServer = nil }
            Button("Save") {
                if let server = renameTargetServer {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        onRenameLegacyServer?(server.id, trimmed)
                    }
                }
                renameTargetServer = nil
            }
        } message: {
            Text("Enter a new name for this server.")
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onShowSettings) {
                    Image(systemName: "gearshape")
                        .foregroundColor(LitterTheme.textSecondary)
                }
            }
            ToolbarItem(placement: .principal) {
                AnimatedLogo(size: 64)
            }
            ToolbarItem(placement: .topBarTrailing) {
                SupporterBadge()
            }
        }
        .overlay(alignment: .bottom) {
            if !appVersionLabel.isEmpty {
                Text(appVersionLabel)
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.textMuted.opacity(0.8))
                    .padding(.bottom, 2)
                    .ignoresSafeArea(.container, edges: .bottom)
            }
        }
    }

    private var visibleConnectionNotice: DexDesktopConnectionNotice? {
        guard let dexDesktopConnectionNotice,
              dexDesktopConnectionNotice.id != dismissedNoticeId else {
            return nil
        }
        return dexDesktopConnectionNotice
    }

    private func workspacesSection(recentLimit: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                title: "Workspaces",
                buttonTitle: connectMacButtonTitle,
                systemImage: "desktopcomputer",
                action: onOpenConnectionPicker
            )

            if let notice = visibleConnectionNotice {
                connectionNoticeCard(notice)
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(workspaces) { workspace in
                    Button {
                        onOpenWorkspaceSessions(workspace)
                    } label: {
                        workspaceCard(workspace)
                    }
                    .buttonStyle(.plain)
                    .disabled(workspace.isDexDesktop && workspace.servers.isEmpty)
                    .contextMenu {
                        if workspace.isDexDesktop, let firstServer = workspace.servers.first {
                            Button(role: .destructive) {
                                disconnectTargetServer = firstServer
                            } label: {
                                Label("Forget Desktop", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            if workspaces.count == 1 {
                emptyStateCard(
                    title: "Pair your Mac workspace",
                    message: "Pair Dex on your Mac and this page will reconnect automatically, then show recent projects and threads here."
                )
            }
        }
    }

    private func recentSessionsSection(limit: Int) -> some View {
        let displayed = Array(recentSessions.prefix(limit))
        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                title: "Recent Sessions",
                buttonTitle: "New Session",
                systemImage: "plus",
                showsLoading: isStartingNewSession,
                action: onNewSession
            )

            if displayed.isEmpty {
                emptyStateCard(
                    title: "No recent sessions",
                    message: connectedServers.isEmpty
                        ? "Pair your Dex desktop to start your first session."
                        : (allConnectedAreDexCompanion
                            ? "Start a new session in one of your paired Dex projects."
                            : "Start a new session on one of your connected servers.")
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(displayed) { thread in
                        Button {
                            Task { await onOpenRecentSession(thread) }
                        } label: {
                            recentSessionCard(thread)
                        }
                        .buttonStyle(.plain)
                        .disabled(openingRecentSessionKey != nil || isStartingNewSession)
                        .contextMenu {
                            Button(role: .destructive) {
                                deleteTargetThread = thread
                            } label: {
                                Label("Delete Session", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    private var connectedServersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                title: "Projects",
                buttonTitle: connectMacButtonTitle,
                systemImage: "desktopcomputer",
                action: onOpenConnectionPicker
            )

            if connectedServers.isEmpty {
                emptyStateCard(
                    title: "No connected projects",
                    message: "Pair your Dex desktop and its projects and chats will appear here."
                )
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(connectedServers) { server in
                        Button {
                            onOpenServerSessions(server)
                        } label: {
                            connectedServerRow(server)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if server.isDexCompanion {
                                Button(role: .destructive) {
                                    disconnectTargetServer = server
                                } label: {
                                    Label("Forget Desktop", systemImage: "trash")
                                }
                            } else {
                                Button {
                                    onReconnectLegacyServer?(server)
                                } label: {
                                    Label("Reconnect", systemImage: "arrow.clockwise")
                                }
                                if !server.isLocal {
                                    Button {
                                        renameText = server.displayName
                                        renameTargetServer = server
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                }
                                Button(role: .destructive) {
                                    disconnectTargetServer = server
                                } label: {
                                    Label("Disconnect Server", systemImage: "bolt.slash")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func sectionHeader(
        title: String,
        buttonTitle: String,
        systemImage: String,
        showsLoading: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .litterFont(.headline)
                .foregroundColor(LitterTheme.textPrimary)

            Spacer(minLength: 0)

            Button(action: action) {
                Group {
                    if showsLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(LitterTheme.accent)
                            .frame(width: 74)
                    } else {
                        Label(buttonTitle, systemImage: systemImage)
                            .litterFont(.caption)
                            .foregroundColor(LitterTheme.accent)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(LitterTheme.surface.opacity(0.72))
                .overlay(
                    Capsule()
                        .stroke(LitterTheme.border.opacity(0.7), lineWidth: 1)
                )
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(showsLoading)
        }
    }

    private func recentSessionCard(_ thread: HomeDashboardRecentSession) -> some View {
        let subtitle: String = {
            var parts = [thread.serverDisplayName]
            if let workspace = HomeDashboardSupport.workspaceLabel(for: thread.cwd) {
                parts.append(workspace)
            }
            parts.append(relativeDate(Int64(thread.updatedAt.timeIntervalSince1970)))
            return parts.joined(separator: " · ")
        }()

        let trailing: SessionServerCardRow.Trailing = {
            if openingRecentSessionKey == thread.key { return .none }
            if thread.hasTurnActive { return .badge("Thinking") }
            return .chevron
        }()

        return ZStack {
            SessionServerCardRow(
                icon: thread.hasTurnActive ? "sparkles" : "text.bubble",
                title: thread.sessionTitle,
                subtitle: subtitle,
                trailing: trailing
            )
            if openingRecentSessionKey == thread.key {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small).tint(LitterTheme.accent)
                }
                .padding(.trailing, 14)
            }
        }
        .accessibilityIdentifier("home.recentSessionCard")
    }

    private func workspaceCard(_ workspace: HomeDashboardWorkspace) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: workspace.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(workspace.statusColor)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(workspace.title)
                        .litterFont(.subheadline, weight: .semibold)
                        .foregroundColor(LitterTheme.textPrimary)
                    Text(workspace.subtitle)
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.textMuted)
                }

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    Circle()
                        .fill(workspace.statusColor)
                        .frame(width: 8, height: 8)
                    Text(workspace.statusLabel)
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.textMuted)
                }
            }

            if !workspace.recentProjects.isEmpty {
                previewRow(
                    icon: "folder",
                    title: "Projects",
                    values: workspace.recentProjects,
                    limit: 5
                )
            }

            if !workspace.recentThreads.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent threads")
                        .litterFont(.caption, weight: .semibold)
                        .foregroundColor(LitterTheme.textSecondary)

                    ForEach(workspace.recentThreads.prefix(3)) { thread in
                        HStack(spacing: 8) {
                            Image(systemName: thread.hasTurnActive ? "sparkles" : "text.bubble")
                                .foregroundColor(thread.hasTurnActive ? LitterTheme.accent : LitterTheme.textMuted)
                                .frame(width: 16)
                            Text(thread.sessionTitle)
                                .litterFont(.caption)
                                .foregroundColor(LitterTheme.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(relativeDate(Int64(thread.updatedAt.timeIntervalSince1970)))
                                .litterFont(.caption2)
                                .foregroundColor(LitterTheme.textMuted)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(LitterTheme.surface.opacity(0.58))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(LitterTheme.border.opacity(0.65), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .accessibilityIdentifier("home.workspaceCard.\(workspace.id)")
    }

    private func previewRow(icon: String, title: String, values: [String], limit: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(LitterTheme.textMuted)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .litterFont(.caption, weight: .semibold)
                    .foregroundColor(LitterTheme.textSecondary)
                Text(values.prefix(limit).joined(separator: ", "))
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.textMuted)
                    .lineLimit(2)
            }
        }
    }

    private func connectionNoticeCard(_ notice: DexDesktopConnectionNotice) -> some View {
        let isFailure = notice.kind == .failed
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundColor(isFailure ? LitterTheme.warning : LitterTheme.accent)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(notice.title)
                    .litterFont(.caption, weight: .semibold)
                    .foregroundColor(LitterTheme.textPrimary)
                Text(notice.message)
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button {
                dismissedNoticeId = notice.id
            } label: {
                Image(systemName: "xmark")
                    .litterFont(.caption, weight: .semibold)
                    .foregroundColor(LitterTheme.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background((isFailure ? LitterTheme.warning : LitterTheme.accent).opacity(0.1))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke((isFailure ? LitterTheme.warning : LitterTheme.accent).opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func connectedServerRow(_ server: HomeDashboardServer) -> some View {
        SessionServerCardRow(
            icon: server.isDexCompanion ? "desktopcomputer" : (server.isLocal ? "iphone" : "server.rack"),
            title: server.projectName ?? server.displayName,
            subtitle: HomeDashboardSupport.serverSubtitle(for: server),
            trailing: .statusLabel(server.statusLabel, server.statusColor)
        )
        .accessibilityIdentifier("home.connectedServerRow")
    }

    private func emptyStateCard(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .litterFont(.subheadline)
                .foregroundColor(LitterTheme.textPrimary)

            Text(message)
                .litterFont(.caption)
                .foregroundColor(LitterTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(LitterTheme.surface.opacity(0.5))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(LitterTheme.border.opacity(0.65), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Recordings

    @State private var recordings: [URL] = []

    private var recordingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recordings")
                .litterFont(.headline)
                .foregroundColor(LitterTheme.textPrimary)

            if recordings.isEmpty {
                emptyStateCard(
                    title: "No recordings",
                    message: "Record a conversation from the debug popover to replay it here."
                )
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(recordings, id: \.absoluteString) { url in
                        Button {
                            onOpenRecording?(url)
                        } label: {
                            SessionServerCardRow(
                                icon: "waveform",
                                title: url.deletingPathExtension().lastPathComponent,
                                subtitle: recordingFileSize(url),
                                trailing: .chevron
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                MessageRecorder.shared.deleteRecording(url: url)
                                recordings = MessageRecorder.shared.listRecordings()
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .onAppear { recordings = MessageRecorder.shared.listRecordings() }
    }

    private func recordingFileSize(_ url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64 else { return "" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }
}
