import * as ChildProcess from "node:child_process";
import * as Crypto from "node:crypto";
import * as Path from "node:path";

import readline from "node:readline";
import {
  CommandId,
  DEFAULT_MODEL_BY_PROVIDER,
  EventId,
  MessageId,
  type OrchestrationThreadActivity,
  ProjectId,
  ServerImportCodexThreadsError,
  ThreadId,
  TurnId,
  type ModelSelection,
  type OrchestrationCommand,
  type OrchestrationMessage,
  type OrchestrationReadModel,
  type ServerImportCodexThreadsResult,
} from "@dex/contracts";
import { Cause, Effect } from "effect";
import { buildCodexInitializeParams, killCodexChildProcess } from "./provider/codexAppServer";
import type { ProviderRuntimeBinding } from "./provider/Services/ProviderSessionDirectory";

const CODEX_IMPORT_PROJECT_PREFIX = "codex-project:";
const CODEX_IMPORT_THREAD_PREFIX = "codex-import:";
const CODEX_IMPORT_MESSAGE_PREFIX = "codex-import-message:";
const CODEX_IMPORT_ACTIVITY_PREFIX = "codex-import-activity:";
const CODEX_IMPORT_TURN_PREFIX = "codex-import-turn:";
const DEFAULT_IMPORT_RUNTIME_MODE = "full-access" as const;
const DEFAULT_IMPORT_INTERACTION_MODE = "default" as const;
const THREAD_LIST_PAGE_SIZE = 100;
const ALL_THREAD_SOURCE_KINDS = [
  "cli",
  "vscode",
  "exec",
  "appServer",
  "subAgent",
  "subAgentReview",
  "subAgentCompact",
  "subAgentThreadSpawn",
  "subAgentOther",
  "unknown",
] as const;

interface JsonRpcResponse {
  readonly id?: unknown;
  readonly result?: unknown;
  readonly error?: {
    readonly message?: unknown;
  };
}

interface CodexPersistedTurn {
  readonly id: string;
  readonly items: ReadonlyArray<unknown>;
}

export interface CodexPersistedThread {
  readonly providerThreadId: string;
  readonly preview: string;
  readonly createdAt: string;
  readonly updatedAt: string;
  readonly cwd: string;
  readonly cliVersion: string | null;
  readonly name: string | null;
  readonly branch: string | null;
  readonly archived: boolean;
  readonly ephemeral: boolean;
  readonly turns: ReadonlyArray<CodexPersistedTurn>;
}

interface ImportCodexThreadsInput {
  readonly binaryPath: string;
  readonly homePath?: string;
  readonly readModel: OrchestrationReadModel;
  readonly dispatchCommand: (
    command: OrchestrationCommand,
  ) => Effect.Effect<{ sequence: number }, Error>;
  readonly upsertProviderBinding: (binding: ProviderRuntimeBinding) => Effect.Effect<void, Error>;
  readonly loadThreads?: (input: {
    readonly binaryPath: string;
    readonly homePath?: string;
  }) => Promise<ReadonlyArray<CodexPersistedThread>>;
}

interface CodexRpcClient {
  readonly request: (method: string, params?: unknown) => Promise<unknown>;
}

interface CodexThreadSummary {
  readonly id: string;
  readonly preview: string;
  readonly createdAt: string;
  readonly updatedAt: string;
  readonly path: string | null;
  readonly cwd: string;
  readonly cliVersion: string | null;
  readonly name: string | null;
  readonly branch: string | null;
  readonly archived: boolean;
  readonly ephemeral: boolean;
}

type ImportedTimelineEntry =
  | {
      readonly kind: "message";
      readonly role: OrchestrationMessage["role"];
      readonly id: MessageId;
      readonly text: string;
      readonly turnId: TurnId | null;
    }
  | {
      readonly kind: "activity";
      readonly activity: Omit<OrchestrationThreadActivity, "createdAt">;
    };

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function readString(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function readBoolean(value: unknown): boolean | undefined {
  return typeof value === "boolean" ? value : undefined;
}

function readNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function readArray(value: unknown): ReadonlyArray<unknown> {
  return Array.isArray(value) ? value : [];
}

function nonEmptyTrimmed(value: unknown): string | undefined {
  const trimmed = readString(value)?.trim();
  return trimmed && trimmed.length > 0 ? trimmed : undefined;
}

function stableHash(parts: ReadonlyArray<string>): string {
  return Crypto.createHash("sha1").update(parts.join("\x1f")).digest("hex").slice(0, 12);
}

function unixSecondsToIso(rawSeconds: number | undefined): string {
  const milliseconds =
    rawSeconds !== undefined && Number.isFinite(rawSeconds)
      ? Math.max(0, rawSeconds) * 1000
      : Date.now();
  return new Date(milliseconds).toISOString();
}

function normalizeTimestampRange(
  startIso: string,
  endIso: string,
): { startMs: number; endMs: number } {
  const parsedStart = Date.parse(startIso);
  const parsedEnd = Date.parse(endIso);
  const startMs = Number.isFinite(parsedStart) ? parsedStart : Date.now();
  const endMs = Number.isFinite(parsedEnd) ? Math.max(startMs, parsedEnd) : startMs;
  return { startMs, endMs };
}

function spreadTimestamps(count: number, startIso: string, endIso: string): ReadonlyArray<string> {
  if (count <= 0) {
    return [];
  }

  const { startMs, endMs } = normalizeTimestampRange(startIso, endIso);
  if (count === 1) {
    return [new Date(endMs).toISOString()];
  }

  const span = endMs - startMs;
  return Array.from({ length: count }, (_value, index) => {
    const nextMs = span <= 0 ? startMs + index : startMs + Math.round((span * index) / (count - 1));
    return new Date(nextMs).toISOString();
  });
}

function summarizeImageAttachments(imageCount: number): string | null {
  if (imageCount <= 0) {
    return null;
  }
  return `[Attached ${imageCount} image${imageCount === 1 ? "" : "s"}]`;
}

function extractUserMessageText(content: ReadonlyArray<unknown>): string | null {
  const textParts: string[] = [];
  let imageCount = 0;

  for (const entry of content) {
    const record = isRecord(entry) ? entry : null;
    const type = readString(record?.type)?.toLowerCase();
    switch (type) {
      case "text": {
        const text = readString(record?.text);
        if (typeof text === "string" && text.length > 0) {
          textParts.push(text);
        }
        break;
      }
      case "image":
      case "localimage":
        imageCount += 1;
        break;
      default:
        break;
    }
  }

  const attachmentSummary = summarizeImageAttachments(imageCount);
  if (textParts.length === 0) {
    return attachmentSummary;
  }

  const joinedText = textParts.join("\n\n");
  if (!attachmentSummary) {
    return joinedText;
  }
  return `${joinedText}\n\n${attachmentSummary}`;
}

function deriveImportThreadTitle(input: {
  readonly cwd: string;
  readonly name: string | null;
  readonly preview: string;
}): string {
  const explicitName = input.name?.trim();
  if (explicitName) {
    return explicitName;
  }

  const previewLine = input.preview
    .split(/\r?\n/u)
    .map((line) => line.trim())
    .find((line) => line.length > 0);
  if (previewLine) {
    return previewLine.slice(0, 120);
  }

  const cwdBaseName = Path.basename(input.cwd).trim();
  return cwdBaseName.length > 0 ? cwdBaseName : "Imported Codex thread";
}

function deriveImportProjectTitle(workspaceRoot: string): string {
  const cwdBaseName = Path.basename(workspaceRoot).trim();
  return cwdBaseName.length > 0 ? cwdBaseName : "Imported Codex";
}

export function deriveCodexImportProjectId(workspaceRoot: string): ProjectId {
  return ProjectId.make(`${CODEX_IMPORT_PROJECT_PREFIX}${stableHash([workspaceRoot])}`);
}

export function deriveCodexImportThreadId(providerThreadId: string): ThreadId {
  return ThreadId.make(`${CODEX_IMPORT_THREAD_PREFIX}${providerThreadId}`);
}

function deriveCodexImportTurnId(
  providerThreadId: string,
  rawTurnId: string | undefined,
  turnIndex: number,
): TurnId {
  return TurnId.make(
    `${CODEX_IMPORT_TURN_PREFIX}${providerThreadId}:${rawTurnId?.trim() || String(turnIndex + 1)}`,
  );
}

function deriveCodexImportMessageId(
  providerThreadId: string,
  rawMessageId: string | undefined,
  role: OrchestrationMessage["role"],
  turnIndex: number,
  itemIndex: number,
): MessageId {
  const fallbackId = `${role}-${turnIndex + 1}-${itemIndex + 1}`;
  return MessageId.make(
    `${CODEX_IMPORT_MESSAGE_PREFIX}${providerThreadId}:${rawMessageId?.trim() || fallbackId}`,
  );
}

function deriveCodexImportActivityId(
  providerThreadId: string,
  rawItemId: string | undefined,
  kind: string,
  turnIndex: number,
  itemIndex: number,
): EventId {
  const fallbackId = `${kind}:${turnIndex + 1}:${itemIndex + 1}`;
  return EventId.make(
    `${CODEX_IMPORT_ACTIVITY_PREFIX}${providerThreadId}:${rawItemId?.trim() || fallbackId}`,
  );
}

function createImportCommandId(kind: string, ...parts: ReadonlyArray<string>): CommandId {
  return CommandId.make(`${CODEX_IMPORT_THREAD_PREFIX}${kind}:${stableHash([kind, ...parts])}`);
}

export function extractCodexImportMessages(input: {
  readonly providerThreadId: string;
  readonly turns: ReadonlyArray<CodexPersistedTurn>;
  readonly createdAt: string;
  readonly updatedAt: string;
}): ReadonlyArray<OrchestrationMessage> {
  return extractCodexImportTimeline(input).messages;
}

export function extractCodexImportActivities(input: {
  readonly providerThreadId: string;
  readonly turns: ReadonlyArray<CodexPersistedTurn>;
  readonly createdAt: string;
  readonly updatedAt: string;
}): ReadonlyArray<OrchestrationThreadActivity> {
  return extractCodexImportTimeline(input).activities;
}

function readStringArray(value: unknown): ReadonlyArray<string> {
  return readArray(value)
    .map((entry) => readString(entry)?.trim())
    .filter((entry): entry is string => Boolean(entry && entry.length > 0));
}

function joinNonEmpty(parts: ReadonlyArray<string>, separator = "\n\n"): string | null {
  const filtered = parts.map((part) => part.trim()).filter((part) => part.length > 0);
  return filtered.length > 0 ? filtered.join(separator) : null;
}

function parsePlanSteps(
  text: string,
): ReadonlyArray<{ readonly step: string; readonly status: "pending" | "completed" }> {
  const steps: Array<{ readonly step: string; readonly status: "pending" | "completed" }> = [];
  for (const rawLine of text.split(/\r?\n/u)) {
    const line = rawLine.trim();
    if (line.length === 0) continue;

    const completed = line.match(/^[-*+]\s+\[(x|X)\]\s+(.*)$/u);
    if (completed) {
      const step = completed[2]?.trim();
      if (step) {
        steps.push({ step, status: "completed" });
      }
      continue;
    }

    const pendingCheckbox = line.match(/^[-*+]\s+\[\s*\]\s+(.*)$/u);
    if (pendingCheckbox) {
      const step = pendingCheckbox[1]?.trim();
      if (step) {
        steps.push({ step, status: "pending" });
      }
      continue;
    }

    const bullet = line.match(/^[-*+]\s+(.*)$/u);
    if (bullet) {
      const step = bullet[1]?.trim();
      if (step) {
        steps.push({ step, status: "pending" });
      }
      continue;
    }

    const numbered = line.match(/^\d+\.\s+(.*)$/u);
    if (numbered) {
      const step = numbered[1]?.trim();
      if (step) {
        steps.push({ step, status: "pending" });
      }
    }
  }

  if (steps.length > 0) {
    return steps;
  }

  const trimmed = text.trim();
  return trimmed ? [{ step: trimmed.slice(0, 160), status: "pending" }] : [];
}

function summarizeFileChanges(changes: ReadonlyArray<unknown>): string | null {
  const paths = changes
    .map((change) =>
      isRecord(change) ? (nonEmptyTrimmed(change.path) ?? nonEmptyTrimmed(change.newPath)) : null,
    )
    .filter((entry): entry is string => entry !== null);
  if (paths.length === 0) {
    return null;
  }
  const preview = paths.slice(0, 3).join(", ");
  return paths.length > 3 ? `${preview} (+${paths.length - 3} more)` : preview;
}

function toolActivityKindFromStatus(status: string | undefined): "tool.updated" | "tool.completed" {
  switch (status?.toLowerCase()) {
    case "inprogress":
    case "in_progress":
    case "running":
    case "pending":
      return "tool.updated";
    default:
      return "tool.completed";
  }
}

function summarizeThreadItemDetail(record: Record<string, unknown>, type: string): string | null {
  switch (type) {
    case "reasoning":
      return joinNonEmpty([...readStringArray(record.summary), ...readStringArray(record.content)]);
    case "plan":
      return nonEmptyTrimmed(record.text) ?? null;
    case "commandexecution":
      return (
        nonEmptyTrimmed(record.command) ??
        nonEmptyTrimmed(record.aggregatedOutput) ??
        nonEmptyTrimmed(record.aggregated_output) ??
        null
      );
    case "filechange":
      return summarizeFileChanges(readArray(record.changes));
    case "mcptoolcall":
      return joinNonEmpty(
        [nonEmptyTrimmed(record.server) ?? "", nonEmptyTrimmed(record.tool) ?? ""],
        " / ",
      );
    case "dynamictoolcall":
      return nonEmptyTrimmed(record.tool) ?? null;
    case "collabagenttoolcall":
      return nonEmptyTrimmed(record.prompt) ?? null;
    default:
      return (
        nonEmptyTrimmed(record.text) ??
        nonEmptyTrimmed(record.query) ??
        nonEmptyTrimmed(record.path) ??
        nonEmptyTrimmed(record.prompt) ??
        null
      );
  }
}

function buildToolActivityEntry(input: {
  readonly providerThreadId: string;
  readonly itemId: string | undefined;
  readonly kindSuffix: string;
  readonly turnIndex: number;
  readonly itemIndex: number;
  readonly turnId: TurnId;
  readonly summary: string;
  readonly title: string;
  readonly itemType:
    | "command_execution"
    | "file_change"
    | "mcp_tool_call"
    | "dynamic_tool_call"
    | "collab_agent_tool_call"
    | "web_search"
    | "image_view";
  readonly detail: string | null;
  readonly payloadData?: Record<string, unknown>;
  readonly status: string | undefined;
}): ImportedTimelineEntry {
  return {
    kind: "activity",
    activity: {
      id: deriveCodexImportActivityId(
        input.providerThreadId,
        input.itemId,
        input.kindSuffix,
        input.turnIndex,
        input.itemIndex,
      ),
      tone: "tool",
      kind: toolActivityKindFromStatus(input.status),
      summary: input.summary,
      payload: {
        itemType: input.itemType,
        title: input.title,
        ...(input.detail ? { detail: input.detail } : {}),
        ...(input.payloadData ? { data: input.payloadData } : {}),
        importedFrom: "codex",
      },
      turnId: input.turnId,
    },
  };
}

function buildImportedActivityEntry(input: {
  readonly providerThreadId: string;
  readonly turnId: TurnId;
  readonly turnIndex: number;
  readonly itemIndex: number;
  readonly item: Record<string, unknown>;
}): ImportedTimelineEntry | null {
  const type = readString(input.item.type)?.toLowerCase();
  if (!type) {
    return null;
  }

  const itemId = readString(input.item.id);
  const detail = summarizeThreadItemDetail(input.item, type);

  switch (type) {
    case "plan": {
      const planText = nonEmptyTrimmed(input.item.text);
      if (!planText) return null;
      return {
        kind: "activity",
        activity: {
          id: deriveCodexImportActivityId(
            input.providerThreadId,
            itemId,
            "plan",
            input.turnIndex,
            input.itemIndex,
          ),
          tone: "info",
          kind: "turn.plan.updated",
          summary: "Plan updated",
          payload: {
            detail: planText,
            plan: parsePlanSteps(planText),
            importedFrom: "codex",
          },
          turnId: input.turnId,
        },
      };
    }

    case "reasoning": {
      if (!detail) return null;
      return {
        kind: "activity",
        activity: {
          id: deriveCodexImportActivityId(
            input.providerThreadId,
            itemId,
            "reasoning",
            input.turnIndex,
            input.itemIndex,
          ),
          tone: "info",
          kind: "task.progress",
          summary: "Reasoning update",
          payload: {
            detail,
            importedFrom: "codex",
          },
          turnId: input.turnId,
        },
      };
    }

    case "commandexecution": {
      const command = nonEmptyTrimmed(input.item.command);
      return {
        kind: "activity",
        activity: {
          id: deriveCodexImportActivityId(
            input.providerThreadId,
            itemId,
            "command",
            input.turnIndex,
            input.itemIndex,
          ),
          tone: "tool",
          kind: toolActivityKindFromStatus(nonEmptyTrimmed(input.item.status) ?? undefined),
          summary: "Ran command",
          payload: {
            itemType: "command_execution",
            title: "Ran command",
            ...(detail ? { detail } : {}),
            data: {
              item: {
                ...(command ? { command } : {}),
                ...(nonEmptyTrimmed(input.item.cwd)
                  ? { cwd: nonEmptyTrimmed(input.item.cwd) }
                  : {}),
                ...(nonEmptyTrimmed(input.item.aggregatedOutput) ||
                nonEmptyTrimmed(input.item.aggregated_output)
                  ? {
                      aggregatedOutput:
                        nonEmptyTrimmed(input.item.aggregatedOutput) ??
                        nonEmptyTrimmed(input.item.aggregated_output),
                    }
                  : {}),
                ...(readNumber(input.item.exitCode) !== undefined
                  ? { exitCode: readNumber(input.item.exitCode) }
                  : readNumber(input.item.exit_code) !== undefined
                    ? { exitCode: readNumber(input.item.exit_code) }
                    : {}),
              },
            },
            importedFrom: "codex",
          },
          turnId: input.turnId,
        },
      };
    }

    case "filechange": {
      const changes = readArray(input.item.changes);
      return buildToolActivityEntry({
        providerThreadId: input.providerThreadId,
        itemId,
        kindSuffix: "file-change",
        turnIndex: input.turnIndex,
        itemIndex: input.itemIndex,
        turnId: input.turnId,
        summary: "File change",
        title: "File change",
        itemType: "file_change",
        detail,
        status: undefined,
        payloadData: {
          changes,
        },
      });
    }

    case "mcptoolcall":
      return buildToolActivityEntry({
        providerThreadId: input.providerThreadId,
        itemId,
        kindSuffix: "mcp-tool",
        turnIndex: input.turnIndex,
        itemIndex: input.itemIndex,
        turnId: input.turnId,
        summary: "MCP tool call",
        title:
          [nonEmptyTrimmed(input.item.tool), nonEmptyTrimmed(input.item.server)]
            .filter((value): value is string => value !== undefined)
            .join(" / ") || "MCP tool call",
        itemType: "mcp_tool_call",
        detail,
        status: nonEmptyTrimmed(input.item.status) ?? undefined,
        payloadData: {
          item: {
            ...(nonEmptyTrimmed(input.item.server)
              ? { server: nonEmptyTrimmed(input.item.server) }
              : {}),
            ...(nonEmptyTrimmed(input.item.tool) ? { tool: nonEmptyTrimmed(input.item.tool) } : {}),
            ...(input.item.arguments !== undefined ? { arguments: input.item.arguments } : {}),
            ...(input.item.result !== undefined ? { result: input.item.result } : {}),
            ...(input.item.error !== undefined ? { error: input.item.error } : {}),
          },
        },
      });

    case "dynamictoolcall":
      return buildToolActivityEntry({
        providerThreadId: input.providerThreadId,
        itemId,
        kindSuffix: "dynamic-tool",
        turnIndex: input.turnIndex,
        itemIndex: input.itemIndex,
        turnId: input.turnId,
        summary: "Tool call",
        title: nonEmptyTrimmed(input.item.tool) ?? "Tool call",
        itemType: "dynamic_tool_call",
        detail,
        status: nonEmptyTrimmed(input.item.status) ?? undefined,
        payloadData: {
          item: {
            ...(nonEmptyTrimmed(input.item.tool) ? { tool: nonEmptyTrimmed(input.item.tool) } : {}),
            ...(input.item.arguments !== undefined ? { arguments: input.item.arguments } : {}),
            ...(input.item.content_items !== undefined
              ? { contentItems: input.item.content_items }
              : {}),
            ...(input.item.success !== undefined ? { success: input.item.success } : {}),
          },
        },
      });

    case "collabagenttoolcall":
      return buildToolActivityEntry({
        providerThreadId: input.providerThreadId,
        itemId,
        kindSuffix: "collab-tool",
        turnIndex: input.turnIndex,
        itemIndex: input.itemIndex,
        turnId: input.turnId,
        summary: "Collaboration tool call",
        title: nonEmptyTrimmed(input.item.tool) ?? "Collaboration tool call",
        itemType: "collab_agent_tool_call",
        detail,
        status: nonEmptyTrimmed(input.item.status) ?? undefined,
        payloadData: {
          item: {
            ...(nonEmptyTrimmed(input.item.tool) ? { tool: nonEmptyTrimmed(input.item.tool) } : {}),
            ...(input.item.prompt !== undefined ? { prompt: input.item.prompt } : {}),
            ...(input.item.receiver_thread_ids !== undefined
              ? { receiverThreadIds: input.item.receiver_thread_ids }
              : {}),
          },
        },
      });

    case "websearch":
      return buildToolActivityEntry({
        providerThreadId: input.providerThreadId,
        itemId,
        kindSuffix: "web-search",
        turnIndex: input.turnIndex,
        itemIndex: input.itemIndex,
        turnId: input.turnId,
        summary: "Web search",
        title: "Web search",
        itemType: "web_search",
        detail,
        status: undefined,
        payloadData: {
          item: {
            ...(nonEmptyTrimmed(input.item.query)
              ? { query: nonEmptyTrimmed(input.item.query) }
              : {}),
            ...(input.item.action !== undefined ? { action: input.item.action } : {}),
          },
        },
      });

    case "imageview":
      return buildToolActivityEntry({
        providerThreadId: input.providerThreadId,
        itemId,
        kindSuffix: "image-view",
        turnIndex: input.turnIndex,
        itemIndex: input.itemIndex,
        turnId: input.turnId,
        summary: "Image view",
        title: "Image view",
        itemType: "image_view",
        detail,
        status: undefined,
        payloadData: {
          item: nonEmptyTrimmed(input.item.path) ? { path: nonEmptyTrimmed(input.item.path) } : {},
        },
      });

    case "contextcompaction":
      return {
        kind: "activity",
        activity: {
          id: deriveCodexImportActivityId(
            input.providerThreadId,
            itemId,
            "context-compaction",
            input.turnIndex,
            input.itemIndex,
          ),
          tone: "info",
          kind: "context-compaction",
          summary: "Context compacted",
          payload: {
            importedFrom: "codex",
          },
          turnId: input.turnId,
        },
      };

    default:
      return null;
  }
}

function extractCodexImportTimeline(input: {
  readonly providerThreadId: string;
  readonly turns: ReadonlyArray<CodexPersistedTurn>;
  readonly createdAt: string;
  readonly updatedAt: string;
}): {
  readonly messages: ReadonlyArray<OrchestrationMessage>;
  readonly activities: ReadonlyArray<OrchestrationThreadActivity>;
} {
  const entries: ImportedTimelineEntry[] = [];

  input.turns.forEach((turn, turnIndex) => {
    const turnId = deriveCodexImportTurnId(input.providerThreadId, turn.id, turnIndex);

    turn.items.forEach((item, itemIndex) => {
      const record = isRecord(item) ? item : null;
      const type = readString(record?.type)?.toLowerCase();

      if (type === "usermessage") {
        const text = extractUserMessageText(readArray(record?.content));
        if (!text) {
          return;
        }

        entries.push({
          kind: "message",
          id: deriveCodexImportMessageId(
            input.providerThreadId,
            readString(record?.id),
            "user",
            turnIndex,
            itemIndex,
          ),
          role: "user",
          text,
          turnId,
        });
        return;
      }

      if (type === "agentmessage") {
        const text = readString(record?.text);
        if (typeof text !== "string" || text.length === 0) {
          return;
        }

        entries.push({
          kind: "message",
          id: deriveCodexImportMessageId(
            input.providerThreadId,
            readString(record?.id),
            "assistant",
            turnIndex,
            itemIndex,
          ),
          role: "assistant",
          text,
          turnId,
        });
        return;
      }

      const activityEntry = buildImportedActivityEntry({
        providerThreadId: input.providerThreadId,
        turnId,
        turnIndex,
        itemIndex,
        item: record ?? {},
      });
      if (activityEntry) {
        entries.push(activityEntry);
      }
    });
  });
  const timestamps = spreadTimestamps(entries.length, input.createdAt, input.updatedAt);
  const messages: OrchestrationMessage[] = [];
  const activities: OrchestrationThreadActivity[] = [];
  for (const [index, entry] of entries.entries()) {
    const timestamp = timestamps[index] ?? input.updatedAt;
    if (entry.kind === "message") {
      messages.push({
        id: entry.id,
        role: entry.role,
        text: entry.text,
        turnId: entry.turnId,
        streaming: false,
        createdAt: timestamp,
        updatedAt: timestamp,
      });
    } else {
      activities.push({
        ...entry.activity,
        createdAt: timestamp,
      });
    }
  }
  return { messages, activities };
}

async function withCodexRpcClient<T>(
  input: { readonly binaryPath: string; readonly homePath?: string },
  callback: (client: CodexRpcClient) => Promise<T>,
): Promise<T> {
  const child = ChildProcess.spawn(input.binaryPath, ["app-server"], {
    env: {
      ...process.env,
      ...(input.homePath ? { CODEX_HOME: input.homePath } : {}),
    },
    stdio: ["pipe", "pipe", "pipe"],
    shell: process.platform === "win32",
  });

  const output = readline.createInterface({ input: child.stdout });
  const stderrLines: string[] = [];
  const pending = new Map<
    number,
    {
      resolve: (value: unknown) => void;
      reject: (error: Error) => void;
    }
  >();

  let nextRequestId = 1;
  let completed = false;

  const cleanup = () => {
    output.removeAllListeners();
    output.close();
    child.removeAllListeners();
    child.stderr.removeAllListeners();
    for (const request of pending.values()) {
      request.reject(new Error("Codex app-server stopped before the request completed."));
    }
    pending.clear();
    if (!child.killed) {
      killCodexChildProcess(child);
    }
  };

  const fail = (error: unknown) => {
    if (completed) {
      return;
    }
    completed = true;
    cleanup();
    throw error instanceof Error
      ? error
      : new Error(`Codex app-server request failed: ${String(error)}`);
  };

  const request = (method: string, params?: unknown): Promise<unknown> => {
    if (!child.stdin.writable) {
      return Promise.reject(new Error("Codex app-server stdin is not writable."));
    }

    const id = nextRequestId;
    nextRequestId += 1;
    const payload = params === undefined ? { id, method } : { id, method, params };

    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      child.stdin.write(`${JSON.stringify(payload)}\n`);
    });
  };

  output.on("line", (line) => {
    let parsed: unknown;
    try {
      parsed = JSON.parse(line);
    } catch {
      return;
    }

    if (!isRecord(parsed)) {
      return;
    }

    const id = readNumber(parsed.id);
    if (id === undefined) {
      return;
    }

    const pendingRequest = pending.get(id);
    if (!pendingRequest) {
      return;
    }

    pending.delete(id);
    const response = parsed as JsonRpcResponse;
    const errorMessage = nonEmptyTrimmed(response.error?.message);
    if (errorMessage) {
      pendingRequest.reject(new Error(errorMessage));
      return;
    }

    pendingRequest.resolve(response.result);
  });

  child.stderr.on("data", (chunk: Buffer) => {
    const lines = chunk
      .toString()
      .split(/\r?\n/u)
      .map((line) => line.trim())
      .filter((line) => line.length > 0);
    stderrLines.push(...lines);
  });

  child.once("error", (error) => {
    for (const request of pending.values()) {
      request.reject(error);
    }
  });

  child.once("exit", (code, signal) => {
    if (completed) {
      return;
    }
    for (const request of pending.values()) {
      request.reject(
        new Error(
          `Codex app-server exited early (code=${code ?? "null"}, signal=${signal ?? "null"}).`,
        ),
      );
    }
  });

  try {
    await request("initialize", buildCodexInitializeParams());
    if (!child.stdin.writable) {
      throw new Error("Codex app-server closed before initialization completed.");
    }
    child.stdin.write(`${JSON.stringify({ method: "initialized" })}\n`);
    const result = await callback({ request });
    completed = true;
    cleanup();
    return result;
  } catch (error) {
    const stderrSuffix =
      stderrLines.length > 0 ? `\n\nCodex stderr:\n${stderrLines.slice(-12).join("\n")}` : "";
    return fail(
      error instanceof Error ? new Error(`${error.message}${stderrSuffix}`) : error,
    ) as never;
  }
}

function parseThreadSummary(value: unknown, archived: boolean): CodexThreadSummary | null {
  const record = isRecord(value) ? value : null;
  const providerThreadId = nonEmptyTrimmed(record?.id);
  const cwd = nonEmptyTrimmed(record?.cwd);
  if (!providerThreadId || !cwd) {
    return null;
  }

  return {
    id: providerThreadId,
    preview: readString(record?.preview) ?? "",
    createdAt: unixSecondsToIso(readNumber(record?.createdAt)),
    updatedAt: unixSecondsToIso(readNumber(record?.updatedAt)),
    path: nonEmptyTrimmed(record?.path) ?? null,
    cwd,
    cliVersion: nonEmptyTrimmed(record?.cliVersion) ?? null,
    name: nonEmptyTrimmed(record?.name) ?? null,
    branch: nonEmptyTrimmed(isRecord(record?.gitInfo) ? record?.gitInfo.branch : undefined) ?? null,
    archived,
    ephemeral: readBoolean(record?.ephemeral) ?? false,
  };
}

function parseThreadTurns(
  providerThreadId: string,
  value: unknown,
): ReadonlyArray<CodexPersistedTurn> {
  const thread =
    isRecord(value) && isRecord(value.thread) ? value.thread : isRecord(value) ? value : null;
  const turns = readArray(thread?.turns);
  return turns.map((turnValue, turnIndex) => {
    const turn = isRecord(turnValue) ? turnValue : null;
    return {
      id: nonEmptyTrimmed(turn?.id) ?? `${providerThreadId}:turn:${turnIndex + 1}`,
      items: readArray(turn?.items),
    };
  });
}

export async function loadPersistedCodexThreadsFromRpcClient(
  client: CodexRpcClient,
): Promise<ReadonlyArray<CodexPersistedThread>> {
  const summariesById = new Map<string, CodexThreadSummary>();
  for (const archived of [false, true] as const) {
    let cursor: string | null = null;
    do {
      const result = await client.request("thread/list", {
        cursor,
        limit: THREAD_LIST_PAGE_SIZE,
        sortKey: "updated_at",
        archived,
        sourceKinds: [...ALL_THREAD_SOURCE_KINDS],
      });
      const response = isRecord(result) ? result : {};
      const page = readArray(response.data).flatMap((entry) => {
        const summary = parseThreadSummary(entry, archived);
        if (!summary || summary.ephemeral) {
          return [];
        }
        return [summary];
      });
      for (const summary of page) {
        summariesById.set(summary.id, summary);
      }
      cursor = nonEmptyTrimmed(response.nextCursor) ?? null;
    } while (cursor !== null);
  }

  const threads: CodexPersistedThread[] = [];
  for (const summary of summariesById.values()) {
    try {
      const readResult = await client.request("thread/read", {
        threadId: summary.id,
        includeTurns: true,
      });
      threads.push({
        providerThreadId: summary.id,
        preview: summary.preview,
        createdAt: summary.createdAt,
        updatedAt: summary.updatedAt,
        cwd: summary.cwd,
        cliVersion: summary.cliVersion,
        name: summary.name,
        branch: summary.branch,
        archived: summary.archived,
        ephemeral: summary.ephemeral,
        turns: parseThreadTurns(summary.id, readResult),
      });
    } catch {
      // Codex can list stored threads that `thread/read` refuses to materialize
      // (for example some archived sessions). Keep the shell thread so sync can
      // still progress instead of failing all remaining imports.
      threads.push({
        providerThreadId: summary.id,
        preview: summary.preview,
        createdAt: summary.createdAt,
        updatedAt: summary.updatedAt,
        cwd: summary.cwd,
        cliVersion: summary.cliVersion,
        name: summary.name,
        branch: summary.branch,
        archived: summary.archived,
        ephemeral: summary.ephemeral,
        turns: [],
      });
    }
  }

  return threads;
}

export async function loadPersistedCodexThreads(input: {
  readonly binaryPath: string;
  readonly homePath?: string;
}): Promise<ReadonlyArray<CodexPersistedThread>> {
  return withCodexRpcClient(input, (client) => loadPersistedCodexThreadsFromRpcClient(client));
}

export function importCodexThreads(
  input: ImportCodexThreadsInput,
): Effect.Effect<ServerImportCodexThreadsResult, ServerImportCodexThreadsError> {
  const loadThreads = input.loadThreads ?? loadPersistedCodexThreads;
  return Effect.gen(function* () {
    const persistedThreads = yield* Effect.tryPromise({
      try: () =>
        loadThreads({
          binaryPath: input.binaryPath,
          ...(input.homePath ? { homePath: input.homePath } : {}),
        }),
      catch: (cause) =>
        new ServerImportCodexThreadsError({
          message:
            cause instanceof Error ? cause.message : "Failed to read persisted Codex threads.",
          cause,
        }),
    });

    const existingProjectIdsByWorkspaceRoot = new Map<string, ProjectId>();
    for (const project of input.readModel.projects) {
      if (project.deletedAt === null) {
        existingProjectIdsByWorkspaceRoot.set(project.workspaceRoot, project.id);
      }
    }

    const existingThreadIds = new Set<ThreadId>();
    const archivedThreadIds = new Set<ThreadId>();
    for (const thread of input.readModel.threads) {
      if (thread.deletedAt === null) {
        existingThreadIds.add(thread.id);
        if (thread.archivedAt !== null) {
          archivedThreadIds.add(thread.id);
        }
      }
    }

    let createdProjectCount = 0;
    let createdThreadCount = 0;
    let processedThreadCount = 0;
    let processedMessageCount = 0;
    let processedActivityCount = 0;
    let skippedThreadCount = 0;

    yield* Effect.logInfo("codex import starting", {
      binaryPath: input.binaryPath,
      hasHomePath: input.homePath !== undefined,
      existingProjectCount: existingProjectIdsByWorkspaceRoot.size,
      existingThreadCount: existingThreadIds.size,
      discoveredThreadCount: persistedThreads.length,
    });

    for (const persistedThread of persistedThreads) {
      const processed = yield* Effect.exit(
        Effect.gen(function* () {
          const workspaceRoot = persistedThread.cwd.trim();
          if (workspaceRoot.length === 0) {
            yield* Effect.logWarning("codex import skipping thread with empty workspace root", {
              providerThreadId: persistedThread.providerThreadId,
            });
            return;
          }

          let projectId = existingProjectIdsByWorkspaceRoot.get(workspaceRoot);
          if (!projectId) {
            projectId = deriveCodexImportProjectId(workspaceRoot);
            yield* input
              .dispatchCommand({
                type: "project.create",
                commandId: createImportCommandId("project", workspaceRoot),
                projectId,
                title: deriveImportProjectTitle(workspaceRoot),
                workspaceRoot,
                defaultModelSelection: {
                  provider: "codex",
                  model: DEFAULT_MODEL_BY_PROVIDER.codex,
                },
                createdAt: persistedThread.createdAt,
              })
              .pipe(
                Effect.mapError(
                  (cause) =>
                    new ServerImportCodexThreadsError({
                      message:
                        cause instanceof Error
                          ? cause.message
                          : "Failed to create imported project.",
                      cause,
                    }),
                ),
              );
            existingProjectIdsByWorkspaceRoot.set(workspaceRoot, projectId);
            createdProjectCount += 1;
          }

          const threadId = deriveCodexImportThreadId(persistedThread.providerThreadId);
          const threadExists = existingThreadIds.has(threadId);
          if (!threadExists) {
            yield* input
              .dispatchCommand({
                type: "thread.create",
                commandId: createImportCommandId("thread", persistedThread.providerThreadId),
                threadId,
                projectId,
                title: deriveImportThreadTitle({
                  cwd: workspaceRoot,
                  name: persistedThread.name,
                  preview: persistedThread.preview,
                }),
                modelSelection: {
                  provider: "codex",
                  model: DEFAULT_MODEL_BY_PROVIDER.codex,
                } satisfies ModelSelection,
                runtimeMode: DEFAULT_IMPORT_RUNTIME_MODE,
                interactionMode: DEFAULT_IMPORT_INTERACTION_MODE,
                branch: persistedThread.branch,
                worktreePath: workspaceRoot,
                createdAt: persistedThread.createdAt,
              })
              .pipe(
                Effect.mapError(
                  (cause) =>
                    new ServerImportCodexThreadsError({
                      message:
                        cause instanceof Error
                          ? cause.message
                          : "Failed to create imported thread.",
                      cause,
                    }),
                ),
              );
            existingThreadIds.add(threadId);
            createdThreadCount += 1;
          }

          yield* input
            .upsertProviderBinding({
              threadId,
              provider: "codex",
              ...(threadExists
                ? {}
                : {
                    status: "stopped",
                    runtimeMode: DEFAULT_IMPORT_RUNTIME_MODE,
                  }),
              resumeCursor: {
                threadId: persistedThread.providerThreadId,
              },
              runtimePayload: {
                importedFrom: "codex",
                providerThreadId: persistedThread.providerThreadId,
                cwd: persistedThread.cwd,
                cliVersion: persistedThread.cliVersion,
                importedAt: new Date().toISOString(),
              },
            })
            .pipe(
              Effect.mapError(
                (cause) =>
                  new ServerImportCodexThreadsError({
                    message:
                      cause instanceof Error
                        ? cause.message
                        : "Failed to persist imported provider binding.",
                    cause,
                  }),
              ),
            );

          const messages = extractCodexImportMessages({
            providerThreadId: persistedThread.providerThreadId,
            turns: persistedThread.turns,
            createdAt: persistedThread.createdAt,
            updatedAt: persistedThread.updatedAt,
          });
          const activities = extractCodexImportActivities({
            providerThreadId: persistedThread.providerThreadId,
            turns: persistedThread.turns,
            createdAt: persistedThread.createdAt,
            updatedAt: persistedThread.updatedAt,
          });

          yield* Effect.logInfo("codex import thread", {
            providerThreadId: persistedThread.providerThreadId,
            threadId,
            projectId,
            workspaceRoot,
            archived: persistedThread.archived,
            existingThread: threadExists,
            messageCount: messages.length,
            activityCount: activities.length,
          });

          for (const message of messages) {
            yield* input
              .dispatchCommand({
                type: "thread.message.upsert",
                commandId: createImportCommandId(
                  "message",
                  persistedThread.providerThreadId,
                  message.id,
                ),
                threadId,
                message,
                createdAt: message.updatedAt,
              })
              .pipe(
                Effect.mapError(
                  (cause) =>
                    new ServerImportCodexThreadsError({
                      message:
                        cause instanceof Error ? cause.message : "Failed to import thread message.",
                      cause,
                    }),
                ),
              );
          }

          for (const activity of activities) {
            yield* input
              .dispatchCommand({
                type: "thread.activity.append",
                commandId: createImportCommandId(
                  "activity",
                  persistedThread.providerThreadId,
                  activity.id,
                ),
                threadId,
                activity,
                createdAt: activity.createdAt,
              })
              .pipe(
                Effect.mapError(
                  (cause) =>
                    new ServerImportCodexThreadsError({
                      message:
                        cause instanceof Error
                          ? cause.message
                          : "Failed to import thread activity.",
                      cause,
                    }),
                ),
              );
          }

          if (persistedThread.archived && !archivedThreadIds.has(threadId)) {
            yield* input
              .dispatchCommand({
                type: "thread.archive",
                commandId: createImportCommandId(
                  "archive",
                  persistedThread.providerThreadId,
                  threadId,
                ),
                threadId,
              })
              .pipe(
                Effect.mapError(
                  (cause) =>
                    new ServerImportCodexThreadsError({
                      message:
                        cause instanceof Error
                          ? cause.message
                          : "Failed to archive imported thread.",
                      cause,
                    }),
                ),
              );
            archivedThreadIds.add(threadId);
          } else if (!persistedThread.archived && archivedThreadIds.has(threadId)) {
            yield* input
              .dispatchCommand({
                type: "thread.unarchive",
                commandId: createImportCommandId(
                  "unarchive",
                  persistedThread.providerThreadId,
                  threadId,
                ),
                threadId,
              })
              .pipe(
                Effect.mapError(
                  (cause) =>
                    new ServerImportCodexThreadsError({
                      message:
                        cause instanceof Error
                          ? cause.message
                          : "Failed to unarchive imported thread.",
                      cause,
                    }),
                ),
              );
            archivedThreadIds.delete(threadId);
          }

          processedThreadCount += 1;
          processedMessageCount += messages.length;
          processedActivityCount += activities.length;
        }),
      );

      if (processed._tag === "Failure") {
        skippedThreadCount += 1;
        yield* Effect.logWarning("codex import skipped thread after failure", {
          providerThreadId: persistedThread.providerThreadId,
          workspaceRoot: persistedThread.cwd,
          detail: Cause.pretty(processed.cause),
        });
      }
    }

    const result = {
      discoveredThreadCount: persistedThreads.length,
      processedThreadCount,
      createdProjectCount,
      createdThreadCount,
      processedMessageCount,
      processedActivityCount,
      skippedThreadCount,
    };
    yield* Effect.logInfo("codex import completed", result);
    return result;
  });
}
