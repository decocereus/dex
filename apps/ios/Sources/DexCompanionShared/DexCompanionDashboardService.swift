import Foundation
import Observation

@MainActor
@Observable
final class DexCompanionDashboardService {
    static let shared = DexCompanionDashboardService()

    private(set) var snapshot: DexCompanionDashboardIndex.Snapshot = .empty

    @ObservationIgnored private var consumerCount = 0
    @ObservationIgnored private var streamTask: Task<Void, Never>?

    deinit {
        streamTask?.cancel()
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
    }

    func refresh() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await DexCompanionDashboardIndex.load(limit: 200)
            guard !Task.isCancelled else { return }
            self.snapshot = snapshot
        }
    }

    private func startStreaming() {
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in
            while let self, await MainActor.run(body: { self.consumerCount > 0 }), !Task.isCancelled {
                let savedSessions = await MainActor.run { DexCompanionSessionStore.load() }
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
                                    DexCompanionSessionStore.remove(environmentId: savedSession.environmentId)
                                }
                                return
                            }

                            let client = DexCompanionClient(
                                httpBaseUrl: browserSession.httpBaseUrl,
                                bearerToken: browserSession.bearerToken
                            )

                            do {
                                try await client.streamNativeShellSnapshots { _ in
                                    guard !Task.isCancelled else { return }
                                    await MainActor.run {
                                        self.refresh()
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
}
