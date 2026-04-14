import { Effect, Schema } from "effect";

import { IsoDateTime, ProjectId, TrimmedNonEmptyString } from "./baseSchemas";
import { ExecutionEnvironmentDescriptor, ScopedThreadRef } from "./environment";
import {
  OrchestrationThread,
  ProviderInteractionMode,
  RuntimeMode,
} from "./orchestration";

export const CompanionNativeProjectShell = Schema.Struct({
  id: ProjectId,
  title: TrimmedNonEmptyString,
  workspaceRoot: TrimmedNonEmptyString,
});
export type CompanionNativeProjectShell = typeof CompanionNativeProjectShell.Type;

export const CompanionNativeSessionSummary = Schema.Struct({
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
export type CompanionNativeSessionSummary = typeof CompanionNativeSessionSummary.Type;

export const CompanionNativeShellSnapshot = Schema.Struct({
  environment: ExecutionEnvironmentDescriptor,
  projects: Schema.Array(CompanionNativeProjectShell),
  sessionSummaries: Schema.Array(CompanionNativeSessionSummary),
  updatedAt: IsoDateTime,
});
export type CompanionNativeShellSnapshot = typeof CompanionNativeShellSnapshot.Type;

export const CompanionNativeApprovalRequestKind = Schema.Literals([
  "command",
  "file-read",
  "file-change",
]);
export type CompanionNativeApprovalRequestKind = typeof CompanionNativeApprovalRequestKind.Type;

export const CompanionNativePendingApproval = Schema.Struct({
  requestId: TrimmedNonEmptyString,
  turnId: Schema.NullOr(TrimmedNonEmptyString),
  requestKind: Schema.NullOr(CompanionNativeApprovalRequestKind),
  requestType: Schema.NullOr(TrimmedNonEmptyString),
  detail: Schema.NullOr(Schema.String),
  createdAt: IsoDateTime,
});
export type CompanionNativePendingApproval = typeof CompanionNativePendingApproval.Type;

export const CompanionNativeUserInputOption = Schema.Struct({
  label: TrimmedNonEmptyString,
  description: Schema.NullOr(Schema.String),
});
export type CompanionNativeUserInputOption = typeof CompanionNativeUserInputOption.Type;

export const CompanionNativeUserInputQuestion = Schema.Struct({
  id: TrimmedNonEmptyString,
  header: Schema.NullOr(Schema.String),
  question: TrimmedNonEmptyString,
  options: Schema.Array(CompanionNativeUserInputOption),
  multiSelect: Schema.Boolean,
});
export type CompanionNativeUserInputQuestion = typeof CompanionNativeUserInputQuestion.Type;

export const CompanionNativePendingUserInput = Schema.Struct({
  requestId: TrimmedNonEmptyString,
  turnId: Schema.NullOr(TrimmedNonEmptyString),
  createdAt: IsoDateTime,
  questions: Schema.Array(CompanionNativeUserInputQuestion),
});
export type CompanionNativePendingUserInput = typeof CompanionNativePendingUserInput.Type;

export const CompanionNativeThreadSnapshot = Schema.Struct({
  environment: ExecutionEnvironmentDescriptor,
  summary: CompanionNativeSessionSummary,
  thread: OrchestrationThread,
  pendingApprovals: Schema.Array(CompanionNativePendingApproval),
  pendingUserInputs: Schema.Array(CompanionNativePendingUserInput),
  updatedAt: IsoDateTime,
});
export type CompanionNativeThreadSnapshot = typeof CompanionNativeThreadSnapshot.Type;
