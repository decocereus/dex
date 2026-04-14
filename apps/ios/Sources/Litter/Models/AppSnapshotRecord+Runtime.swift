import Foundation

extension AppSnapshotRecord {
    func threadHasTrackedTurn(for key: ThreadKey) -> Bool {
        guard let thread = threadSnapshot(for: key) else { return false }
        return threadHasTrackedTurn(thread)
    }

    private func threadHasTrackedTurn(_ thread: AppThreadSnapshot) -> Bool {
        if thread.hasActiveTurn {
            return true
        }

        let key = thread.key
        if pendingApprovals.contains(where: {
            $0.serverId == key.serverId && $0.threadId == key.threadId
        }) {
            return true
        }

        return pendingUserInputs.contains(where: {
            $0.serverId == key.serverId && $0.threadId == key.threadId
        })
    }

    var threadsWithTrackedTurns: [AppThreadSnapshot] {
        threads.filter { threadHasTrackedTurn($0) }
    }
}
