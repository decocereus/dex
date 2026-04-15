import Foundation

struct DexNativeThreadOverlay {
    let serverSnapshot: AppServerSnapshot
    let sessionSummary: AppSessionSummary
    let threadSnapshot: AppThreadSnapshot
    let pendingApprovals: [PendingApproval]
    let pendingUserInputs: [PendingUserInputRequest]
}

enum DexNativeThreadAdapter {
    static func makeOverlay(
        serverId: String,
        browserSession: DexDesktopBrowserSession,
        snapshot: DexNativeThreadSnapshot
    ) -> DexNativeThreadOverlay {
        let host = URL(string: browserSession.httpBaseUrl)?.host ?? "dex"
        let port = UInt16(URL(string: browserSession.httpBaseUrl)?.port ?? 443)
        let key = ThreadKey(serverId: serverId, threadId: snapshot.thread.id)

        let serverSnapshot = AppServerSnapshot(
            serverId: serverId,
            displayName: browserSession.serverLabel,
            host: host,
            port: port,
            wakeMac: nil,
            isLocal: false,
            supportsIpc: false,
            hasIpc: false,
            health: .connected,
            transportState: .connected,
            ipcState: .unsupported,
            capabilities: AppServerCapabilities(
                canUseTransportActions: false,
                canBrowseDirectories: false,
                canStartThreads: true,
                canResumeThreads: true,
                canUseIpc: false,
                canResumeViaIpc: false
            ),
            account: nil,
            requiresOpenaiAuth: false,
            rateLimits: nil,
            availableModels: syntheticAvailableModels(from: snapshot),
            connectionProgress: nil
        )

        let sessionSummary = AppSessionSummary(
            key: key,
            serverDisplayName: browserSession.serverLabel,
            serverHost: host,
            title: snapshot.summary.title,
            preview: snapshot.summary.preview,
            cwd: snapshot.summary.cwd ?? "",
            model: snapshot.summary.model,
            modelProvider: snapshot.summary.modelProvider,
            parentThreadId: snapshot.summary.parentThreadId,
            agentNickname: snapshot.summary.agentNickname,
            agentRole: snapshot.summary.agentRole,
            agentDisplayLabel: snapshot.summary.agentDisplayLabel,
            agentStatus: subagentStatus(from: snapshot.summary.agentStatus),
            updatedAt: isoDateToUnixSeconds(snapshot.summary.updatedAt),
            hasActiveTurn: snapshot.summary.hasActiveTurn,
            isSubagent: snapshot.summary.isSubagent,
            isFork: snapshot.summary.isFork
        )

        let threadInfo = ThreadInfo(
            id: snapshot.thread.id,
            title: snapshot.summary.title,
            model: snapshot.summary.model,
            status: threadStatus(from: snapshot),
            preview: snapshot.summary.preview,
            cwd: snapshot.summary.cwd,
            path: nil,
            modelProvider: snapshot.summary.modelProvider,
            agentNickname: snapshot.summary.agentNickname,
            agentRole: snapshot.summary.agentRole,
            parentThreadId: snapshot.summary.parentThreadId,
            agentStatus: snapshot.summary.agentStatus,
            createdAt: isoDateToUnixSeconds(snapshot.thread.messages.first?.createdAt ?? snapshot.updatedAt),
            updatedAt: isoDateToUnixSeconds(snapshot.summary.updatedAt)
        )

        let threadSnapshot = AppThreadSnapshot(
            key: key,
            info: threadInfo,
            collaborationMode: collaborationMode(from: snapshot.summary.interactionMode),
            model: snapshot.summary.model,
            reasoningEffort: reasoningEffort(from: snapshot.thread),
            effectiveApprovalPolicy: effectiveApprovalPolicy(from: snapshot.summary.runtimeMode),
            effectiveSandboxPolicy: effectiveSandboxPolicy(from: snapshot.summary.runtimeMode),
            hydratedConversationItems: hydratedConversationItems(from: snapshot.thread),
            queuedFollowUps: [],
            activeTurnId: snapshot.thread.messages.last?.turnId,
            activePlanProgress: nil,
            pendingPlanImplementationPrompt: nil,
            contextTokensUsed: nil,
            modelContextWindow: nil,
            rateLimits: nil,
            realtimeSessionId: nil
        )

        return DexNativeThreadOverlay(
            serverSnapshot: serverSnapshot,
            sessionSummary: sessionSummary,
            threadSnapshot: threadSnapshot,
            pendingApprovals: snapshot.pendingApprovals.map {
                PendingApproval(
                    id: $0.requestId,
                    serverId: serverId,
                    kind: approvalKind(from: $0.requestKind),
                    threadId: snapshot.thread.id,
                    turnId: $0.turnId,
                    itemId: nil,
                    command: nil,
                    path: nil,
                    grantRoot: nil,
                    cwd: snapshot.summary.cwd,
                    reason: $0.detail
                )
            },
            pendingUserInputs: snapshot.pendingUserInputs.map {
                PendingUserInputRequest(
                    id: $0.requestId,
                    serverId: serverId,
                    threadId: snapshot.thread.id,
                    turnId: $0.turnId ?? "",
                    itemId: $0.requestId,
                    questions: $0.questions.map {
                        PendingUserInputQuestion(
                            id: $0.id,
                            header: $0.header,
                            question: $0.question,
                            isOtherAllowed: false,
                            isSecret: false,
                            options: $0.options.map {
                                PendingUserInputOption(
                                    label: $0.label,
                                    description: $0.description
                                )
                            }
                        )
                    },
                    requesterAgentNickname: snapshot.summary.agentNickname,
                    requesterAgentRole: snapshot.summary.agentRole
                )
            }
        )
    }

    private static func isoDateToUnixSeconds(_ value: String) -> Int64? {
        let formatterWithFractional = ISO8601DateFormatter()
        formatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatterWithFractional.date(from: value) {
            return Int64(date.timeIntervalSince1970)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else { return nil }
        return Int64(date.timeIntervalSince1970)
    }

    private static func threadStatus(from snapshot: DexNativeThreadSnapshot) -> ThreadSummaryStatus {
        if snapshot.summary.hasActiveTurn {
            return .active
        }
        return .idle
    }

    private static func collaborationMode(from value: String) -> AppModeKind {
        value == "plan" ? .plan : .default
    }

    private static func reasoningEffort(
        from thread: DexNativeOrchestrationThread
    ) -> String? {
        thread.modelSelection?.options?.codex?.reasoningEffort?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private static func effectiveApprovalPolicy(from runtimeMode: String) -> AppAskForApproval? {
        switch runtimeMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "approval-required":
            return .unlessTrusted
        case "auto-accept-edits":
            return .onRequest
        case "full-access":
            return .never
        default:
            return nil
        }
    }

    private static func effectiveSandboxPolicy(from runtimeMode: String) -> AppSandboxPolicy? {
        switch runtimeMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "approval-required":
            return .readOnly(
                access: .restricted(includePlatformDefaults: true, readableRoots: []),
                networkAccess: false
            )
        case "auto-accept-edits":
            return .workspaceWrite(
                writableRoots: [],
                readOnlyAccess: .fullAccess,
                networkAccess: true,
                excludeTmpdirEnvVar: false,
                excludeSlashTmp: false
            )
        case "full-access":
            return .dangerFullAccess
        default:
            return nil
        }
    }

    private static func syntheticAvailableModels(
        from snapshot: DexNativeThreadSnapshot
    ) -> [ModelInfo]? {
        let currentModel = snapshot.summary.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentModel.isEmpty else { return nil }

        let defaultEffort = ReasoningEffort(
            wireValue: reasoningEffort(from: snapshot.thread)
        ) ?? .medium

        return [
            ModelInfo(
                id: currentModel,
                model: currentModel,
                upgrade: nil,
                upgradeModel: nil,
                upgradeCopy: nil,
                modelLink: nil,
                migrationMarkdown: nil,
                availabilityNuxMessage: nil,
                displayName: currentModel,
                description: "Current Dex model",
                hidden: false,
                supportedReasoningEfforts: [
                    ReasoningEffortOption(reasoningEffort: .low, description: "Fast"),
                    ReasoningEffortOption(reasoningEffort: .medium, description: "Balanced"),
                    ReasoningEffortOption(reasoningEffort: .high, description: "Deeper reasoning"),
                    ReasoningEffortOption(reasoningEffort: .xHigh, description: "Maximum reasoning"),
                ],
                defaultReasoningEffort: defaultEffort,
                inputModalities: [.text, .image],
                supportsPersonality: true,
                isDefault: true
            ),
        ]
    }

    private static func approvalKind(from value: String?) -> ApprovalKind {
        switch value {
        case "file-change":
            return .fileChange
        case "file-read":
            return .permissions
        default:
            return .command
        }
    }

    private static func subagentStatus(from value: String?) -> AppSubagentStatus {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pendinginit":
            return .pendingInit
        case "running":
            return .running
        case "interrupted":
            return .interrupted
        case "completed":
            return .completed
        case "errored", "error":
            return .errored
        case "shutdown", "stopped":
            return .shutdown
        default:
            return .unknown
        }
    }

    private static func hydratedConversationItems(
        from thread: DexNativeOrchestrationThread
    ) -> [HydratedConversationItem] {
        let items: [HydratedConversationItem] = thread.messages.enumerated().map { index, message in
            let content: HydratedConversationItemContent =
                if message.role == "assistant" {
                    .assistant(
                        HydratedAssistantMessageData(
                            text: message.text,
                            agentNickname: nil,
                            agentRole: nil,
                            phase: nil
                        )
                    )
                } else {
                    .user(
                        HydratedUserMessageData(
                            text: message.text,
                            imageDataUris: []
                        )
                    )
                }

            return HydratedConversationItem(
                id: message.id,
                content: content,
                sourceTurnId: message.turnId,
                sourceTurnIndex: UInt32(index),
                timestamp: nil,
                isFromUserTurnBoundary: message.role == "user"
            )
        }

        return items
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
