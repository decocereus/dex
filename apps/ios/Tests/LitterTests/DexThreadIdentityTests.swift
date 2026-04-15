import XCTest
@testable import Litter

@MainActor
final class DexThreadIdentityTests: XCTestCase {
    func testAuthoritativeDexThreadKeyUsesThreadIDFromSnapshotThread() {
        let snapshot = makeNativeThreadSnapshot(
            threadID: "thread-from-server",
            summaryThreadID: "stale-summary-thread-id"
        )

        let key = AppModel.authoritativeDexThreadKey(
            serverId: "dex-companion:env-1::project-1",
            nativeSnapshot: snapshot
        )

        XCTAssertEqual(key.serverId, "dex-companion:env-1::project-1")
        XCTAssertEqual(key.threadId, "thread-from-server")
    }

    func testClearDexThreadStateLocallyClearsMatchingActiveThread() {
        let key = ThreadKey(serverId: "dex-companion:env-1::project-1", threadId: "thread-1")
        let model = AppModel()
        model.applySnapshot(makeSnapshot(activeThread: key))

        model.clearDexThreadStateLocally(for: key)

        XCTAssertNil(model.snapshot?.activeThread)
    }

    private func makeNativeThreadSnapshot(
        threadID: String,
        summaryThreadID: String
    ) -> DexNativeThreadSnapshot {
        DexNativeThreadSnapshot(
            environment: DexNativeEnvironmentDescriptor(
                environmentId: "env-1",
                label: "Dex Desktop"
            ),
            summary: DexNativeSessionSummary(
                threadRef: DexNativeScopedThreadRef(
                    environmentId: "env-1",
                    threadId: summaryThreadID
                ),
                projectId: "project-1",
                title: "New Session",
                preview: "hello",
                cwd: "/tmp/project",
                branch: "main",
                model: "gpt-5.4",
                modelProvider: "codex",
                runtimeMode: "full-access",
                interactionMode: "default",
                updatedAt: "2026-04-15T00:00:00Z",
                archivedAt: nil,
                latestUserMessageAt: nil,
                hasActiveTurn: false,
                hasPendingApprovals: false,
                hasPendingUserInput: false,
                isSubagent: false,
                isFork: false,
                parentThreadId: nil,
                agentNickname: nil,
                agentRole: nil,
                agentDisplayLabel: nil,
                agentStatus: nil
            ),
            thread: DexNativeOrchestrationThread(
                id: threadID,
                projectId: "project-1",
                title: "New Session",
                modelSelection: DexNativeModelSelection(
                    provider: "codex",
                    model: "gpt-5.4",
                    options: nil
                ),
                runtimeMode: "full-access",
                interactionMode: "default",
                branch: "main",
                worktreePath: "/tmp/project",
                latestTurn: nil,
                messages: []
            ),
            pendingApprovals: [],
            pendingUserInputs: [],
            updatedAt: "2026-04-15T00:00:00Z"
        )
    }

    private func makeSnapshot(activeThread: ThreadKey?) -> AppSnapshotRecord {
        let server = AppServerSnapshot(
            serverId: "dex-companion:env-1::project-1",
            displayName: "Dex Desktop",
            host: "dex.local",
            port: 8080,
            wakeMac: nil,
            isLocal: false,
            supportsIpc: false,
            hasIpc: false,
            health: .connected,
            transportState: .connected,
            ipcState: .unsupported,
            capabilities: AppServerCapabilities(
                canUseTransportActions: true,
                canBrowseDirectories: false,
                canStartThreads: true,
                canResumeThreads: true,
                canUseIpc: false,
                canResumeViaIpc: false
            ),
            account: nil,
            requiresOpenaiAuth: false,
            rateLimits: nil,
            availableModels: nil,
            connectionProgress: nil
        )

        return AppSnapshotRecord(
            servers: [server],
            threads: [],
            sessionSummaries: [],
            agentDirectoryVersion: 0,
            activeThread: activeThread,
            pendingApprovals: [],
            pendingUserInputs: [],
            voiceSession: AppVoiceSessionSnapshot(
                activeThread: nil,
                sessionId: nil,
                phase: nil,
                lastError: nil,
                transcriptEntries: [],
                handoffThreadKey: nil
            )
        )
    }
}
