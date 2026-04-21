# dex

dex is a local-first, server-authoritative GUI for coding agents.

Today the repository ships:

- a Node.js server/runtime in `apps/server`
- a React web client in `apps/web`
- an Electron desktop app in `apps/desktop`
- an imported iOS companion baseline in `apps/ios`

Current providers:

- Codex
- Claude

## Current Status

This project is still very early, but the direction is already clear:

- correctness, reliability, and predictable runtime behavior over feature sprawl
- provider-neutral orchestration with provider-specific adapters at the edge
- remote-capable environments and pairing as first-class product surfaces
- desktop and web as the main clients, with iPhone companion support growing behind them

For the current project snapshot and roadmap, see [docs/status.md](./docs/status.md).

## Getting Started

Provider prerequisites:

- Codex: install [Codex CLI](https://github.com/openai/codex) and run `codex login`
- Claude: install Claude Code and run `claude auth login`

Run without installing:

```bash
npx dex
```

Local development:

```bash
bun install .
bun run dev
```

Desktop development:

```bash
bun run dev:desktop
```

Headless remote-friendly server:

```bash
npx dex serve --host "$(tailscale ip -4)"
```

## Distribution

Desktop builds are published on [GitHub Releases](https://github.com/pingdotgg/dex/releases).

If package-manager distribution channels still lag the rename, prefer GitHub Releases first.

## Useful Docs

- [docs/status.md](./docs/status.md)
- [REMOTE.md](./REMOTE.md)
- [docs/observability.md](./docs/observability.md)
- [docs/release.md](./docs/release.md)
- [.docs/quick-start.md](./.docs/quick-start.md)

## Contribution Policy

This repository is not currently accepting broad drive-by contributions.

Small, focused fixes may still be useful, but the project is still early and the maintainer direction is changing quickly.

Need support? Join the [Discord](https://discord.gg/jn4EGJjrvv).
