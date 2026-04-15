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
    @ObservationIgnored private let dexDashboardService = DexDesktopDashboardService.shared
    @ObservationIgnored private(set) var rebuildCount = 0
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var nativeObservationGeneration = 0
    @ObservationIgnored private var dexObservationGeneration = 0
    @ObservationIgnored private var nativeSnapshot = Snapshot(connectedServers: [], recentSessions: [])
    @ObservationIgnored private var dexSnapshot = Snapshot(connectedServers: [], recentSessions: [])
    @ObservationIgnored private var dexDashboardConsumerActive = false

    func bind(appModel: AppModel) {
        self.appModel = appModel
        guard isActive else { return }
        refreshState()
        activateDexDashboardConsumerIfNeeded()
        refreshDexState()
    }

    func activate() {
        guard !isActive else { return }
        isActive = true
        refreshState()
        activateDexDashboardConsumerIfNeeded()
        refreshDexState()
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        nativeObservationGeneration &+= 1
        dexObservationGeneration &+= 1
        deactivateDexDashboardConsumerIfNeeded()
    }

    private func refreshState() {
        guard isActive, let appModel else {
            nativeSnapshot = Snapshot(connectedServers: [], recentSessions: [])
            publishMergedState()
            return
        }

        nativeObservationGeneration &+= 1
        let generation = nativeObservationGeneration
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
                guard let self, self.isActive else { return }
                guard self.nativeObservationGeneration == generation else { return }
                self.refreshState()
            }
        }

        rebuildCount += 1
        nativeSnapshot = snapshot
        publishMergedState()
    }

    private func refreshDexState() {
        guard isActive else {
            dexSnapshot = Snapshot(connectedServers: [], recentSessions: [])
            publishMergedState()
            return
        }

        dexObservationGeneration &+= 1
        let generation = dexObservationGeneration
        let snapshot = withObservationTracking {
            let dexSnapshot = dexDashboardService.snapshot
            return Snapshot(
                connectedServers: dexSnapshot.connectedServers,
                recentSessions: Array(dexSnapshot.recentSessions.prefix(10))
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isActive, self.dexObservationGeneration == generation else {
                    return
                }
                self.refreshDexState()
            }
        }

        dexSnapshot = snapshot
        publishMergedState()
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
}
