import {
  ClientOrchestrationCommand,
  CommandId,
  CompanionNativeShellSnapshot,
  CompanionNativeThreadSnapshot,
  type ExecutionEnvironmentDescriptor,
  ModelSelection,
  type OrchestrationEvent,
  type OrchestrationThread,
  OrchestrationDispatchCommandError,
  OrchestrationGetSnapshotError,
  type OrchestrationReadModel,
  ProjectId,
  ProjectSearchEntriesInput,
  ProviderInteractionMode,
  RuntimeMode,
  type ServerProviderSkill,
  ThreadId,
  TrimmedNonEmptyString,
} from "@dex/contracts";
import { Effect, Option, Schema, Stream } from "effect";
import { HttpRouter, HttpServerRequest, HttpServerResponse } from "effect/unstable/http";

import { respondToAuthError } from "../auth/http.ts";
import { ServerAuth } from "../auth/Services/ServerAuth.ts";
import { normalizeDispatchCommand } from "./Normalizer.ts";
import {
  toCompanionNativeShellSnapshot,
  toCompanionNativeThreadSnapshot,
} from "./nativeProjection.ts";
import { OrchestrationEngineService } from "./Services/OrchestrationEngine.ts";
import {
  ProjectionSnapshotQuery,
  type ProjectionSnapshotQueryShape,
} from "./Services/ProjectionSnapshotQuery.ts";
import { ServerEnvironment } from "../environment/Services/ServerEnvironment.ts";
import { WorkspaceEntries } from "../workspace/Services/WorkspaceEntries.ts";
import { ProviderRegistry } from "../provider/Services/ProviderRegistry.ts";

const respondToOrchestrationHttpError = (
  error: OrchestrationDispatchCommandError | OrchestrationGetSnapshotError,
) =>
  Effect.gen(function* () {
    if (error._tag === "OrchestrationGetSnapshotError") {
      yield* Effect.logError("orchestration http route failed", {
        message: error.message,
        cause: error.cause,
      });
      return HttpServerResponse.jsonUnsafe({ error: error.message }, { status: 500 });
    }

    return HttpServerResponse.jsonUnsafe({ error: error.message }, { status: 400 });
  });

const authenticateSession = Effect.gen(function* () {
  const request = yield* HttpServerRequest.HttpServerRequest;
  const serverAuth = yield* ServerAuth;
  return yield* serverAuth.authenticateHttpRequest(request);
});

const authenticateOwnerSession = Effect.gen(function* () {
  const session = yield* authenticateSession;
  if (session.role !== "owner") {
    return yield* new OrchestrationDispatchCommandError({
      message: "Only owner sessions can manage projects.",
    });
  }
  return session;
});

export const orchestrationSnapshotRouteLayer = HttpRouter.add(
  "GET",
  "/api/orchestration/snapshot",
  Effect.gen(function* () {
    yield* authenticateOwnerSession;
    const projectionSnapshotQuery = yield* ProjectionSnapshotQuery;
    const snapshot = yield* projectionSnapshotQuery.getSnapshot().pipe(
      Effect.mapError(
        (cause) =>
          new OrchestrationGetSnapshotError({
            message: "Failed to load orchestration snapshot.",
            cause,
          }),
      ),
    );
    return HttpServerResponse.jsonUnsafe(snapshot satisfies OrchestrationReadModel, {
      status: 200,
    });
  }).pipe(
    Effect.catchTag("OrchestrationDispatchCommandError", respondToOrchestrationHttpError),
    Effect.catchTag("OrchestrationGetSnapshotError", respondToOrchestrationHttpError),
  ),
);

export const orchestrationDispatchRouteLayer = HttpRouter.add(
  "POST",
  "/api/orchestration/dispatch",
  Effect.gen(function* () {
    yield* authenticateOwnerSession;
    const orchestrationEngine = yield* OrchestrationEngineService;
    const command = yield* HttpServerRequest.schemaBodyJson(ClientOrchestrationCommand).pipe(
      Effect.mapError(
        (cause) =>
          new OrchestrationDispatchCommandError({
            message: "Invalid orchestration command payload.",
            cause,
          }),
      ),
    );
    const normalizedCommand = yield* normalizeDispatchCommand(command);
    const result = yield* orchestrationEngine.dispatch(normalizedCommand).pipe(
      Effect.mapError(
        (cause) =>
          new OrchestrationDispatchCommandError({
            message: "Failed to dispatch orchestration command.",
            cause,
          }),
      ),
    );
    return HttpServerResponse.jsonUnsafe(result, { status: 200 });
  }).pipe(
    Effect.catchTag("AuthError", respondToAuthError),
    Effect.catchTag("OrchestrationDispatchCommandError", respondToOrchestrationHttpError),
  ),
);

const companionClientAllowedCommandTypes = new Set([
  "thread.turn.start",
  "thread.turn.interrupt",
  "thread.approval.respond",
  "thread.user-input.respond",
  "thread.session.stop",
]);

const nativeThreadStreamEncoder = new TextEncoder();

const CompanionNativeThreadCreateInput = Schema.Struct({
  projectId: ProjectId,
  title: Schema.optional(TrimmedNonEmptyString),
  modelSelection: Schema.optional(ModelSelection),
  runtimeMode: RuntimeMode.pipe(Schema.withDecodingDefault(Effect.succeed("full-access"))),
  interactionMode: ProviderInteractionMode.pipe(
    Schema.withDecodingDefault(Effect.succeed("default")),
  ),
  branch: Schema.optional(Schema.NullOr(TrimmedNonEmptyString)),
  worktreePath: Schema.optional(Schema.NullOr(TrimmedNonEmptyString)),
});

const CompanionNativeThreadConfigureInput = Schema.Struct({
  threadId: ThreadId,
  title: Schema.optional(TrimmedNonEmptyString),
  modelSelection: Schema.optional(ModelSelection),
  runtimeMode: Schema.optional(RuntimeMode),
  interactionMode: Schema.optional(ProviderInteractionMode),
});

const CompanionNativeThreadArchiveInput = Schema.Struct({
  threadId: ThreadId,
});

const CompanionNativeSkillsRequest = Schema.Struct({
  cwd: TrimmedNonEmptyString,
  forceReload: Schema.optional(Schema.Boolean),
});

function isNativeThreadStreamEvent(event: OrchestrationEvent): boolean {
  return (
    event.aggregateKind === "thread" &&
    (event.type === "thread.meta-updated" ||
      event.type === "thread.runtime-mode-set" ||
      event.type === "thread.interaction-mode-set" ||
      event.type === "thread.message-sent" ||
      event.type === "thread.turn-start-requested" ||
      event.type === "thread.turn-interrupt-requested" ||
      event.type === "thread.reverted" ||
      event.type === "thread.session-stop-requested" ||
      event.type === "thread.session-set" ||
      event.type === "thread.turn-diff-completed" ||
      event.type === "thread.activity-appended")
  );
}

export const companionShellSnapshotRouteLayer = HttpRouter.add(
  "GET",
  "/api/companion/shell",
  Effect.gen(function* () {
    yield* authenticateSession;
    const projectionSnapshotQuery = yield* ProjectionSnapshotQuery;
    const snapshot = yield* projectionSnapshotQuery.getShellSnapshot().pipe(
      Effect.mapError(
        (cause) =>
          new OrchestrationGetSnapshotError({
            message: "Failed to load companion shell snapshot.",
            cause,
          }),
      ),
    );
    return HttpServerResponse.jsonUnsafe(snapshot, { status: 200 });
  }).pipe(
    Effect.catchTag("AuthError", respondToAuthError),
    Effect.catchTag("OrchestrationGetSnapshotError", respondToOrchestrationHttpError),
  ),
);

function loadNativeThreadSnapshot(input: {
  readonly threadId: ThreadId;
  readonly projectionSnapshotQuery: ProjectionSnapshotQueryShape;
  readonly environment: ExecutionEnvironmentDescriptor;
}) {
  return input.projectionSnapshotQuery.getThreadDetailById(input.threadId).pipe(
    Effect.mapError(
      (cause) =>
        new OrchestrationGetSnapshotError({
          message: "Failed to load native companion thread snapshot.",
          cause,
        }),
    ),
    Effect.flatMap((thread) => {
      if (Option.isNone(thread)) {
        return Effect.succeed(
          HttpServerResponse.jsonUnsafe({ error: "Thread not found." }, { status: 404 }),
        );
      }

      return Effect.succeed(
        HttpServerResponse.jsonUnsafe(
          toCompanionNativeThreadSnapshot({
            environment: input.environment,
            thread: thread.value,
          }) satisfies CompanionNativeThreadSnapshot,
          { status: 200 },
        ),
      );
    }),
  );
}

export const companionThreadDetailRouteLayer = HttpRouter.add(
  "GET",
  "/api/companion/thread",
  Effect.gen(function* () {
    yield* authenticateSession;
    const request = yield* HttpServerRequest.HttpServerRequest;
    const requestUrl = HttpServerRequest.toURL(request);
    if (Option.isNone(requestUrl)) {
      return HttpServerResponse.jsonUnsafe({ error: "Invalid request URL." }, { status: 400 });
    }

    const rawThreadId = requestUrl.value.searchParams.get("threadId")?.trim();
    if (!rawThreadId) {
      return HttpServerResponse.jsonUnsafe(
        { error: "Missing threadId query parameter." },
        { status: 400 },
      );
    }

    const projectionSnapshotQuery = yield* ProjectionSnapshotQuery;
    const thread = yield* projectionSnapshotQuery
      .getThreadDetailById(ThreadId.make(rawThreadId))
      .pipe(
        Effect.mapError(
          (cause) =>
            new OrchestrationGetSnapshotError({
              message: "Failed to load companion thread detail.",
              cause,
            }),
        ),
      );

    if (Option.isNone(thread)) {
      return HttpServerResponse.jsonUnsafe({ error: "Thread not found." }, { status: 404 });
    }

    return HttpServerResponse.jsonUnsafe(thread.value, { status: 200 });
  }).pipe(
    Effect.catchTag("AuthError", respondToAuthError),
    Effect.catchTag("OrchestrationGetSnapshotError", respondToOrchestrationHttpError),
  ),
);

export const companionDispatchRouteLayer = HttpRouter.add(
  "POST",
  "/api/companion/dispatch",
  Effect.gen(function* () {
    const session = yield* authenticateSession;
    const orchestrationEngine = yield* OrchestrationEngineService;
    const command = yield* HttpServerRequest.schemaBodyJson(ClientOrchestrationCommand).pipe(
      Effect.mapError(
        (cause) =>
          new OrchestrationDispatchCommandError({
            message: "Invalid companion orchestration command payload.",
            cause,
          }),
      ),
    );

    if (session.role !== "owner" && !companionClientAllowedCommandTypes.has(command.type)) {
      return yield* new OrchestrationDispatchCommandError({
        message: `Client sessions cannot dispatch ${command.type}.`,
      });
    }

    const normalizedCommand = yield* normalizeDispatchCommand(command);
    const result = yield* orchestrationEngine.dispatch(normalizedCommand).pipe(
      Effect.mapError(
        (cause) =>
          new OrchestrationDispatchCommandError({
            message: "Failed to dispatch companion orchestration command.",
            cause,
          }),
      ),
    );
    return HttpServerResponse.jsonUnsafe(result, { status: 200 });
  }).pipe(
    Effect.catchTag("AuthError", respondToAuthError),
    Effect.catchTag("OrchestrationDispatchCommandError", respondToOrchestrationHttpError),
  ),
);

export const companionNativeShellSnapshotRouteLayer = HttpRouter.add(
  "GET",
  "/api/companion/native/shell",
  Effect.gen(function* () {
    yield* authenticateSession;
    const projectionSnapshotQuery = yield* ProjectionSnapshotQuery;
    const serverEnvironment = yield* ServerEnvironment;
    const [readModel, environment] = yield* Effect.all([
      projectionSnapshotQuery.getSnapshot().pipe(
        Effect.mapError(
          (cause) =>
            new OrchestrationGetSnapshotError({
              message: "Failed to load native companion shell snapshot.",
              cause,
            }),
        ),
      ),
      serverEnvironment.getDescriptor,
    ]);

    return HttpServerResponse.jsonUnsafe(
      toCompanionNativeShellSnapshot({
        environment,
        readModel,
      }) satisfies CompanionNativeShellSnapshot,
      { status: 200 },
    );
  }).pipe(
    Effect.catchTag("AuthError", respondToAuthError),
    Effect.catchTag("OrchestrationGetSnapshotError", respondToOrchestrationHttpError),
  ),
);

export const companionNativeThreadSnapshotRouteLayer = HttpRouter.add(
  "GET",
  "/api/companion/native/thread",
  Effect.gen(function* () {
    yield* authenticateSession;
    const request = yield* HttpServerRequest.HttpServerRequest;
    const requestUrl = HttpServerRequest.toURL(request);
    if (Option.isNone(requestUrl)) {
      return HttpServerResponse.jsonUnsafe({ error: "Invalid request URL." }, { status: 400 });
    }

    const rawThreadId = requestUrl.value.searchParams.get("threadId")?.trim();
    if (!rawThreadId) {
      return HttpServerResponse.jsonUnsafe(
        { error: "Missing threadId query parameter." },
        { status: 400 },
      );
    }

    const projectionSnapshotQuery = yield* ProjectionSnapshotQuery;
    const serverEnvironment = yield* ServerEnvironment;
    const environment = yield* serverEnvironment.getDescriptor;
    return yield* loadNativeThreadSnapshot({
      threadId: ThreadId.make(rawThreadId),
      projectionSnapshotQuery,
      environment,
    });
  }).pipe(
    Effect.catchTag("AuthError", respondToAuthError),
    Effect.catchTag("OrchestrationGetSnapshotError", respondToOrchestrationHttpError),
  ),
);

export const companionNativeThreadCreateRouteLayer = HttpRouter.add(
  "POST",
  "/api/companion/native/thread/create",
  Effect.gen(function* () {
    yield* authenticateSession;
    const orchestrationEngine = yield* OrchestrationEngineService;
    const projectionSnapshotQuery = yield* ProjectionSnapshotQuery;
    const serverEnvironment = yield* ServerEnvironment;
    const payload = yield* HttpServerRequest.schemaBodyJson(CompanionNativeThreadCreateInput).pipe(
      Effect.mapError(
        (cause) =>
          new OrchestrationDispatchCommandError({
            message: "Invalid native companion thread create payload.",
            cause,
          }),
      ),
    );

    const threadId = ThreadId.make(crypto.randomUUID());
    const createdAt = new Date().toISOString();
    yield* orchestrationEngine
      .dispatch({
        type: "thread.create",
        commandId: CommandId.make(`companion-native-create:${crypto.randomUUID()}`),
        threadId,
        projectId: payload.projectId,
        title: payload.title ?? "New Session",
        modelSelection: payload.modelSelection ?? {
          provider: "codex",
          model: "gpt-5.4",
        },
        runtimeMode: payload.runtimeMode,
        interactionMode: payload.interactionMode,
        branch: payload.branch ?? null,
        worktreePath: payload.worktreePath ?? null,
        createdAt,
      })
      .pipe(
        Effect.mapError(
          (cause) =>
            new OrchestrationDispatchCommandError({
              message: "Failed to create native companion thread.",
              cause,
            }),
        ),
      );

    const environment = yield* serverEnvironment.getDescriptor;
    return yield* loadNativeThreadSnapshot({
      threadId,
      projectionSnapshotQuery,
      environment,
    });
  }).pipe(
    Effect.catchTag("AuthError", respondToAuthError),
    Effect.catchTag("OrchestrationDispatchCommandError", respondToOrchestrationHttpError),
    Effect.catchTag("OrchestrationGetSnapshotError", respondToOrchestrationHttpError),
  ),
);

export const companionNativeThreadConfigureRouteLayer = HttpRouter.add(
  "POST",
  "/api/companion/native/thread/configure",
  Effect.gen(function* () {
    yield* authenticateSession;
    const orchestrationEngine = yield* OrchestrationEngineService;
    const projectionSnapshotQuery = yield* ProjectionSnapshotQuery;
    const serverEnvironment = yield* ServerEnvironment;
    const payload = yield* HttpServerRequest.schemaBodyJson(
      CompanionNativeThreadConfigureInput,
    ).pipe(
      Effect.mapError(
        (cause) =>
          new OrchestrationDispatchCommandError({
            message: "Invalid native companion thread configure payload.",
            cause,
          }),
      ),
    );

    const currentThread = yield* projectionSnapshotQuery.getThreadDetailById(payload.threadId).pipe(
      Effect.mapError(
        (cause) =>
          new OrchestrationGetSnapshotError({
            message: "Failed to load native companion thread snapshot.",
            cause,
          }),
      ),
    );

    if (Option.isNone(currentThread)) {
      return HttpServerResponse.jsonUnsafe({ error: "Thread not found." }, { status: 404 });
    }

    const thread = currentThread.value;
    const createdAt = new Date().toISOString();

    if (payload.title !== undefined || payload.modelSelection !== undefined) {
      yield* orchestrationEngine
        .dispatch({
          type: "thread.meta.update",
          commandId: CommandId.make(`companion-native-meta:${crypto.randomUUID()}`),
          threadId: payload.threadId,
          ...(payload.title !== undefined ? { title: payload.title } : {}),
          ...(payload.modelSelection !== undefined
            ? { modelSelection: payload.modelSelection }
            : {}),
        })
        .pipe(
          Effect.mapError(
            (cause) =>
              new OrchestrationDispatchCommandError({
                message: "Failed to update native companion thread metadata.",
                cause,
              }),
          ),
        );
    }

    if (payload.runtimeMode !== undefined && payload.runtimeMode !== thread.runtimeMode) {
      yield* orchestrationEngine
        .dispatch({
          type: "thread.runtime-mode.set",
          commandId: CommandId.make(`companion-native-runtime:${crypto.randomUUID()}`),
          threadId: payload.threadId,
          runtimeMode: payload.runtimeMode,
          createdAt,
        })
        .pipe(
          Effect.mapError(
            (cause) =>
              new OrchestrationDispatchCommandError({
                message: "Failed to update native companion runtime mode.",
                cause,
              }),
          ),
        );
    }

    if (
      payload.interactionMode !== undefined &&
      payload.interactionMode !== thread.interactionMode
    ) {
      yield* orchestrationEngine
        .dispatch({
          type: "thread.interaction-mode.set",
          commandId: CommandId.make(`companion-native-interaction:${crypto.randomUUID()}`),
          threadId: payload.threadId,
          interactionMode: payload.interactionMode,
          createdAt,
        })
        .pipe(
          Effect.mapError(
            (cause) =>
              new OrchestrationDispatchCommandError({
                message: "Failed to update native companion collaboration mode.",
                cause,
              }),
          ),
        );
    }

    const environment = yield* serverEnvironment.getDescriptor;
    return yield* loadNativeThreadSnapshot({
      threadId: payload.threadId,
      projectionSnapshotQuery,
      environment,
    });
  }).pipe(
    Effect.catchTag("AuthError", respondToAuthError),
    Effect.catchTag("OrchestrationDispatchCommandError", respondToOrchestrationHttpError),
    Effect.catchTag("OrchestrationGetSnapshotError", respondToOrchestrationHttpError),
  ),
);

export const companionNativeThreadArchiveRouteLayer = HttpRouter.add(
  "POST",
  "/api/companion/native/thread/archive",
  Effect.gen(function* () {
    yield* authenticateSession;
    const orchestrationEngine = yield* OrchestrationEngineService;
    const payload = yield* HttpServerRequest.schemaBodyJson(CompanionNativeThreadArchiveInput).pipe(
      Effect.mapError(
        (cause) =>
          new OrchestrationDispatchCommandError({
            message: "Invalid native companion thread archive payload.",
            cause,
          }),
      ),
    );

    const result = yield* orchestrationEngine
      .dispatch({
        type: "thread.archive",
        commandId: CommandId.make(`companion-native-archive:${crypto.randomUUID()}`),
        threadId: payload.threadId,
      })
      .pipe(
        Effect.mapError(
          (cause) =>
            new OrchestrationDispatchCommandError({
              message: "Failed to archive native companion thread.",
              cause,
            }),
        ),
      );

    return HttpServerResponse.jsonUnsafe(result, { status: 200 });
  }).pipe(
    Effect.catchTag("AuthError", respondToAuthError),
    Effect.catchTag("OrchestrationDispatchCommandError", respondToOrchestrationHttpError),
  ),
);

export const companionNativeFileSearchRouteLayer = HttpRouter.add(
  "POST",
  "/api/companion/native/files/search",
  Effect.gen(function* () {
    yield* authenticateSession;
    const workspaceEntries = yield* WorkspaceEntries;
    const payload = yield* HttpServerRequest.schemaBodyJson(ProjectSearchEntriesInput).pipe(
      Effect.mapError(
        (cause) =>
          new OrchestrationDispatchCommandError({
            message: "Invalid native companion file search payload.",
            cause,
          }),
      ),
    );

    const result = yield* workspaceEntries.search(payload).pipe(
      Effect.mapError(
        (cause) =>
          new OrchestrationDispatchCommandError({
            message: `Failed to search native companion files: ${cause.detail}`,
            cause,
          }),
      ),
    );

    return HttpServerResponse.jsonUnsafe(
      {
        results: result.entries.map((entry, index) => ({
          root: payload.cwd,
          path: entry.path,
          matchType: entry.kind,
          fileName: entry.path.split("/").pop() ?? entry.path,
          score: Math.max(result.entries.length - index, 1),
          indices: null,
        })),
        truncated: result.truncated,
      },
      { status: 200 },
    );
  }).pipe(
    Effect.catchTag("AuthError", respondToAuthError),
    Effect.catchTag("OrchestrationDispatchCommandError", respondToOrchestrationHttpError),
  ),
);

export const companionNativeSkillsRouteLayer = HttpRouter.add(
  "POST",
  "/api/companion/native/skills/list",
  Effect.gen(function* () {
    yield* authenticateSession;
    const providerRegistry = yield* ProviderRegistry;
    const payload = yield* HttpServerRequest.schemaBodyJson(CompanionNativeSkillsRequest).pipe(
      Effect.mapError(
        (cause) =>
          new OrchestrationDispatchCommandError({
            message: "Invalid native companion skills payload.",
            cause,
          }),
      ),
    );

    const providers = yield* (
      payload.forceReload === true
        ? providerRegistry.refresh("codex")
        : providerRegistry.getProviders
    ).pipe(
      Effect.mapError(
        (cause) =>
          new OrchestrationDispatchCommandError({
            message: "Failed to load native companion skills.",
            cause,
          }),
      ),
    );

    const codexSkills: ReadonlyArray<ServerProviderSkill> =
      providers.find((provider) => provider.provider === "codex")?.skills ?? [];

    return HttpServerResponse.jsonUnsafe(
      {
        cwd: payload.cwd,
        skills: codexSkills,
      },
      { status: 200 },
    );
  }).pipe(
    Effect.catchTag("AuthError", respondToAuthError),
    Effect.catchTag("OrchestrationDispatchCommandError", respondToOrchestrationHttpError),
  ),
);

export const companionNativeThreadStreamRouteLayer = HttpRouter.add(
  "GET",
  "/api/companion/native/thread/stream",
  Effect.gen(function* () {
    yield* authenticateSession;
    const request = yield* HttpServerRequest.HttpServerRequest;
    const requestUrl = HttpServerRequest.toURL(request);
    if (Option.isNone(requestUrl)) {
      return HttpServerResponse.jsonUnsafe({ error: "Invalid request URL." }, { status: 400 });
    }

    const rawThreadId = requestUrl.value.searchParams.get("threadId")?.trim();
    if (!rawThreadId) {
      return HttpServerResponse.jsonUnsafe(
        { error: "Missing threadId query parameter." },
        { status: 400 },
      );
    }

    const threadId = ThreadId.make(rawThreadId);
    const projectionSnapshotQuery = yield* ProjectionSnapshotQuery;
    const serverEnvironment = yield* ServerEnvironment;
    const orchestrationEngine = yield* OrchestrationEngineService;
    const environment = yield* serverEnvironment.getDescriptor;

    const initialThread = yield* projectionSnapshotQuery.getThreadDetailById(threadId).pipe(
      Effect.mapError(
        (cause) =>
          new OrchestrationGetSnapshotError({
            message: "Failed to load native companion thread snapshot.",
            cause,
          }),
      ),
    );

    if (Option.isNone(initialThread)) {
      return HttpServerResponse.jsonUnsafe({ error: "Thread not found." }, { status: 404 });
    }

    const encodeSnapshot = (thread: OrchestrationThread) =>
      nativeThreadStreamEncoder.encode(
        `${JSON.stringify(toCompanionNativeThreadSnapshot({ environment, thread }))}\n`,
      );

    const liveStream = orchestrationEngine.streamDomainEvents.pipe(
      Stream.filter(
        (event) =>
          event.aggregateKind === "thread" &&
          event.aggregateId === threadId &&
          isNativeThreadStreamEvent(event),
      ),
      Stream.mapEffect(() =>
        projectionSnapshotQuery.getThreadDetailById(threadId).pipe(
          Effect.mapError(
            (cause) =>
              new OrchestrationGetSnapshotError({
                message: "Failed to refresh native companion thread snapshot.",
                cause,
              }),
          ),
        ),
      ),
      Stream.flatMap((thread) =>
        Option.isSome(thread) ? Stream.succeed(thread.value) : Stream.empty,
      ),
      Stream.map(encodeSnapshot),
    );

    return HttpServerResponse.stream(
      Stream.concat(Stream.succeed(encodeSnapshot(initialThread.value)), liveStream),
      {
        headers: {
          "cache-control": "no-cache",
          "content-type": "application/x-ndjson; charset=utf-8",
        },
      },
    );
  }).pipe(
    Effect.catchTag("AuthError", respondToAuthError),
    Effect.catchTag("OrchestrationGetSnapshotError", respondToOrchestrationHttpError),
  ),
);
