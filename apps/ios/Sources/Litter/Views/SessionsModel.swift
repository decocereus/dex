import Foundation
import Observation

@MainActor
@Observable
final class SessionsModel {
    private struct DexSnapshot: Equatable {
        let sessionSummaries: [AppSessionSummary]
        let connectedServers: [HomeDashboardServer]
    }

    struct ThreadEphemeralState: Equatable {
        let hasTurnActive: Bool
        let updatedAt: Date
    }

    private struct Snapshot: Equatable {
        let derivedData: SessionsDerivedData
        let connectedServerOptions: [DirectoryPickerServerOption]
        let connectedServers: [HomeDashboardServer]
        let ephemeralStateByThreadKey: [ThreadKey: ThreadEphemeralState]
        let activeThreadKey: ThreadKey?
        let frozenMostRecentThreadOrder: [ThreadKey]?
    }

    private(set) var derivedData: SessionsDerivedData = .empty
    private(set) var connectedServerOptions: [DirectoryPickerServerOption] = []
    private(set) var connectedServers: [HomeDashboardServer] = []
    private(set) var ephemeralStateByThreadKey: [ThreadKey: ThreadEphemeralState] = [:]
    private(set) var activeThreadKey: ThreadKey?

    @ObservationIgnored private weak var appModel: AppModel?
    @ObservationIgnored private weak var appState: AppState?
    @ObservationIgnored private let dexDashboardService = DexDesktopDashboardService.shared
    @ObservationIgnored private var searchQuery = ""
    @ObservationIgnored private var hasInitializedState = false
    @ObservationIgnored private var nativeObservationGeneration = 0
    @ObservationIgnored private var dexObservationGeneration = 0
    @ObservationIgnored private var frozenMostRecentThreadOrder: [ThreadKey]?
    @ObservationIgnored private var lastPublishedSnapshot: Snapshot?
    @ObservationIgnored private var dexSnapshot = DexSnapshot(
        sessionSummaries: [],
        connectedServers: []
    )
    @ObservationIgnored private var dexDashboardConsumerActive = false

    func bind(appModel: AppModel, appState: AppState) {
        let needsRebind = self.appModel !== appModel || self.appState !== appState

        self.appModel = appModel
        self.appState = appState

        guard needsRebind || !hasInitializedState else { return }
        hasInitializedState = true
        refreshState()
        activateDexDashboardConsumerIfNeeded()
        refreshDexState()
    }

    func updateSearchQuery(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != searchQuery else { return }
        searchQuery = trimmed
        refreshState()
    }

    private func refreshState() {
        guard let appModel, let appState else {
            derivedData = .empty
            connectedServerOptions = []
            connectedServers = []
            ephemeralStateByThreadKey = [:]
            activeThreadKey = nil
            frozenMostRecentThreadOrder = nil
            lastPublishedSnapshot = nil
            return
        }

        let previousDisplayedOrder = derivedData.allThreadKeys
        let currentSearchQuery = searchQuery

        nativeObservationGeneration &+= 1
        let generation = nativeObservationGeneration
        let snapshot = withObservationTracking {
            let selectedServerFilterId = appState.sessionsSelectedServerFilterId
            let showOnlyForks = appState.sessionsShowOnlyForks
            let workspaceSortMode = WorkspaceSortMode(rawValue: appState.sessionsWorkspaceSortModeRaw) ?? .mostRecent
            let appSnapshot = appModel.snapshot
            let combinedSessionSummaries = mergeSessionSummaries(
                native: appSnapshot?.sessionSummaries ?? [],
                dex: dexSnapshot.sessionSummaries
            )

            let nativeConnectedServers = HomeDashboardSupport.sortedConnectedServers(
                from: appSnapshot?.servers ?? [],
                activeServerId: appSnapshot?.activeThread?.serverId
            )
            let nextConnectedServers = HomeDashboardSupport.mergeServers(
                native: nativeConnectedServers,
                dexCompanion: dexSnapshot.connectedServers
            )

            let nextConnectedServerOptions = nextConnectedServers.map {
                DirectoryPickerServerOption(
                    id: $0.id,
                    name: $0.displayName,
                    sourceLabel: $0.sourceLabel,
                    workspaceRoot: $0.workspaceRoot
                )
            }

            let nextEphemeralStateByThreadKey = combinedSessionSummaries.reduce(into: [ThreadKey: ThreadEphemeralState]()) { partialResult, session in
                partialResult[session.key] = ThreadEphemeralState(
                    hasTurnActive: session.hasActiveTurn,
                    updatedAt: session.updatedAtDate
                )
            }

            let nextFrozenMostRecentThreadOrder = resolvedFrozenMostRecentThreadOrder(
                sessionSummaries: combinedSessionSummaries,
                workspaceSortMode: workspaceSortMode,
                previousDisplayedOrder: previousDisplayedOrder
            )

            let nextDerivedData = SessionsDerivation.build(
                sessions: combinedSessionSummaries,
                selectedServerFilterId: selectedServerFilterId,
                showOnlyForks: showOnlyForks,
                workspaceSortMode: workspaceSortMode,
                searchQuery: currentSearchQuery,
                frozenMostRecentOrder: nextFrozenMostRecentThreadOrder
            )

            return Snapshot(
                derivedData: nextDerivedData,
                connectedServerOptions: nextConnectedServerOptions,
                connectedServers: nextConnectedServers,
                ephemeralStateByThreadKey: nextEphemeralStateByThreadKey,
                activeThreadKey: appSnapshot?.activeThread,
                frozenMostRecentThreadOrder: nextFrozenMostRecentThreadOrder
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.nativeObservationGeneration == generation else { return }
                self.refreshState()
            }
        }

        let previousSnapshot = lastPublishedSnapshot
        guard previousSnapshot != snapshot else {
            frozenMostRecentThreadOrder = snapshot.frozenMostRecentThreadOrder
            return
        }

        frozenMostRecentThreadOrder = snapshot.frozenMostRecentThreadOrder
        lastPublishedSnapshot = snapshot

        if previousSnapshot?.connectedServerOptions != snapshot.connectedServerOptions {
            connectedServerOptions = snapshot.connectedServerOptions
        }
        if previousSnapshot?.connectedServers != snapshot.connectedServers {
            connectedServers = snapshot.connectedServers
        }
        if previousSnapshot?.ephemeralStateByThreadKey != snapshot.ephemeralStateByThreadKey {
            ephemeralStateByThreadKey = snapshot.ephemeralStateByThreadKey
        }
        if previousSnapshot?.activeThreadKey != snapshot.activeThreadKey {
            activeThreadKey = snapshot.activeThreadKey
        }
        if previousSnapshot?.derivedData != snapshot.derivedData {
            derivedData = snapshot.derivedData
        }
    }

    private func refreshDexState() {
        dexObservationGeneration &+= 1
        let generation = dexObservationGeneration
        let snapshot = withObservationTracking {
            let dexSnapshot = dexDashboardService.snapshot
            return DexSnapshot(
                sessionSummaries: dexSnapshot.sessionSummaries,
                connectedServers: dexSnapshot.connectedServers
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.dexObservationGeneration == generation else { return }
                self.refreshDexState()
            }
        }

        self.dexSnapshot = snapshot
        refreshState()
    }

    private func activateDexDashboardConsumerIfNeeded() {
        guard !dexDashboardConsumerActive else { return }
        dexDashboardConsumerActive = true
        dexDashboardService.activateConsumer()
    }

    private func deactivateDexDashboardConsumerIfNeeded() {
        guard dexDashboardConsumerActive else { return }
        dexDashboardConsumerActive = false
        dexDashboardService.deactivateConsumer()
    }

    private func mergeSessionSummaries(
        native: [AppSessionSummary],
        dex: [AppSessionSummary]
    ) -> [AppSessionSummary] {
        var seen = Set<ThreadKey>()
        return (native + dex).filter { summary in
            seen.insert(summary.key).inserted
        }
    }

    private func resolvedFrozenMostRecentThreadOrder(
        sessionSummaries: [AppSessionSummary],
        workspaceSortMode: WorkspaceSortMode,
        previousDisplayedOrder: [ThreadKey]
    ) -> [ThreadKey]? {
        guard workspaceSortMode == .mostRecent else {
            return nil
        }

        let hasActiveThread = sessionSummaries.contains(where: \.hasActiveTurn)
        guard hasActiveThread else {
            return nil
        }

        if let frozenMostRecentThreadOrder {
            return frozenMostRecentThreadOrder
        }

        if !previousDisplayedOrder.isEmpty {
            return previousDisplayedOrder
        }

        return sessionSummaries
            .sorted { $0.updatedAtDate > $1.updatedAtDate }
            .map(\.key)
    }
}
