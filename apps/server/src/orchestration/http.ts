import {
  ClientOrchestrationCommand,
  CompanionNativeShellSnapshot,
  CompanionNativeThreadSnapshot,
  type OrchestrationEvent,
  type OrchestrationThread,
  OrchestrationDispatchCommandError,
  OrchestrationGetSnapshotError,
  type OrchestrationReadModel,
  ThreadId,
} from "@dex/contracts";
import { Effect, Option, Stream } from "effect";
import { HttpRouter, HttpServerRequest, HttpServerResponse } from "effect/unstable/http";

import { respondToAuthError } from "../auth/http.ts";
import { ServerAuth } from "../auth/Services/ServerAuth.ts";
import { normalizeDispatchCommand } from "./Normalizer.ts";
import {
  toCompanionNativeShellSnapshot,
  toCompanionNativeThreadSnapshot,
} from "./nativeProjection.ts";
import { OrchestrationEngineService } from "./Services/OrchestrationEngine.ts";
import { ProjectionSnapshotQuery } from "./Services/ProjectionSnapshotQuery.ts";
import { ServerEnvironment } from "../environment/Services/ServerEnvironment.ts";

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

function isNativeThreadStreamEvent(event: OrchestrationEvent): boolean {
  return (
    event.aggregateKind === "thread" &&
    (event.type === "thread.meta-updated" ||
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
    const [thread, environment] = yield* Effect.all([
      projectionSnapshotQuery.getThreadDetailById(ThreadId.make(rawThreadId)).pipe(
        Effect.mapError(
          (cause) =>
            new OrchestrationGetSnapshotError({
              message: "Failed to load native companion thread snapshot.",
              cause,
            }),
        ),
      ),
      serverEnvironment.getDescriptor,
    ]);

    if (Option.isNone(thread)) {
      return HttpServerResponse.jsonUnsafe({ error: "Thread not found." }, { status: 404 });
    }

    return HttpServerResponse.jsonUnsafe(
      toCompanionNativeThreadSnapshot({
        environment,
        thread: thread.value,
      }) satisfies CompanionNativeThreadSnapshot,
      { status: 200 },
    );
  }).pipe(
    Effect.catchTag("AuthError", respondToAuthError),
    Effect.catchTag("OrchestrationGetSnapshotError", respondToOrchestrationHttpError),
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
