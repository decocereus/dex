# Dex + iOS Companion Phase 0/1 Implementation Plan

## Purpose

Turn the architecture decisions in [19-dex-ios-companion-architecture.md](./19-dex-ios-companion-architecture.md) into an implementation-focused plan for the first two phases:

- Phase 0: import the existing iOS app into the `dex` monorepo without changing its product shape
- Phase 1: establish desktop-authoritative pairing/auth and the minimum companion API needed for iPhone text-thread continuity

This document is intentionally constrained. It does not cover:

- Codex thread import/attach implementation details
- cloud identity and subscriptions
- full mobile feature parity
- live voice continuity

## Goals

- import the current iOS app into `dex` with history preserved
- keep desktop and iOS independently buildable after import
- make iPhone capable of pairing to `dex` desktop as a trusted device
- reuse the existing `dex` auth/orchestration model where possible
- avoid introducing a second mobile authority
- define the minimum remote API surface needed for text-thread continuity

## Non-goals

- redesigning the iOS app
- rewriting the iOS Rust layer to TypeScript
- migrating Codex threads in this phase
- adding accounts, subscriptions, or cloud authority
- shipping Android or Windows companion support

## Phase 0 scope: repo import

## Recommendation

Import the iOS repo into `dex` on a dedicated integration branch before building the continuity features.

This is the right time to import because:

- the authority model is already locked
- the import can preserve the current iOS product shape
- the import itself is now mostly mechanical

## Import shape

Do not import the iOS repo root 1:1 into `dex`.

The current source repo uses top-level directories like `shared/` that would create naming confusion with existing `dex` conventions such as `packages/shared`.

Recommended destination shape inside `dex`:

- `apps/ios`
- `native/rust-bridge`
- `third_party/codex-mobile`
- `patches/codex-mobile`

Optional import destination if we want to preserve source structure more literally:

- `apps/ios`
- `shared/rust-bridge`
- `shared/third_party/codex`
- `patches/codex`

The first option is recommended because it avoids semantic collision with existing `dex` `shared` packages.

## Import content

Minimum content to import in Phase 0:

- `apps/ios`
- Rust mobile crates currently under `shared/rust-bridge`
- upstream Codex submodule reference currently under `shared/third_party/codex`
- local Codex patch set
- iOS-specific helper scripts still required by the build
- any app assets/resources required for the iOS app to compile

Do not import:

- stale Android-era documents and scripts that are already being removed upstream
- release artifacts or generated build outputs
- unrelated top-level repo policy files when `dex` already has its own equivalents

## Import mechanics

### Source selection

Do not import from a dirty working tree.

Create or identify a clean source commit in `codex-litter` that represents the intended iOS-only baseline. The import should be pinned to a specific commit hash and documented in the resulting PR/plan notes.

### History preservation

Use a history-preserving import method.

Recommended approach:

1. create a temporary export branch from the chosen `codex-litter` commit
2. use `git filter-repo` on that branch to retain only the paths we want
3. rewrite those paths into the target `dex` destination prefixes
4. merge the rewritten export branch into `dex`

Why this is recommended:

- preserves file history
- supports multi-path import in one operation
- avoids repeated subtree imports for multiple prefixes
- gives us a clean commit series for review

### Build-system coexistence

Do not make the root `dex` build depend on iOS immediately.

Phase 0 should keep the iOS build isolated:

- the current `bun`/`turbo` flow should continue working without Xcode/Rust/iOS toolchains
- iOS build entrypoints should be explicit and opt-in

Recommended initial build posture:

- keep `dex` root `package.json` and Turbo flows unchanged for web/server/desktop
- add a separate iOS-focused build entrypoint after import
- do not require `apps/ios` for `bun install`, `bun lint`, or `bun typecheck`

### Generated files

Do not commit generated Rust outputs that are currently local-only in the source repo.

Keep the same guardrails:

- generated UniFFI/headers remain generated
- downloaded frameworks remain generated/downloaded
- Xcode project remains generated from `project.yml`

## Phase 0 deliverables

- iOS code imported into `dex`
- Rust bridge imported into `dex`
- source history preserved for imported files
- a documented source commit pinned in the import PR
- iOS app still builds through its own explicit entrypoint
- existing `dex` desktop/server/web flows remain usable

## Phase 1 scope: pairing, auth, and minimum companion API

## Product boundary

Phase 1 does not make iPhone feature-complete. It only makes iPhone a trusted remote client of desktop-authoritative `dex` for text-thread continuity.

Minimum user-visible outcomes:

- user pairs iPhone to desktop
- user can connect to desktop from anywhere through a secure relay/tunnel
- user can see and continue threads from phone
- user can handle approvals and user input from phone
- no change to desktop authority model

## Phase 1 design principle

Prefer reusing existing `dex` auth/orchestration surfaces over inventing a new mobile-only protocol.

Relevant existing surfaces already present:

- `/.well-known/dex/environment`
- `POST /api/auth/bootstrap/bearer`
- `GET /api/auth/session`
- `POST /api/auth/ws-token`
- `orchestration.subscribeShell`
- `orchestration.subscribeThread`
- `orchestration.dispatchCommand`

This is a major advantage and should be preserved.

## Pairing and auth contract

## Current reusable pieces

`dex` already has:

- auth policy descriptors
- bootstrap credential exchange
- bearer session bootstrap for non-browser clients
- websocket token issuance
- pairing credential issuance
- client session metadata and revocation

Relevant areas:

- `packages/contracts/src/auth.ts`
- `apps/server/src/auth/http.ts`
- `apps/server/src/auth/Services/ServerAuth.ts`
- `apps/web/src/environments/remote/api.ts`

## Recommended Phase 1 auth flow

### Pairing initiation on desktop

The desktop app, acting as an authenticated owner session, requests a one-time pairing credential from the server using the existing pairing credential mechanism.

Desktop then renders a QR artifact containing:

- the remote-reachable base URL or relay URL
- the environment descriptor label
- the one-time credential
- optional desktop display metadata for UX

### Pairing redemption on iPhone

The iPhone app scans the QR artifact and redeems the one-time credential through the existing bearer bootstrap endpoint:

- `POST /api/auth/bootstrap/bearer`

The response returns:

- bearer session token
- expiry
- role and session method

This is the correct `v1` native-session model.

### Session establishment

After bearer bootstrap:

1. iPhone calls `GET /api/auth/session` to validate state if needed
2. iPhone calls `POST /api/auth/ws-token`
3. iPhone connects to desktop `dex` through websocket using the short-lived websocket token

This reuses the current remote-environment model instead of inventing a separate mobile websocket handshake.

## Phase 1 auth changes required

### Server

Add or tighten only what is missing for native trusted-device pairing:

- pairing credential metadata should carry device intent cleanly
- client session metadata should accurately record mobile device characteristics
- native bearer session TTLs should be explicit and appropriate for trusted-device reconnects
- trusted-device UX labels should be supported without special-case server hacks

### Desktop UI

Desktop must add:

- “pair iPhone” action
- QR code presentation
- trusted device/session visibility and revocation
- relay/tunnel reachability status for the device

### iOS

iPhone must add or adapt:

- QR scan pairing flow
- bearer token storage in secure storage
- remote `dex` server record type for companion pairing
- reconnect flow built on the `dex` auth contract, not on direct provider authority

## Trusted device model

For Phase 1, a trusted iPhone can be represented as a long-lived bearer session plus client metadata. We do not need a separate account-backed device registry yet.

This is enough for:

- trust establishment
- device listing on desktop
- device revocation
- later migration to cloud-backed device identity

## Minimum companion API

## Principle

The minimum API should support continuity, not parity.

If an iPhone action is not required for “continue Thread A remotely,” it should not be in the minimum surface.

## Minimum read surfaces

### 1. Environment descriptor

Use existing:

- `GET /.well-known/dex/environment`

Needed for:

- pairing payload validation
- labeling and environment identity

### 2. Auth/session

Use existing:

- `POST /api/auth/bootstrap/bearer`
- `GET /api/auth/session`
- `POST /api/auth/ws-token`

Needed for:

- native session establishment
- reconnects

### 3. Shell snapshot

Use existing:

- `orchestration.subscribeShell`

Needed for:

- project list
- thread list
- thread shell/session state
- sidebar-equivalent thread summaries on phone

### 4. Thread detail snapshot + events

Use existing:

- `orchestration.subscribeThread`

Needed for:

- open a thread
- render messages, activities, proposed plans, turn state, pending requests

## Minimum write surfaces

### 1. Continue/start turn

Use existing:

- `orchestration.dispatchCommand`

Required command family:

- `thread.turn.start`

### 2. Interrupt turn

Use existing:

- `orchestration.dispatchCommand`

Required command family:

- `thread.turn.interrupt`

### 3. Approvals

Use existing:

- `orchestration.dispatchCommand`

Required command family:

- approval response command path already used by desktop/web

### 4. Pending user input

Use existing:

- `orchestration.dispatchCommand`

Required command family:

- user-input response command path already used by desktop/web

### 5. Optional thread navigation helpers

The iPhone app may need a small convenience layer for:

- finding/opening the active thread directly after push navigation
- mapping thread references more directly than today’s web-centric environment service does

Prefer a thin client adapter first, not a new server domain.

## API changes likely required

We should assume a few targeted additions will still be needed:

### 1. Mobile-focused session metadata

The current auth/client metadata model should be extended only if needed to improve:

- trusted device labeling
- push-capable device identification
- session management UX

### 2. Companion pairing payload contract

The QR artifact needs a formal contract rather than ad hoc string encoding.

Recommended new shared contract:

- `CompanionPairingPayload`

Fields should include:

- remote URL
- environment label
- pairing credential
- issuance time / expiry
- optional display metadata

This contract belongs in `packages/contracts`.

### 3. Optional mobile bootstrap endpoint wrapper

If the iOS app benefits from a clearer semantic wrapper around bearer bootstrap for pairing, we can add a thin endpoint wrapper. But the default recommendation is to reuse the current bearer bootstrap endpoint first.

### 4. Push-aware mobile thread-open flow

The iOS app likely needs a clean way to:

- open a thread from a push notification
- guarantee the thread is present in local mobile state after reconnect

This may require:

- a mobile-side adapter over existing snapshot subscriptions
- not necessarily a new server API

## iOS application changes required in Phase 1

## Preserve

- current SwiftUI navigation and screen model
- current design work and aesthetics
- approvals/user input UX as much as possible

## Change

### 1. Replace authority assumptions

Current iOS runtime assumptions that treat the mobile layer as owning too much runtime truth must be redirected toward remote `dex` state.

High-level areas:

- `AppModel`
- runtime controller / reconnect model
- saved server and discovery model
- any direct provider-thread assumptions

### 2. Introduce a `dex` companion transport/client layer

The iOS app should gain a dedicated client layer for desktop-authoritative `dex` access.

Recommended shape:

- new Swift client boundary for `dex` HTTP + websocket auth/orchestration
- a projection layer that maps `dex` thread/session snapshots into the existing iOS UI models as much as possible

This is better than a full UI rewrite and better than forcing the current Rust store to remain the authority.

### 3. Preserve approvals and pending user input

The iOS app must keep:

- approval response support
- pending structured user input response support

This is mandatory for continuity and not optional polish.

### 4. Preserve current mobile UX for sessions and conversations

The goal is not to make iPhone look like the desktop app. The goal is to keep the current mobile UX while swapping the authority path underneath it.

## Desktop application changes required in Phase 1

### 1. Pairing UX

Desktop needs:

- a user-facing “pair iPhone” entrypoint
- QR payload generation
- revocation UI for paired mobile sessions/devices

### 2. Reachability UX

Desktop needs:

- relay/tunnel connection state
- clear indication of whether the desktop is reachable remotely
- recovery messaging when remote continuation is unavailable

### 3. Minimal import-adjacent future-proofing

Even though import is Phase 2+, desktop should avoid coupling pairing work to a purely desktop-native thread model. The pairing/companion surfaces should assume imported provider-attached threads will exist soon.

## Server changes required in Phase 1

### 1. Companion session trust model

Server auth must cleanly support:

- trusted mobile bearer sessions
- mobile websocket token issuance
- client session enumeration and revocation

### 2. Desktop-owned pairing credential issuance

Desktop should already be able to issue one-time pairing credentials using existing owner flows, but the UX and contract need to be formalized for iPhone.

### 3. Remote-reachable auth posture

This phase assumes `remote-reachable` auth policy becomes a real first-class path for the companion use case, not just a generic remote environment concept.

### 4. Mobile-safe continuity semantics

The server must guarantee that the current orchestration shell/detail subscriptions are stable enough for a non-browser companion client to rely on as its primary continuity feed.

If browser-only assumptions remain in those flows, fix them at the contract level rather than adding ad hoc mobile-only state APIs.

## Deliverables

## Phase 0 deliverables

- imported iOS app and native bridge code in `dex`
- documented import source commit
- isolated iOS build entrypoint
- no regression to existing desktop/web/server workflows

## Phase 1 deliverables

- desktop pairing flow
- trusted mobile bearer session flow
- QR pairing contract
- remote reachable mobile auth/reconnect path
- iPhone reads shell/thread state from `dex`
- iPhone can continue a thread, interrupt it, and handle approvals/user input

## Success criteria

- desktop remains the only authority in `v1`
- iPhone does not need direct provider authority to continue text threads
- iPhone pairing uses a formal trusted-device flow
- existing iOS product shape remains largely intact
- the minimum continuity path is working before parity work begins

## Recommended next artifact after this plan

Once this plan is accepted, the next implementation artifact should be a narrower contract doc covering:

- `CompanionPairingPayload`
- native trusted-device session lifecycle
- the exact subset of `orchestration.dispatchCommand` commands required by iPhone `v1`
- the projection strategy from `dex` orchestration state into the existing iOS app models
