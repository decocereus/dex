# Architecture

dex is a server-authoritative agent runtime with web, desktop, and emerging mobile clients.

At a high level:

```text
browser / desktop / phone companion
            |
            v
   apps/server (HTTP + WebSocket RPC)
            |
            v
 orchestration + git + terminal + auth + provider adapters
            |
            v
     Codex / Claude runtimes
```

## Main runtime pieces

- **Client transport**: `apps/web/src/rpc/wsTransport.ts` owns WebSocket connection state and request lifecycles.
- **Client state bootstrap**: `apps/web/src/rpc/serverState.ts` and `apps/web/src/routes/__root.tsx` hydrate lifecycle/config/auth state into the UI.
- **Browser/desktop bridge**: `apps/web/src/localApi.ts` exposes desktop-only capabilities through a typed local facade.
- **Server composition**: `apps/server/src/server.ts` composes HTTP routes, WebSocket RPC, orchestration, providers, git, terminal, auth, and persistence layers.
- **Server startup/readiness**: `apps/server/src/serverRuntimeStartup.ts` owns runtime bootstrapping before clients are welcomed.
- **WebSocket RPC**: `apps/server/src/ws.ts` routes request/response methods and publishes typed push streams.
- **Orchestration core**: `apps/server/src/orchestration/*` owns canonical command handling, event projection, receipts, and checkpoint workflows.
- **Provider boundary**: `apps/server/src/provider/Layers/*` keeps Codex and Claude specifics at the edge while exposing a shared adapter/service contract.

## Event lifecycle

### 1. Startup

1. The server composes its live layers in `apps/server/src/server.ts`.
2. `apps/server/src/serverRuntimeStartup.ts` runs startup tasks and establishes readiness.
3. `apps/server/src/ws.ts` accepts a WebSocket client only after the runtime is ready to welcome it.
4. The web client receives `server.welcome` and seeds its local runtime state through `apps/web/src/rpc/serverState.ts`.

### 2. User turn

1. The UI sends a typed RPC request through `apps/web/src/rpc/wsTransport.ts`.
2. `apps/server/src/ws.ts` routes the request to orchestration, git, workspace, settings, or provider services.
3. `ProviderService` starts or resumes a provider session and talks to the selected runtime.
4. Provider-native output is translated into canonical runtime events.
5. `ProviderRuntimeIngestion` turns those runtime events into orchestration commands.
6. `OrchestrationEngine` persists events and updates the projected read model.
7. The server pushes resulting domain events back to the client on `orchestration.domainEvent`.

### 3. Async follow-up work

Long-running follow-up work stays explicit and ordered:

- `ProviderCommandReactor` handles provider-side follow-up intent
- `CheckpointReactor` owns checkpoint capture and diff summaries
- `RuntimeReceiptBus` provides deterministic completion signals for orchestration/tests

This is part of the repo’s push toward predictable behavior under load, reconnects, and partial provider streams.

## Architectural direction

The current direction is:

- keep the server as the source of truth
- keep provider adapters thin but provider-specific
- keep orchestration contracts canonical and shared
- support multiple clients against the same environment
- extend the same authority model to remote access and the iOS companion

For the current project snapshot and roadmap, see `docs/status.md` and the active plans under `.plans/17-*`, `.plans/18-*`, `.plans/19-*`, and `.plans/20-*`.
