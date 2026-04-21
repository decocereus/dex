# Project Status

## Snapshot

dex is moving toward a server-authoritative workspace for coding agents rather than a thin local GUI around one provider.

Today that means:

- `apps/server` is the authority for orchestration, provider sessions, git, terminals, auth, and environment metadata
- `apps/web` is the main multi-environment UI
- `apps/desktop` packages the server locally and adds updater, secret storage, and remote reachability UX
- `apps/ios` is now in-repo as an early companion baseline, not yet full product parity

The repository already supports both Codex and Claude through provider adapters, but the runtime is still historically Codex-first.

## What Has Been Done So Far

### Runtime and platform

- moved the project identity from `T3 Code` to `dex`
- built a server-authoritative orchestration model with typed contracts in `packages/contracts`
- hardened the runtime around ordered orchestration, receipts, checkpointing, and restart/reconnect behavior
- implemented both Codex and Claude provider layers under a shared adapter/service model
- added remote pairing and saved-environment flows so multiple clients can attach to environments

### User-facing product work

- desktop app bundles and manages the local backend
- settings now cover provider install/auth state, connections, and remote pairing flows
- sidebar/project UX supports hiding projects, cascade cleanup, and syncing persisted Codex threads
- git/worktree flows are a first-class product surface, not an afterthought

### Mobile direction

- imported the iOS companion baseline into `apps/ios`
- documented a companion-first architecture in `.plans/19-dex-ios-companion-architecture.md`
- documented Phase 0/1 implementation direction in `.plans/20-dex-ios-phase0-phase1-implementation.md`

## What Is Left

### Product gaps

- full GUI support for remote project management is still incomplete
- the iOS companion is not yet at continuity/parity with desktop/web
- release/distribution channels still need cleanup around the rebrand

### Architecture and cleanup

- the auth model in `.plans/18-server-auth-model.md` is directionally clear but not fully productized end-to-end
- the repo still contains migration debt around mixed state access patterns, including React Query and local bridge surfaces
- historical plan docs still contain some legacy file references and old local absolute links

### Project-level decisions

- the long-term public contribution policy is still intentionally conservative
- licensing/distribution stance needs to stay explicit now that the old top-level `LICENSE` and `CONTRIBUTING.md` files are gone

## Direction

The project is clearly moving in these directions:

1. **Server-authoritative over client-authoritative**
   The server owns durable state, orchestration, and provider/runtime truth.

2. **Provider-neutral over provider-specific**
   Codex and Claude are supported today, and new providers are expected to fit the same adapter boundary rather than forcing a rewrite.

3. **Remote-capable environments over single-machine assumptions**
   Pairing, saved environments, reachability controls, and auth work all point toward first-class multi-device use.

4. **Desktop plus companion clients over one canonical shell**
   The desktop app is the strongest surface today, but the repo is explicitly heading toward a phone companion that attaches to the same authority model.

5. **Reliability and predictability over feature velocity**
   The repo priorities in `AGENTS.md` match the code: performance, robustness, and determinism come before broader scope.

## Best Plans To Read Next

- `.plans/17-provider-neutral-runtime-determinism.md`
- `.plans/17-claude-agent.md`
- `.plans/18-server-auth-model.md`
- `.plans/19-dex-ios-companion-architecture.md`
- `.plans/20-dex-ios-phase0-phase1-implementation.md`
