import { Effect, Schema } from "effect";

import { IsoDateTime, ProjectId, TrimmedNonEmptyString } from "./baseSchemas";
import { ExecutionEnvironmentDescriptor, ScopedThreadRef } from "./environment";
import { OrchestrationThread, ProviderInteractionMode, RuntimeMode } from "./orchestration";

export const DexMobileNativeProjectShell = Schema.Struct({
  id: ProjectId,
  title: TrimmedNonEmptyString,
  workspaceRoot: TrimmedNonEmptyString,
});
export type DexMobileNativeProjectShell = typeof DexMobileNativeProjectShell.Type;

export const DexMobileNativeSessionSummary = Schema.Struct({
  threadRef: ScopedThreadRef,
  projectId: ProjectId,
  title: TrimmedNonEmptyString,
  preview: Schema.String,
  cwd: Schema.NullOr(Schema.String),
  branch: Schema.NullOr(TrimmedNonEmptyString),
  model: TrimmedNonEmptyString,
  modelProvider: TrimmedNonEmptyString,
  runtimeMode: RuntimeMode,
  interactionMode: ProviderInteractionMode.pipe(
    Schema.withDecodingDefault(Effect.succeed("default")),
  ),
  updatedAt: IsoDateTime,
  archivedAt: Schema.NullOr(IsoDateTime),
  latestUserMessageAt: Schema.NullOr(IsoDateTime),
  hasActiveTurn: Schema.Boolean,
  hasPendingApprovals: Schema.Boolean,
  hasPendingUserInput: Schema.Boolean,
  isSubagent: Schema.Boolean,
  isFork: Schema.Boolean,
  parentThreadId: Schema.NullOr(TrimmedNonEmptyString),
  agentNickname: Schema.NullOr(TrimmedNonEmptyString),
  agentRole: Schema.NullOr(TrimmedNonEmptyString),
  agentDisplayLabel: Schema.NullOr(TrimmedNonEmptyString),
  agentStatus: Schema.NullOr(TrimmedNonEmptyString),
});
export type DexMobileNativeSessionSummary = typeof DexMobileNativeSessionSummary.Type;

export const DexMobileNativeShellSnapshot = Schema.Struct({
  environment: ExecutionEnvironmentDescriptor,
  projects: Schema.Array(DexMobileNativeProjectShell),
  sessionSummaries: Schema.Array(DexMobileNativeSessionSummary),
  updatedAt: IsoDateTime,
});
export type DexMobileNativeShellSnapshot = typeof DexMobileNativeShellSnapshot.Type;

export const DexMobileNativeApprovalRequestKind = Schema.Literals([
  "command",
  "file-read",
  "file-change",
]);
export type DexMobileNativeApprovalRequestKind = typeof DexMobileNativeApprovalRequestKind.Type;

export const DexMobileNativePendingApproval = Schema.Struct({
  requestId: TrimmedNonEmptyString,
  turnId: Schema.NullOr(TrimmedNonEmptyString),
  requestKind: Schema.NullOr(DexMobileNativeApprovalRequestKind),
  requestType: Schema.NullOr(TrimmedNonEmptyString),
  detail: Schema.NullOr(Schema.String),
  createdAt: IsoDateTime,
});
export type DexMobileNativePendingApproval = typeof DexMobileNativePendingApproval.Type;

export const DexMobileNativeUserInputOption = Schema.Struct({
  label: TrimmedNonEmptyString,
  description: Schema.NullOr(Schema.String),
});
export type DexMobileNativeUserInputOption = typeof DexMobileNativeUserInputOption.Type;

export const DexMobileNativeUserInputQuestion = Schema.Struct({
  id: TrimmedNonEmptyString,
  header: Schema.NullOr(Schema.String),
  question: TrimmedNonEmptyString,
  options: Schema.Array(DexMobileNativeUserInputOption),
  multiSelect: Schema.Boolean,
});
export type DexMobileNativeUserInputQuestion = typeof DexMobileNativeUserInputQuestion.Type;

export const DexMobileNativePendingUserInput = Schema.Struct({
  requestId: TrimmedNonEmptyString,
  turnId: Schema.NullOr(TrimmedNonEmptyString),
  createdAt: IsoDateTime,
  questions: Schema.Array(DexMobileNativeUserInputQuestion),
});
export type DexMobileNativePendingUserInput = typeof DexMobileNativePendingUserInput.Type;

export const DexMobileNativeThreadSnapshot = Schema.Struct({
  environment: ExecutionEnvironmentDescriptor,
  summary: DexMobileNativeSessionSummary,
  thread: OrchestrationThread,
  pendingApprovals: Schema.Array(DexMobileNativePendingApproval),
  pendingUserInputs: Schema.Array(DexMobileNativePendingUserInput),
  updatedAt: IsoDateTime,
});
export type DexMobileNativeThreadSnapshot = typeof DexMobileNativeThreadSnapshot.Type;

export const CompanionNativeProjectShell = DexMobileNativeProjectShell;
export type CompanionNativeProjectShell = DexMobileNativeProjectShell;

export const CompanionNativeSessionSummary = DexMobileNativeSessionSummary;
export type CompanionNativeSessionSummary = DexMobileNativeSessionSummary;

export const CompanionNativeShellSnapshot = DexMobileNativeShellSnapshot;
export type CompanionNativeShellSnapshot = DexMobileNativeShellSnapshot;

export const CompanionNativeApprovalRequestKind = DexMobileNativeApprovalRequestKind;
export type CompanionNativeApprovalRequestKind = DexMobileNativeApprovalRequestKind;

export const CompanionNativePendingApproval = DexMobileNativePendingApproval;
export type CompanionNativePendingApproval = DexMobileNativePendingApproval;

export const CompanionNativeUserInputOption = DexMobileNativeUserInputOption;
export type CompanionNativeUserInputOption = DexMobileNativeUserInputOption;

export const CompanionNativeUserInputQuestion = DexMobileNativeUserInputQuestion;
export type CompanionNativeUserInputQuestion = DexMobileNativeUserInputQuestion;

export const CompanionNativePendingUserInput = DexMobileNativePendingUserInput;
export type CompanionNativePendingUserInput = DexMobileNativePendingUserInput;

export const CompanionNativeThreadSnapshot = DexMobileNativeThreadSnapshot;
export type CompanionNativeThreadSnapshot = DexMobileNativeThreadSnapshot;
