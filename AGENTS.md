# AGENTS.md

## Task Completion Requirements

- All of `bun fmt`, `bun lint`, and `bun typecheck` must pass before considering tasks completed.
- NEVER run `bun test`. Always use `bun run test` (runs Vitest).

## Project Snapshot

dex is a minimal web GUI for using coding agents like Codex and Claude.

This repository is a VERY EARLY WIP. Proposing sweeping changes that improve long-term maintainability is encouraged.

## Core Priorities

1. Performance first.
2. Reliability first.
3. Keep behavior predictable under load and during failures (session restarts, reconnects, partial streams).

If a tradeoff is required, choose correctness and robustness over short-term convenience.

## Maintainability

Long term maintainability is a core priority. If you add new functionality, first check if there is shared logic that can be extracted to a separate module. Duplicate logic across multiple files is a code smell and should be avoided. Don't be afraid to change existing code. Don't take shortcuts by just adding local logic to solve a problem.

## Package Roles

- `apps/server`: Node.js WebSocket server. Wraps Codex app-server (JSON-RPC over stdio), serves the React web app, and manages provider sessions.
- `apps/web`: React/Vite UI. Owns session UX, conversation/event rendering, and client-side state. Connects to the server via WebSocket.
- `apps/desktop`: Electron shell. Owns the packaged local backend lifecycle, updater, desktop secret storage, and LAN/phone reachability UX.
- `apps/ios`: Early iOS companion client. Imported baseline for pairing, remote access, and thread/session continuity work.
- `packages/contracts`: Shared effect/Schema schemas and TypeScript contracts for provider events, WebSocket protocol, and model/session types. Keep this package schema-only — no runtime logic.
- `packages/shared`: Shared runtime utilities consumed by both server and web. Uses explicit subpath exports (e.g. `@dex/shared/git`) — no barrel index.

## Codex App Server (Important)

dex is still Codex-first in architecture and product history, but the runtime is now provider-neutral enough to support both Codex and Claude through adapter boundaries. The server starts `codex app-server` (JSON-RPC over stdio) per Codex provider session, then streams structured events to the browser through WebSocket push messages.

How we use it in this codebase:

- Session startup/resume and turn lifecycle are brokered in `apps/server/src/codexAppServerManager.ts`.
- Provider routing and session ownership are coordinated in `apps/server/src/provider/Layers/ProviderService.ts` and `apps/server/src/provider/Layers/ProviderRegistry.ts`.
- WebSocket RPC routes live in `apps/server/src/ws.ts`.
- Server composition and runtime startup live in `apps/server/src/server.ts` and `apps/server/src/serverRuntimeStartup.ts`.
- The web app consumes lifecycle/config/auth state via `apps/web/src/rpc/serverState.ts` and orchestration domain events over the `orchestration.domainEvent` push channel.

Docs:

- Codex App Server docs: https://developers.openai.com/codex/sdk/#app-server

## Reference Repos

- Open-source Codex repo: https://github.com/openai/codex
- Codex-Monitor (Tauri, feature-complete, strong reference implementation): https://github.com/Dimillian/CodexMonitor

Use these as implementation references when designing protocol handling, UX flows, and operational safeguards.
