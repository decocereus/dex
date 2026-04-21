# Provider architecture

The web app communicates with the server over WebSocket RPC plus typed push streams.

- request/response calls are defined in `packages/contracts/src/rpc.ts`
- browser/desktop bridging lives behind `apps/web/src/localApi.ts`
- client transport and connection state live in `apps/web/src/rpc/wsTransport.ts`
- server RPC routing lives in `apps/server/src/ws.ts`

Push channels currently include:

- `server.welcome`
- `server.configUpdated`
- `auth.access`
- `terminal.event`
- `orchestration.domainEvent`

Payloads are schema-validated at the transport boundary. Decode failures become structured transport diagnostics instead of leaking malformed runtime state into the UI.

## Implemented providers

dex currently implements two provider adapters:

- `codex`
- `claudeAgent`

The contracts and orchestration stack are intentionally provider-neutral. Provider-native lifecycle details should stay inside adapter/provider layers rather than leaking into generic transport, orchestration, or UI state.

## Current provider stack

1. `ProviderRegistry` aggregates provider snapshots and availability.
2. `ProviderService` owns session routing, start/send/interrupt/stop semantics, and persisted provider bindings.
3. Provider adapters translate provider-native runtime behavior into canonical dex events.
4. `ProviderRuntimeIngestion` converts canonical runtime events into orchestration commands.
5. `OrchestrationEngine` persists events and projects them into read models that the UI consumes.

## Design constraints

- keep provider-specific decode and resume semantics inside adapter-owned code
- keep provider selection explicit in contracts and UI state
- keep read models and orchestration receipts canonical across providers
- avoid baking Codex or Claude event names directly into generic runtime logic

This is why the repo has both provider-specific layers and a provider-neutral orchestration core.
