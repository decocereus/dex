# Dex + iOS Companion Architecture Plan

## Purpose

Define the architecture for turning `dex` into the authoritative desktop-first coding environment, with the current iOS app becoming a companion client that can continue the same work from anywhere.

This plan is intentionally product- and system-level. It is not a UI redesign doc and it is not a file-by-file implementation checklist yet. The goal is to lock the authority model, repo strategy, and the main technical seams before code movement starts.

## Product thesis

- `dex` on macOS is the main brain and primary interaction surface.
- The iPhone app is a companion surface over the same work, not a second authority.
- A user should be able to continue `Thread A` from phone and then continue the same `Thread A` again on desktop without the flow breaking.
- `v1` is Apple-only and desktop-authoritative.
- `v2` introduces cloud identity, subscriptions, and eventually a cloud authority path that removes the requirement for the Mac to be online.

## Locked decisions

### 1. `dex` is the authority in `v1`

For `v1`, desktop owns the authoritative state for:

- thread identity
- provider attachment and resume state
- session lifecycle
- worktree and workspace execution context
- approvals and pending user input
- orchestration history shown to clients

The iPhone app must not independently become an authority for those concepts.

### 2. `v1` is not peer-to-peer sync

This is not a three-peer sync system.

The correct `v1` model is:

- provider thread
- `dex` authority
- iPhone companion client

In practical terms:

- desktop talks to Codex / Claude / future providers
- iPhone talks to `dex`
- iPhone-originated actions execute against the desktop-backed thread/workspace

### 3. The Mac must be reachable in `v1`

For `v1`, a user can continue work from phone only when the Mac-hosted authority is online and reachable.

This is acceptable for the first release and is the right complexity boundary.

### 4. Reachability must work beyond the local network

`v1` should support remote continuation away from home, not just same-LAN continuation.

The recommended transport model is:

- trusted-device pairing locally
- secure relay/tunnel for remote reachability

Not recommended for `v1`:

- raw public server exposure
- peer-to-peer NAT traversal as the primary path
- phone talking directly to provider threads in parallel with desktop

### 5. iOS `v1` keeps its current product shape

The current iOS app is the base. We should preserve its core UX and current functionality as much as possible and layer the companion architecture underneath it.

This plan does not require a mobile redesign before continuity ships.

### 6. Codex import attaches first

Imported Codex threads should remain attached to the original provider-native thread identity first, rather than being copied into a new detached `dex`-native thread.

This gives the best chance of true “pick up where you left off” continuity.

### 7. Voice continuity is not a `v1` goal

`v1` targets text-thread continuity only.

Out of scope for `v1`:

- live voice handoff between Mac and iPhone
- cross-device realtime audio session ownership transfer

Voice can remain supported on iPhone as it exists today, but it is not part of the first desktop-companion continuity milestone.

### 8. Cloud identity and subscriptions belong to `v2`

The architecture must leave room for:

- user accounts
- subscription entitlements
- cloud-backed sync and authority

But those are not required to ship `v1`.

## Non-goals

- Android support in `v1`
- Windows support in `v1`
- full feature parity between iPhone and desktop in `v1`
- live voice handoff in `v1`
- offline-first phone continuation in `v1`
- immediate rewrite of the iOS Rust layer to TypeScript

## Current codebase roles

### `dex`

`dex` already has the right long-term authority shape:

- server-side orchestration and read models
- persisted provider resume state
- desktop shell and desktop-managed local environment model
- auth bootstrap and websocket session flows
- provider abstraction for multiple agent backends
- remote environment/client connection concepts

Relevant current areas:

- `apps/server/src/orchestration/*`
- `apps/server/src/provider/*`
- `apps/server/src/auth/*`
- `apps/server/src/ws.ts`
- `apps/server/src/server.ts`
- `apps/desktop/src/main.ts`
- `apps/web/src/environments/runtime/*`
- `apps/web/src/store.ts`

### current iOS app

The iOS app currently contains:

- a mature mobile UI and navigation model
- pairing/discovery ideas
- push and notification workflows
- mobile-specific voice work
- a Rust-backed runtime/store/client layer

The iOS app should be treated as:

- a strong UX and platform foundation
- a source of mobile-specific components and flows
- not the long-term authority model

## Repository strategy

## Recommendation

Import the current iOS app into the `dex` monorepo before major implementation starts, while preserving the existing iOS app structure as much as possible.

Target topology:

- `apps/server`
- `apps/web`
- `apps/desktop`
- `apps/ios`
- `shared/rust-bridge` or an equivalent imported shared-native subtree

### Why import before implementation

- the authority model is now clear enough that the monorepo helps instead of hurting
- pairing, relay, auth, import, and companion APIs need shared evolution across desktop and mobile
- secure bridge work already underway on the iOS side belongs near the desktop authority code
- future subscription/account/cloud work will need a unified repo view anyway

### Import principles

- preserve iOS history
- preserve the existing iOS app layout initially
- preserve the Rust bridge initially
- do not redesign the iOS UI as part of the repo merge
- do not rewrite the Rust bridge during import

## Authority model

### `v1` authority

Desktop is authoritative for:

- threads
- provider session binding
- resume cursor state
- worktree/workspace execution
- approvals and pending user input
- orchestration event history

iPhone is authoritative only for:

- local UI state
- local notification routing
- local device integration concerns
- presentation of remote `dex` state

### `v2` authority

Cloud becomes the durable identity and sync layer:

- account identity
- subscription entitlement
- trusted device registry
- eventually a cloud authority or cloud-assisted authority path

Desktop may still host execution for local-workspace actions, but it should no longer be the only durable authority.

## Connectivity model

### `v1`

Required capabilities:

- local trusted-device pairing
- remote secure reachability
- authenticated phone-to-desktop session establishment
- websocket or equivalent streaming updates for thread continuity

Recommended conceptual flow:

1. User opens pairing on desktop.
2. Desktop issues a short-lived pairing credential.
3. iPhone scans a QR code or equivalent pairing artifact.
4. iPhone exchanges that artifact for a trusted-device/session credential with desktop.
5. Desktop registers the phone as a trusted companion device.
6. For remote continuation, the phone reaches the desktop through a secure relay/tunnel.

### Relay requirement

`v1` should assume a relay/tunnel service exists or will exist soon.

The relay is responsible for:

- routing authenticated phone traffic to the correct desktop instance
- not owning thread authority in `v1`
- eventually becoming part of the `v2` cloud identity/subscription layer

The relay should not become the orchestration authority in `v1`.

## Thread continuity model

### Core `v1` behavior

When a thread exists in `dex`:

- desktop and iPhone should see the same logical thread
- iPhone should see the same latest messages, activities, approvals, and pending user input
- iPhone-originated turns should execute against the same desktop-backed workspace/worktree
- returning to desktop should not require merge or reconciliation because the authority never changed

### Imported Codex threads

For imported Codex threads:

- `dex` creates an internal thread record that remains attached to the provider-native thread identity
- desktop remains responsible for the live provider session binding
- iPhone simply sees and drives that attached thread through `dex`

This is preferable to copying provider history into a detached local-only thread for the first phase.

### Workspace binding stance

For import, the recommended initial behavior is:

- attach imported threads first
- require explicit workspace binding only for features that actually need local repository/worktree execution

This keeps the import flow broad and useful while still allowing local-code features to be stricter.

## Multi-provider stance

`dex` should continue to be provider-neutral at the orchestration layer.

The mobile companion architecture should not assume Codex-only forever.

`v1` import and continuity focus:

- Codex first

Future expansion:

- Claude / Claude Code where continuity semantics are good enough
- other providers as `dex` adapters mature

This aligns with the existing `dex` provider abstraction rather than fighting it.

## Rust strategy

## Recommendation

Keep the current Rust bridge/runtime for now, but stop treating it as the long-term product authority.

### Keep now

Keep Rust where it clearly pays for itself:

- upstream Codex crate reuse
- low-level protocol/SSH/native bridge logic
- mobile-specific native support that is hard to replace immediately
- any current secure bridge work that is already in flight

### Do not do now

Do not start with:

- a full Rust-to-TypeScript rewrite
- expanding the Rust app-store/reducer as the future authority layer

### Long-term direction

As iPhone becomes a remote `dex` client:

- the Rust runtime should shrink
- the iOS app should keep only the native/runtime pieces that still earn their cost
- duplicated authority logic should be retired rather than ported blindly

## Required changes by system

## 1. `dex` server

### New responsibilities

- trusted companion-device pairing
- companion session auth model
- remote phone client session establishment
- a stable mobile-facing orchestration surface over the existing authority
- import/attach of provider-native threads, starting with Codex

### Expected work areas

- `apps/server/src/auth/*`
- `apps/server/src/ws.ts`
- `apps/server/src/http.ts`
- `apps/server/src/orchestration/*`
- `apps/server/src/provider/*`
- `apps/server/src/persistence/*`
- `packages/contracts/src/*`

### Key additions

- companion device registration model
- pairing credential issuance and exchange
- remote session token model appropriate for native clients
- explicit thread import/attach workflow for Codex
- durable mapping from `dex` thread to provider-native thread identity
- mobile-safe snapshot/event subscriptions where current browser assumptions are too narrow

## 2. `dex` desktop shell

### New responsibilities

- expose the pairing UX
- display companion device state
- manage relay/tunnel status for “work from anywhere”
- remain the user’s main control surface for authority-side settings and imports

### Expected work areas

- `apps/desktop/src/main.ts`
- desktop preload/bridge surface
- `apps/web/src/components/settings/*`
- `apps/web/src/routes/*`
- desktop/server exposure and auth presentation surfaces

### Key additions

- QR pairing flow
- trusted device management UI
- remote reachability / relay status UI
- Codex thread import UI
- future account/subscription affordances, even if dormant in `v1`

## 3. `dex` web UI

### New responsibilities

- surface companion/mobile-related status in the main desktop experience
- represent imported provider-attached threads clearly
- expose any continuity-sensitive state the phone also needs

### Expected work areas

- `apps/web/src/store.ts`
- `apps/web/src/environments/runtime/*`
- `apps/web/src/components/Sidebar.tsx`
- `apps/web/src/components/ChatView.tsx`
- `apps/web/src/components/settings/*`

### Key additions

- thread metadata indicating imported/attached origin
- provider attachment visibility where needed
- settings/management surfaces for companion devices
- import flow UI and thread continuity indicators

## 4. iOS app

### High-level change

Keep the current iOS UX shape, but replace its authority assumptions so it becomes a client of `dex`.

### Preserve

- current screen structure
- navigation model
- push handling model where still useful
- current visual direction and ongoing design work

### Change

- thread/session authority source
- connection model
- pairing target
- any direct-provider flows that conflict with the new authority model

### Expected work areas after import

- `apps/ios/Sources/Litter/LitterApp.swift`
- `apps/ios/Sources/Litter/Models/AppModel.swift`
- `apps/ios/Sources/Litter/Models/AppRuntimeController.swift`
- `apps/ios/Sources/Litter/Models/NetworkDiscovery.swift`
- `apps/ios/Sources/Litter/Models/SavedServerStore.swift`
- pairing / secure bridge / reconnect code
- conversation and sessions screens only where authority assumptions leak through

### iOS work categories

#### Pairing and trust

- pair to desktop `dex`, not to a separate mobile authority
- store trusted-device credentials appropriate for native use
- support relay-backed remote reachability

#### Thread/session continuity

- list/open remote `dex` threads
- continue existing `dex` threads
- render live remote thread state
- send turns to the desktop authority
- preserve current approvals and pending user-input capabilities

#### Import visibility

- show desktop-imported provider-attached threads naturally in the existing session/thread UI
- avoid special-case UX unless needed for clarity

#### Voice

- do not block `v1` on cross-device voice continuity
- keep current voice features working where possible without forcing them into the continuity milestone

## 5. Relay / cloud-adjacent services

`v1` needs a secure reachability layer but not full cloud authority.

This can live as a dedicated service boundary that later grows into account/subscription/cloud sync infrastructure.

### `v1` responsibilities

- relay/tunnel connections between trusted phone and trusted desktop
- authenticate requests to the correct desktop authority
- avoid becoming the thread/session source of truth

### `v2` expansion path

- user identity
- subscription entitlements
- device registry
- cloud-stored metadata and eventually cloud authority

## Migration strategy

## Phase 0: Repo import

- import the current iOS app into `dex`
- import Rust bridge code with history preserved
- preserve iOS build system shape initially
- keep desktop and iOS independently runnable

## Phase 1: Companion foundation

- define companion device credentials and pairing
- add desktop pairing UI
- add iPhone pairing flow
- establish remote authenticated mobile sessions to `dex`

## Phase 2: Text-thread continuity

- iPhone can list/open `dex` threads
- iPhone can continue a thread against the desktop-backed workspace
- approvals and pending user input work end-to-end
- desktop remains the single authority

## Phase 3: Codex import/attach

- import existing Codex threads into `dex`
- keep provider attachment first
- expose imported threads to both desktop and iPhone through the same `dex` model

## Phase 4: parity growth

- broaden the mobile companion feature set
- improve provider import breadth
- tighten relay and trusted-device management

## Phase 5: cloud/account/subscription

- account identity
- entitlement checks
- cloud-backed trusted device registry
- eventual move away from “desktop must be online”

## Risks and guardrails

### Main risk: split-brain authority

Guardrail:

- do not allow the iPhone app to continue talking to provider threads in a way that bypasses `dex` for continuity-sensitive flows

### Main risk: repo merge without architectural alignment

Guardrail:

- import the app, but preserve its current structure while redirecting authority step-by-step

### Main risk: over-committing to Rust or to a rewrite

Guardrail:

- keep Rust where useful
- shrink it after the new authority model works
- do not rewrite first

### Main risk: `v1` scope collapse

Guardrail:

- ship text-thread continuity first
- explicitly defer live voice handoff, offline sync, and cloud authority

## Success criteria for `v1`

- User pairs iPhone to desktop `dex`.
- User can leave home and continue a desktop-backed thread from phone through a secure relay/tunnel.
- The same logical thread can be continued on phone and then again on desktop without merge or reset.
- Approvals and pending user input do not regress on iPhone.
- Existing iOS UI remains recognizable and functional.
- Codex import/attach works for at least an initial attached-first flow.
- Desktop remains the main brain and interaction surface throughout.

## Immediate next planning artifact

After this plan, the next concrete artifact should be a narrower implementation plan for:

- repo import mechanics
- companion pairing/auth contract
- the minimum mobile-facing `dex` API surface for Phase 2 text-thread continuity

