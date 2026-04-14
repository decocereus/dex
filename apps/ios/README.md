## iOS Workspace

This directory now contains the imported iOS app from `codex-litter`, plus an additive Dex companion integration lane.

### Current targets

- `Litter`: the preserved source app. It still depends on generated native outputs that are not checked into git:
  - `apps/ios/Frameworks/ios_system/*`
  - `apps/ios/GeneratedRust/*`
- `DexCompanion`: the additive Dex-first target that pairs with the desktop app and opens authenticated Dex companion sessions on iPhone.

### Source of truth

- `project.yml` is the source of truth for the Xcode project.
- Regenerate the project with:

```bash
./apps/ios/scripts/regenerate-project.sh
```

### Current migration direction

- Preserve the existing `Litter` app UI and flows.
- Integrate Dex additively inside the restored app.
- Gradually replace Rust-backed runtime paths with Dex-backed paths.
- Keep generated native outputs out of git.

### Useful commands

```bash
make ios-dex-companion
make ios-dex-companion-device
```

### Temporary legacy compatibility path

Until the preserved `Litter` target is fully de-Rustified, the old bridge can be rebuilt locally when needed:

```bash
./apps/ios/scripts/build-rust.sh --preserve-current --fast-sim
```

That path may hydrate `shared/third_party/codex`, generate `Sources/Litter/Bridge/UniFFICodexClient.generated.swift`, and create ignored outputs under `apps/ios/GeneratedRust`.

After rebuilding and testing, you can reclaim disk space from the Rust build cache with:

```bash
rm -rf shared/rust-bridge/target
```
