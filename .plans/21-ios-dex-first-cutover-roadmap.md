# Dex iOS Dex-First Cutover Roadmap

## Purpose

Map the concrete changes required to move from the current imported `Litter` baseline to the desired end state:

- iOS is a first-class `dex` client
- desktop `dex` is the only authority in `v1`
- iOS no longer talks directly to Codex, Claude, or any local mobile runtime as a peer authority
- desktop and iOS stay in sync through the same `dex` server state and auth model
- the strong mobile UI/performance characteristics from `Litter` are preserved
- the cleaner visual language from `remodex` can be adopted without importing its runtime model

This plan is intentionally more concrete than plans `19` and `20`. It focuses on the actual cutover work from the current codebase shape.

## End State

The desired `v1` iOS product shape is:

- one paired `dex` desktop environment is the primary mobile concept
- iOS authenticates through `dex` auth flows
- iOS reads shell/thread state from `dex`
- iOS dispatches turn/approval/user-input actions through `dex`
- iOS does not own thread authority
- iOS does not own provider lifecycle
- iOS does not expose SSH/server discovery as the main product model
- iOS UI is mobile-native, fast, and visually polished

## Current State Summary

### What is already directionally correct

- `apps/server` already has a server-authoritative orchestration model
- `apps/server` already has auth bootstrap, bearer session, and websocket auth flows
- `apps/server` already exposes companion/native HTTP routes for iOS
- `apps/ios` already contains an imported iOS baseline and some Dex-specific integration work
- `Litter` already has strong mobile UI, scrolling, rendering, and performance-oriented view logic
- desktop already manages local backend lifecycle and network exposure

### What is still wrong for the target state

- the iOS app still fundamentally centers a legacy Rust/mobile runtime model
- Dex integration in iOS is a partial overlay, not the primary app architecture
- iOS still carries a multi-server / SSH / direct-server-discovery mental model that does not fit the target product
- the standalone `DexCompanion` lane is a bootstrap/web-container path, not the final mobile architecture
- the current iOS Dex integration uses custom companion HTTP surfaces instead of fully leaning on the long-term Dex remote runtime model from plans `19` and `20`
- there are known correctness issues in the current Dex-iOS path, including thread identity mismatches

## Guiding Principles

### 1. Keep the iOS shell, replace the authority model

We should preserve:

- mobile conversation UI
- rendering behavior
- input/composer ergonomics
- notification/lifecycle integration
- performance optimizations

We should replace:

- direct/legacy runtime assumptions
- mobile-owned session authority
- SSH/server discovery as the main product entry

### 2. Prefer simplification over compatibility

If a mobile feature conflicts with the Dex-first authority model, simplify or defer it.

Examples:

- SSH login
- arbitrary server list management
- direct Codex runtime concepts on phone
- mobile-only fork/worktree flows that Dex cannot yet represent cleanly

### 3. Reuse Dex contracts first

Before creating new iOS-specific server endpoints, prefer:

- existing auth contracts
- existing websocket auth/token flows
- existing orchestration subscriptions and command dispatch

### 4. Treat `remodex` as a design/system reference only

Adopt selectively:

- theme direction
- typography
- liquid glass treatment
- compositional UI patterns

Do not adopt:

- its bridge architecture
- its secure transport model
- its relay/session runtime as the Dex base

## Main Gaps To Close

## Gap A: Product model mismatch on iOS

Current shape:

- “find or connect to servers”
- local / remote / ssh / direct codex
- Dex is just one special case among many

Target shape:

- “your paired Dex desktop/environment”
- projects
- threads
- approvals
- pending user input

Required changes:

- define a Dex-first iOS navigation model
- make paired Dex environments the primary entry
- demote legacy server discovery/SSH to debug or legacy mode
- stop teaching the user that phone can connect to arbitrary runtimes as first-class behavior

## Gap B: Runtime split-brain in `AppModel`

Current shape:

- `AppModel` owns Rust-backed `AppStore`, `AppClient`, `ServerBridge`, `SshBridge`
- Dex is handled via conditional branches and overlay state

Target shape:

- Dex-backed state is primary
- legacy runtime is behind compatibility seams or gradually removed

Required changes:

- introduce an explicit Dex-first mobile runtime/client layer
- isolate the legacy `Litter` runtime bridge behind adapters
- remove Dex special-casing from core app state once the Dex path becomes primary
- make thread/session identity authoritative from Dex responses instead of generating local shadow identity

## Gap C: Auth/session model is not yet first-class

Current shape:

- desktop can generate pairing QR for a companion flow
- iOS can redeem bearer bootstrap
- there is still a “companion” conceptual split instead of a clean Dex mobile client story

Target shape:

- desktop “pair iPhone” is a native Dex capability
- iOS stores a trusted Dex environment/session
- reconnect uses Dex auth/session flows directly
- desktop shows paired mobile clients as first-class trusted devices/sessions

Required changes:

- tighten pairing payload contract ownership around Dex, not “companion”
- ensure bearer session TTL, metadata, and reconnect semantics are appropriate for trusted iPhone use
- make desktop pairing UX explicit and revocable
- make iOS reconnect logic depend on Dex auth/session, not on ad hoc companion assumptions

## Gap D: Data transport is transitional

Current shape:

- active thread streaming on iOS uses custom native companion NDJSON thread streaming
- dashboard/session lists poll Dex every 10 seconds

Target shape:

- iOS uses the long-term Dex remote runtime transport model
- live updates come from Dex subscriptions rather than bespoke polling/snapshot refresh loops where possible

Required changes:

- decide the canonical mobile transport:
  - preferred: websocket auth token + Dex subscription model
  - fallback only where necessary: HTTP bootstrap/snapshot helpers
- replace polling-based shell/session refresh with live subscribed state
- reduce duplicate mobile-specific projection endpoints if existing subscription surfaces can provide the same data

## Gap E: Server APIs do not yet fully support mobile UI needs

Current shape:

- some mobile needs are supported through native companion endpoints
- some actions are missing, partial, or mapped through lossy overlay transforms

Target shape:

- server exposes the minimum Dex-authoritative state/actions needed for the intended iOS UX
- mobile does not reconstruct missing semantics locally when server truth should own them

Required changes:

- audit every iOS screen against the Dex server contract
- add targeted server support for:
  - shell/sidebar thread summaries
  - full thread detail
  - thread open after push navigation
  - approvals
  - pending user input
  - thread metadata/runtime mode/collaboration mode updates
  - file search and skill search if those remain in the mobile UX
- remove iOS-only synthetic mapping once the server can express the needed truth directly

## Gap F: Legacy features need a disposition

For each existing `Litter` feature, assign one of:

- keep now
- adapt for Dex-first
- defer
- remove from iOS

Recommended initial disposition:

- keep now:
  - conversation UI
  - scrolling/render caches
  - attachments
  - notifications
  - theme/wallpaper work if low-cost
- adapt:
  - sessions list
  - home/dashboard
  - thread info/configuration
  - model/runtime/collaboration controls
- defer:
  - full parity git/worktree flows
  - advanced voice continuity
  - fork/worktree-heavy flows if server semantics are not ready
- remove or hide from primary UX:
  - SSH login
  - generic server discovery
  - direct Codex server connections as a first-class product path

## Workstreams

## Workstream 1: Dex-first product shell on iOS

Goal:

- reframe the app around paired Dex environments instead of generic servers

Changes:

- define a new primary app entry flow:
  - onboarding / pair iPhone
  - reconnect trusted desktop
  - open project/thread
- redesign or simplify `DiscoveryView` into:
  - paired desktops/environments
  - add new pairing
  - legacy/debug connection tools hidden behind an advanced path
- simplify sessions/home models so Dex environments are primary entities

Exit criteria:

- a new user can understand the product as “Dex on phone,” not “a generic remote codex client”

## Workstream 2: Auth and trusted-device lifecycle

Goal:

- make desktop/iOS pairing and reconnect a clean first-class Dex flow

Changes:

- harden pairing payload contract
- add any missing client metadata fields for mobile session labeling
- ensure desktop settings/pairing UI can:
  - issue iPhone pairing QR
  - list connected paired mobile clients
  - revoke them
- ensure iOS secure storage stores:
  - environment identity
  - base URL
  - bearer session or durable reconnect material

Exit criteria:

- iOS can pair once and reconnect as a trusted Dex client without re-scanning on ordinary reconnects

## Workstream 3: Mobile transport cutover

Goal:

- move iOS to the intended Dex transport model

Changes:

- build a dedicated Dex iOS transport/client layer
- prefer websocket token + Dex subscription channels for live state
- retain HTTP only for:
  - initial bootstrap
  - session validation
  - narrow helper endpoints if still necessary
- remove polling loops where subscriptions can replace them

Exit criteria:

- active thread, thread list, and shell state update live from Dex authority

## Workstream 4: Thread identity and state correctness

Goal:

- make Dex thread operations correct and authoritative on iOS

Changes:

- fix new-thread identity so iOS always uses the thread ID returned by Dex
- remove local synthetic identity generation where it can diverge from server truth
- ensure turn start / interrupt / approval / user-input flows target the correct authoritative thread and request IDs
- tighten error handling and reconnect behavior for active threads

Exit criteria:

- thread continuity is correct across desktop and iPhone for the same logical thread

## Workstream 5: UI adapter cleanup

Goal:

- stop translating Dex state into the old model in lossy ways

Changes:

- replace or shrink `DexNativeThreadAdapter`-style synthetic overlays
- introduce view models shaped around Dex server truth instead of legacy assumptions
- keep the fast renderer/conversation components, but feed them with cleaner upstream models

Exit criteria:

- iOS UI is driven by Dex-native app state rather than compatibility overlays

## Workstream 6: Design-language uplift

Goal:

- bring the cleaner visual language from `remodex` into Dex iOS without importing its runtime

Changes:

- port font system ideas
- port light/dark visual direction
- port selective liquid glass treatment
- audit current Litter screens for visual simplification
- preserve existing performance safeguards while restyling

Exit criteria:

- the app looks closer to the desired Dex identity while remaining technically grounded in the current repo

## Suggested Execution Phases

## Phase A: Stabilize the current Dex path

This phase is about correctness before redesign.

Do first:

- fix Dex thread identity mismatch on create
- audit all Dex thread actions for correctness
- verify approvals/user-input/update/archive paths
- document which iOS screens are currently Dex-backed vs legacy-backed

Why first:

- without this, every higher-level UX decision sits on unstable behavior

## Phase B: Establish the real Dex mobile runtime seam

Do next:

- define a dedicated Dex iOS client/runtime layer
- centralize auth/session/bootstrap/reconnect behavior
- move active Dex thread/shell state under that layer
- reduce Dex-specific conditionals scattered through `AppModel`

Why second:

- this creates the technical seam needed to simplify the rest of the app without a rewrite

## Phase C: Simplify product model

Do next:

- collapse primary UX from server discovery to paired Dex environments
- hide SSH/generic remote server flows from main UX
- simplify home/sessions information architecture

Why third:

- product clarity should happen once the runtime underneath is stable enough

## Phase D: Adopt visual system upgrades

Do next:

- port fonts/theme/glass language from `remodex`
- simplify presentation and branding toward Dex

Why fourth:

- styling should land on top of the right architecture, not mask unresolved runtime issues

## Phase E: Expand capability deliberately

Only after the above:

- decide which current Litter capabilities should return in Dex-first form
- add more parity where it strengthens the product
- defer or remove features that fight the authority model

## First Recommended Build Slice

The first meaningful implementation slice should be:

1. Fix Dex new-thread identity and active-thread correctness.
2. Build a small Dex-first session/runtime service on iOS.
3. Use it to drive:
   - paired environment list
   - thread list
   - thread open
   - turn start
   - interrupt
   - approvals
   - pending user input
4. Keep the existing conversation UI, but wire it through the new Dex-first state path.
5. Hide SSH/generic discovery from the main product entry.

This slice is small enough to ship incrementally but meaningful enough to prove the architecture.

## What We Should Not Do

- do not rebase the app on `remodex`
- do not attempt feature parity before basic Dex continuity works
- do not redesign the whole UI before the Dex runtime cutover is real
- do not preserve every legacy `Litter` server/SSH concept in the primary mobile UX
- do not keep layering more special-case companion adapters into `AppModel` indefinitely

## Success Criteria

We can call the cutover direction successful when:

- iOS is understood internally as a Dex client, not a separate mobile runtime
- desktop and iOS stay in sync on the same thread without reconciliation hacks
- iOS pairing/reconnect feels like a first-class Dex feature
- the main mobile UX no longer depends on SSH/server-discovery concepts
- the codebase has a clear Dex-first runtime seam on iOS
- visual rebrand/design work can proceed on top of a stable authority model
