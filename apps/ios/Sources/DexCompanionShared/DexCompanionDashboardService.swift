import Foundation
import Observation

@MainActor
@Observable
final class DexDesktopDashboardService {
    static let shared = DexDesktopDashboardService()

    private(set) var snapshot: DexDesktopDashboardIndex.Snapshot = .empty

    @ObservationIgnored private var consumerCount = 0
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var environmentSnapshots: [String: DexDesktopDashboardIndex.Snapshot] = [:]
    @ObservationIgnored private var sessionsObserver: NSObjectProtocol?

    init() {
        sessionsObserver = NotificationCenter.default.addObserver(
            forName: .dexDesktopSessionsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.consumerCount > 0 else { return }
                self.restartStreaming()
            }
        }
    }

    deinit {
        streamTask?.cancel()
        if let sessionsObserver {
            NotificationCenter.default.removeObserver(sessionsObserver)
        }
    }

    func activateConsumer() {
        consumerCount += 1
        guard consumerCount == 1 else { return }
        refresh()
        startStreaming()
    }

    func deactivateConsumer() {
        consumerCount = max(consumerCount - 1, 0)
        guard consumerCount == 0 else { return }
        streamTask?.cancel()
        streamTask = nil
        environmentSnapshots.removeAll()
    }

    func refresh() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshotsByEnvironment = await DexDesktopDashboardIndex.loadSnapshotsByEnvironment(
                limit: 200
            )
            guard !Task.isCancelled else { return }
            self.environmentSnapshots = snapshotsByEnvironment
            self.snapshot = DexDesktopDashboardIndex.mergeSnapshots(
                Array(snapshotsByEnvironment.values),
                limit: 200
            )
        }
    }

    private func startStreaming() {
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in
            while let self, await MainActor.run(body: { self.consumerCount > 0 }), !Task.isCancelled {
                let savedSessions = await MainActor.run { DexDesktopSessionStore.load() }
                if savedSessions.isEmpty {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }

                await withTaskGroup(of: Void.self) { group in
                    for savedSession in savedSessions {
                        group.addTask { [weak self] in
                            guard let self else { return }
                            guard let browserSession = await MainActor.run(body: { savedSession.makeBrowserSession() }) else {
                                await MainActor.run {
                                    DexDesktopSessionStore.remove(environmentId: savedSession.environmentId)
                                }
                                return
                            }

                            let client = DexCompanionClient(
                                httpBaseUrl: browserSession.httpBaseUrl,
                                bearerToken: browserSession.bearerToken
                            )

                            do {
                                try await client.streamNativeShellSnapshots { shellSnapshot in
                                    guard !Task.isCancelled else { return }
                                    await MainActor.run {
                                        let nextSnapshot = DexDesktopDashboardIndex.makeSnapshot(
                                            savedSession: savedSession,
                                            browserSession: browserSession,
                                            shellSnapshot: shellSnapshot,
                                            limit: 200
                                        )
                                        self.environmentSnapshots[savedSession.environmentId] = nextSnapshot
                                        self.snapshot = DexDesktopDashboardIndex.mergeSnapshots(
                                            Array(self.environmentSnapshots.values),
                                            limit: 200
                                        )
                                    }
                                }
                            } catch {
                                guard !Task.isCancelled else { return }
                            }
                        }
                    }
                    await group.waitForAll()
                }

                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }

            await MainActor.run { [weak self] in
                self?.streamTask = nil
            }
        }
    }

    private func restartStreaming() {
        streamTask?.cancel()
        streamTask = nil
        refresh()
        startStreaming()
    }
}

typealias DexCompanionDashboardService = DexDesktopDashboardService
