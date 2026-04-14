import { Effect } from "effect";
import { describe, expect, it } from "vitest";
import type { OrchestrationCommand, OrchestrationReadModel } from "@dex/contracts";

import {
  deriveCodexImportProjectId,
  deriveCodexImportThreadId,
  extractCodexImportActivities,
  extractCodexImportMessages,
  importCodexThreads,
  type CodexPersistedThread,
} from "./codexThreadImport";
import type { ProviderRuntimeBinding } from "./provider/Services/ProviderSessionDirectory";

function emptyReadModel(): OrchestrationReadModel {
  return {
    snapshotSequence: 0,
    projects: [],
    threads: [],
    updatedAt: "2026-04-14T00:00:00.000Z",
  };
}

describe("extractCodexImportMessages", () => {
  it("extracts user and assistant messages from thread turns", () => {
    const messages = extractCodexImportMessages({
      providerThreadId: "thr_123",
      createdAt: "2026-01-01T00:00:00.000Z",
      updatedAt: "2026-01-01T00:10:00.000Z",
      turns: [
        {
          id: "turn-1",
          items: [
            {
              type: "userMessage",
              id: "user-1",
              content: [
                { type: "text", text: "Show me the diff" },
                { type: "localImage", path: "/tmp/screenshot.png" },
              ],
            },
            {
              type: "agentMessage",
              id: "assistant-1",
              text: "Here is the diff summary.",
            },
          ],
        },
      ],
    });

    expect(messages).toHaveLength(2);
    expect(messages[0]).toMatchObject({
      role: "user",
      text: "Show me the diff\n\n[Attached 1 image]",
      streaming: false,
    });
    expect(messages[1]).toMatchObject({
      role: "assistant",
      text: "Here is the diff summary.",
      streaming: false,
    });
    expect(messages[0]?.turnId).toBe(messages[1]?.turnId);
  });
});

describe("extractCodexImportActivities", () => {
  it("extracts plan, reasoning, and tool history as activities", () => {
    const activities = extractCodexImportActivities({
      providerThreadId: "thr_456",
      createdAt: "2026-01-01T00:00:00.000Z",
      updatedAt: "2026-01-01T00:10:00.000Z",
      turns: [
        {
          id: "turn-1",
          items: [
            {
              type: "plan",
              id: "plan-1",
              text: "- inspect logs\n- reproduce locally",
            },
            {
              type: "reasoning",
              id: "reasoning-1",
              summary: ["Comparing recent failures"],
              content: ["Looking for a common root cause"],
            },
            {
              type: "commandExecution",
              id: "cmd-1",
              command: "bun test",
              cwd: "/repo/demo",
              status: "completed",
            },
          ],
        },
      ],
    });

    expect(activities).toHaveLength(3);
    expect(activities[0]).toMatchObject({
      kind: "turn.plan.updated",
      summary: "Plan updated",
    });
    expect(activities[1]).toMatchObject({
      kind: "task.progress",
      summary: "Reasoning update",
    });
    expect(activities[2]).toMatchObject({
      kind: "tool.completed",
      summary: "Ran command",
      payload: {
        itemType: "command_execution",
      },
    });
  });
});

describe("importCodexThreads", () => {
  it("creates projects, threads, messages, activities, and provider bindings from persisted Codex history", async () => {
    const dispatchedCommands: OrchestrationCommand[] = [];
    const providerBindings: ProviderRuntimeBinding[] = [];
    const threadId = deriveCodexImportThreadId("thr_abc");
    const projectId = deriveCodexImportProjectId("/repo/demo");

    const persistedThreads: ReadonlyArray<CodexPersistedThread> = [
      {
        providerThreadId: "thr_abc",
        preview: "Investigate flaky tests",
        createdAt: "2026-02-10T10:00:00.000Z",
        updatedAt: "2026-02-10T11:00:00.000Z",
        cwd: "/repo/demo",
        cliVersion: "0.0.0",
        name: "Flaky tests",
        branch: "main",
        archived: false,
        ephemeral: false,
        turns: [
          {
            id: "turn-1",
            items: [
              {
                type: "userMessage",
                id: "msg-user",
                content: [{ type: "text", text: "Investigate flaky tests" }],
              },
              {
                type: "agentMessage",
                id: "msg-assistant",
                text: "I found two failing snapshots.",
              },
              {
                type: "plan",
                id: "plan-1",
                text: "- inspect snapshots\n- update baselines",
              },
              {
                type: "reasoning",
                id: "reasoning-1",
                summary: ["Diffing generated output"],
                content: ["Checking whether the serializer changed"],
              },
              {
                type: "commandExecution",
                id: "command-1",
                command: "bun run test",
                cwd: "/repo/demo",
                status: "completed",
              },
            ],
          },
        ],
      },
    ];

    const result = await Effect.runPromise(
      importCodexThreads({
        binaryPath: "codex",
        readModel: emptyReadModel(),
        loadThreads: async () => persistedThreads,
        dispatchCommand: (command) =>
          Effect.sync(() => {
            dispatchedCommands.push(command);
            return { sequence: dispatchedCommands.length };
          }),
        upsertProviderBinding: (binding) =>
          Effect.sync(() => {
            providerBindings.push(binding);
          }),
      }),
    );

    expect(result).toEqual({
      discoveredThreadCount: 1,
      processedThreadCount: 1,
      createdProjectCount: 1,
      createdThreadCount: 1,
      processedMessageCount: 2,
      processedActivityCount: 3,
      skippedThreadCount: 0,
    });

    expect(dispatchedCommands[0]).toMatchObject({
      type: "project.create",
      projectId,
      title: "demo",
      workspaceRoot: "/repo/demo",
    });
    expect(dispatchedCommands[1]).toMatchObject({
      type: "thread.create",
      threadId,
      projectId,
      title: "Flaky tests",
      branch: "main",
      worktreePath: "/repo/demo",
    });

    const importedMessages = dispatchedCommands.filter(
      (command): command is Extract<OrchestrationCommand, { type: "thread.message.upsert" }> =>
        command.type === "thread.message.upsert",
    );
    expect(importedMessages).toHaveLength(2);
    expect(importedMessages[0]?.message).toMatchObject({
      role: "user",
      text: "Investigate flaky tests",
    });
    expect(importedMessages[1]?.message).toMatchObject({
      role: "assistant",
      text: "I found two failing snapshots.",
    });
    const importedActivities = dispatchedCommands.filter(
      (command): command is Extract<OrchestrationCommand, { type: "thread.activity.append" }> =>
        command.type === "thread.activity.append",
    );
    expect(importedActivities).toHaveLength(3);
    expect(importedActivities.map((command) => command.activity.kind)).toEqual([
      "turn.plan.updated",
      "task.progress",
      "tool.completed",
    ]);

    expect(providerBindings).toEqual([
      expect.objectContaining({
        threadId,
        provider: "codex",
        status: "stopped",
        runtimeMode: "full-access",
        resumeCursor: {
          threadId: "thr_abc",
        },
      }),
    ]);
  });

  it("archives imported threads that came from archived Codex history", async () => {
    const dispatchedCommands: OrchestrationCommand[] = [];

    await Effect.runPromise(
      importCodexThreads({
        binaryPath: "codex",
        readModel: emptyReadModel(),
        loadThreads: async () => [
          {
            providerThreadId: "thr_archived",
            preview: "Old archived thread",
            createdAt: "2026-02-10T10:00:00.000Z",
            updatedAt: "2026-02-10T11:00:00.000Z",
            cwd: "/repo/archived",
            cliVersion: "0.0.0",
            name: "Old archived thread",
            branch: "main",
            archived: true,
            ephemeral: false,
            turns: [],
          },
        ],
        dispatchCommand: (command) =>
          Effect.sync(() => {
            dispatchedCommands.push(command);
            return { sequence: dispatchedCommands.length };
          }),
        upsertProviderBinding: () => Effect.void,
      }),
    );

    expect(
      dispatchedCommands.some(
        (command): command is Extract<OrchestrationCommand, { type: "thread.archive" }> =>
          command.type === "thread.archive",
      ),
    ).toBe(true);
  });
});
