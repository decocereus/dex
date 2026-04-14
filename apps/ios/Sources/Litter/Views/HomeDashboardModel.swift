import Foundation
import Observation

@MainActor
@Observable
final class HomeDashboardModel {
    private struct Snapshot {
        let connectedServers: [HomeDashboardServer]
        let recentSessions: [HomeDashboardRecentSession]
    }

    private(set) var connectedServers: [HomeDashboardServer] = []
    private(set) var recentSessions: [HomeDashboardRecentSession] = []

    @ObservationIgnored private weak var appModel: AppModel?
    @ObservationIgnored private(set) var rebuildCount = 0
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var observationGeneration = 0
    @ObservationIgnored private var nativeSnapshot = Snapshot(connectedServers: [], recentSessions: [])
    @ObservationIgnored private var dexSnapshot = Snapshot(connectedServers: [], recentSessions: [])
    @ObservationIgnored private var dexRefreshTask: Task<Void, Never>?

    func bind(appModel: AppModel) {
        self.appModel = appModel
        guard isActive else { return }
        refreshState()
        refreshDexCompanionState()
    }

    func activate() {
        guard !isActive else { return }
        isActive = true
        refreshState()
        refreshDexCompanionState()
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        observationGeneration &+= 1
        dexRefreshTask?.cancel()
        dexRefreshTask = nil
    }

    private func refreshState() {
        guard isActive, let appModel else {
            nativeSnapshot = Snapshot(connectedServers: [], recentSessions: [])
            publishMergedState()
            return
        }

        observationGeneration &+= 1
        let generation = observationGeneration
        let snapshot = withObservationTracking {
            let appSnapshot = appModel.snapshot
            let nextConnectedServers = HomeDashboardSupport.sortedConnectedServers(
                from: appSnapshot?.servers ?? [],
                sessions: appSnapshot?.sessionSummaries ?? [],
                activeServerId: appSnapshot?.activeThread?.serverId
            )
            let nextRecentSessions = HomeDashboardSupport.recentConnectedSessions(
                from: appSnapshot?.sessionSummaries ?? [],
                serversById: Dictionary(uniqueKeysWithValues: nextConnectedServers.map { ($0.id, $0) })
            )
            return Snapshot(
                connectedServers: nextConnectedServers,
                recentSessions: nextRecentSessions
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isActive, self.observationGeneration == generation else { return }
                self.refreshState()
            }
        }

        rebuildCount += 1
        nativeSnapshot = snapshot
        publishMergedState()
    }

    private func refreshDexCompanionState() {
        dexRefreshTask?.cancel()
        dexRefreshTask = Task { @MainActor [weak self] in
            guard let self, self.isActive else { return }
            let snapshot = await DexCompanionDashboardIndex.load(limit: 10)
            guard self.isActive, !Task.isCancelled else { return }
            self.dexSnapshot = Snapshot(
                connectedServers: snapshot.connectedServers,
                recentSessions: snapshot.recentSessions
            )
            self.publishMergedState()
        }
    }

    private func publishMergedState() {
        connectedServers = HomeDashboardSupport.mergeServers(
            native: nativeSnapshot.connectedServers,
            dexCompanion: dexSnapshot.connectedServers
        )
        recentSessions = HomeDashboardSupport.mergeRecentSessions(
            native: nativeSnapshot.recentSessions,
            dexCompanion: dexSnapshot.recentSessions
        )
    }
}
