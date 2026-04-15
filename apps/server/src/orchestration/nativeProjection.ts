import type {
  DexMobileNativePendingApproval,
  DexMobileNativePendingUserInput,
  DexMobileNativeSessionSummary,
  DexMobileNativeShellSnapshot,
  DexMobileNativeThreadSnapshot,
  ExecutionEnvironmentDescriptor,
  OrchestrationReadModel,
  OrchestrationThread,
  OrchestrationThreadActivity,
} from "@dex/contracts";

function trimmedNonEmptyOrNull(value: string | null | undefined) {
  if (typeof value !== "string") {
    return null;
  }
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function deriveThreadPreview(thread: OrchestrationThread) {
  const latestUserMessage = thread.messages
    .toReversed()
    .find((message) => message.role === "user" && message.text.trim().length > 0);
  if (latestUserMessage) {
    return latestUserMessage.text;
  }

  const latestAssistantMessage = thread.messages
    .toReversed()
    .find((message) => message.role === "assistant" && message.text.trim().length > 0);
  if (latestAssistantMessage) {
    return latestAssistantMessage.text;
  }

  return thread.title;
}

function deriveParentThreadId(thread: OrchestrationThread) {
  const sourceProposedPlanThreadId = thread.latestTurn?.sourceProposedPlan?.threadId ?? null;
  return trimmedNonEmptyOrNull(sourceProposedPlanThreadId);
}

function deriveAgentRole(thread: OrchestrationThread) {
  return deriveParentThreadId(thread) ? "subagent" : null;
}

function deriveAgentDisplayLabel(thread: OrchestrationThread) {
  const role = deriveAgentRole(thread);
  return role ? "Subagent" : null;
}

function deriveAgentStatus(thread: OrchestrationThread) {
  const latestState = thread.latestTurn?.state ?? null;
  return trimmedNonEmptyOrNull(latestState);
}

export function toDexMobileNativeSessionSummary(input: {
  environment: ExecutionEnvironmentDescriptor;
  thread: OrchestrationThread;
}): DexMobileNativeSessionSummary {
  const { environment, thread } = input;
  const parentThreadId = deriveParentThreadId(thread);
  const model = thread.modelSelection.model.trim();
  return {
    threadRef: {
      environmentId: environment.environmentId,
      threadId: thread.id,
    },
    projectId: thread.projectId,
    title: thread.title,
    preview: deriveThreadPreview(thread),
    cwd: thread.worktreePath,
    branch: thread.branch,
    model,
    modelProvider: thread.modelSelection.provider,
    runtimeMode: thread.runtimeMode,
    interactionMode: thread.interactionMode,
    updatedAt: thread.updatedAt,
    archivedAt: thread.archivedAt ?? null,
    latestUserMessageAt:
      thread.messages
        .filter((message) => message.role === "user")
        .map((message) => message.updatedAt)
        .at(-1) ?? null,
    hasActiveTurn: thread.session?.activeTurnId !== null || thread.latestTurn?.state === "running",
    hasPendingApprovals: thread.activities.some(
      (activity) => activity.kind === "approval.requested",
    ),
    hasPendingUserInput: thread.activities.some(
      (activity) => activity.kind === "user-input.requested",
    ),
    isSubagent: parentThreadId !== null,
    isFork: parentThreadId !== null,
    parentThreadId,
    agentNickname: null,
    agentRole: deriveAgentRole(thread),
    agentDisplayLabel: deriveAgentDisplayLabel(thread),
    agentStatus: deriveAgentStatus(thread),
  };
}

function extractRequestId(activity: OrchestrationThreadActivity) {
  const payload =
    typeof activity.payload === "object" && activity.payload !== null
      ? (activity.payload as Record<string, unknown>)
      : null;
  return trimmedNonEmptyOrNull(typeof payload?.requestId === "string" ? payload.requestId : null);
}

function derivePendingApprovals(
  thread: OrchestrationThread,
): Array<DexMobileNativePendingApproval> {
  const pendingByRequestId = new Map<string, DexMobileNativePendingApproval>();

  for (const activity of thread.activities) {
    const requestId = extractRequestId(activity);
    if (!requestId) {
      continue;
    }

    const payload =
      typeof activity.payload === "object" && activity.payload !== null
        ? (activity.payload as Record<string, unknown>)
        : null;

    if (activity.kind === "approval.requested") {
      pendingByRequestId.set(requestId, {
        requestId,
        turnId: activity.turnId,
        requestKind:
          payload?.requestKind === "command" ||
          payload?.requestKind === "file-read" ||
          payload?.requestKind === "file-change"
            ? payload.requestKind
            : null,
        requestType:
          typeof payload?.requestType === "string"
            ? trimmedNonEmptyOrNull(payload.requestType)
            : null,
        detail: typeof payload?.detail === "string" ? payload.detail : null,
        createdAt: activity.createdAt,
      });
      continue;
    }

    if (activity.kind === "approval.resolved") {
      pendingByRequestId.delete(requestId);
    }
  }

  return [...pendingByRequestId.values()];
}

function derivePendingUserInputs(
  thread: OrchestrationThread,
): Array<DexMobileNativePendingUserInput> {
  const pendingByRequestId = new Map<string, DexMobileNativePendingUserInput>();

  for (const activity of thread.activities) {
    const requestId = extractRequestId(activity);
    if (!requestId) {
      continue;
    }

    const payload =
      typeof activity.payload === "object" && activity.payload !== null
        ? (activity.payload as Record<string, unknown>)
        : null;

    if (activity.kind === "user-input.requested") {
      const rawQuestions = Array.isArray(payload?.questions) ? payload.questions : [];
      pendingByRequestId.set(requestId, {
        requestId,
        turnId: activity.turnId,
        createdAt: activity.createdAt,
        questions: rawQuestions.flatMap((question) => {
          if (typeof question !== "object" || question === null) {
            return [];
          }
          const record = question as Record<string, unknown>;
          const id = trimmedNonEmptyOrNull(typeof record.id === "string" ? record.id : null);
          const prompt = trimmedNonEmptyOrNull(
            typeof record.question === "string" ? record.question : null,
          );
          if (!id || !prompt) {
            return [];
          }
          const options = Array.isArray(record.options)
            ? record.options.flatMap((option) => {
                if (typeof option !== "object" || option === null) {
                  return [];
                }
                const optionRecord = option as Record<string, unknown>;
                const label = trimmedNonEmptyOrNull(
                  typeof optionRecord.label === "string" ? optionRecord.label : null,
                );
                if (!label) {
                  return [];
                }
                return [
                  {
                    label,
                    description:
                      typeof optionRecord.description === "string"
                        ? optionRecord.description
                        : null,
                  },
                ];
              })
            : [];
          return [
            {
              id,
              header: typeof record.header === "string" ? record.header : null,
              question: prompt,
              options,
              multiSelect: record.multiSelect === true,
            },
          ];
        }),
      });
      continue;
    }

    if (activity.kind === "user-input.resolved") {
      pendingByRequestId.delete(requestId);
    }
  }

  return [...pendingByRequestId.values()];
}

export function toDexMobileNativeThreadSnapshot(input: {
  environment: ExecutionEnvironmentDescriptor;
  thread: OrchestrationThread;
}): DexMobileNativeThreadSnapshot {
  const { environment, thread } = input;
  return {
    environment,
    summary: toDexMobileNativeSessionSummary({ environment, thread }),
    thread,
    pendingApprovals: derivePendingApprovals(thread),
    pendingUserInputs: derivePendingUserInputs(thread),
    updatedAt: thread.updatedAt,
  };
}

export function toDexMobileNativeShellSnapshot(input: {
  environment: ExecutionEnvironmentDescriptor;
  readModel: OrchestrationReadModel;
}): DexMobileNativeShellSnapshot {
  const { environment, readModel } = input;
  return {
    environment,
    projects: readModel.projects
      .filter((project) => project.deletedAt === null)
      .map((project) => ({
        id: project.id,
        title: project.title,
        workspaceRoot: project.workspaceRoot,
      })),
    sessionSummaries: readModel.threads
      .filter((thread) => thread.deletedAt === null)
      .map((thread) => toDexMobileNativeSessionSummary({ environment, thread })),
    updatedAt: readModel.updatedAt,
  };
}

export const toCompanionNativeSessionSummary = toDexMobileNativeSessionSummary;
export const toCompanionNativeThreadSnapshot = toDexMobileNativeThreadSnapshot;
export const toCompanionNativeShellSnapshot = toDexMobileNativeShellSnapshot;
