import Foundation
import Observation

@MainActor
@Observable
final class DexCompanionDashboardService {
    static let shared = DexCompanionDashboardService()

    private(set) var snapshot: DexCompanionDashboardIndex.Snapshot = .empty

    @ObservationIgnored private var consumerCount = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?

    private static let pollingNanoseconds: UInt64 = 10_000_000_000
    private static let sharedSnapshotLimit = 200

    deinit {
        refreshTask?.cancel()
        pollingTask?.cancel()
    }

    func activateConsumer() {
        consumerCount += 1
        guard consumerCount == 1 else { return }
        refresh()
        startPolling()
    }

    func deactivateConsumer() {
        consumerCount = max(consumerCount - 1, 0)
        guard consumerCount == 0 else { return }
        refreshTask?.cancel()
        refreshTask = nil
        pollingTask?.cancel()
        pollingTask = nil
    }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await DexCompanionDashboardIndex.load(
                limit: Self.sharedSnapshotLimit
            )
            guard !Task.isCancelled else { return }
            self.snapshot = snapshot
        }
    }

    private func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { @MainActor [weak self] in
            while let self, self.consumerCount > 0, !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.pollingNanoseconds)
                } catch {
                    break
                }
                guard self.consumerCount > 0, !Task.isCancelled else { break }
                self.refresh()
            }
            self?.pollingTask = nil
        }
    }
}
