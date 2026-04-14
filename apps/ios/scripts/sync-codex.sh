#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$IOS_DIR/../.." && pwd)"
SUBMODULE_DIR="$REPO_DIR/shared/third_party/codex"
SUBMODULE_URL="https://github.com/openai/codex"
PATCH_FILES=(
    "$REPO_DIR/patches/codex/ios-exec-hook.patch"
    "$REPO_DIR/patches/codex/client-controlled-handoff.patch"
    "$REPO_DIR/patches/codex/mobile-code-mode-stub.patch"
    "$REPO_DIR/patches/codex/thread-read-permissions.patch"
    "$REPO_DIR/patches/codex/mobile-shell-snapshot-timeout.patch"
)

patch_already_upstreamed() {
    return 1
}

patch_content_present() {
    local patch_file="$1"
    local patch_targets=()
    local added_lines
    local line
    local trimmed

    while IFS= read -r pf; do
        [ -f "$SUBMODULE_DIR/$pf" ] && patch_targets+=("$SUBMODULE_DIR/$pf")
    done < <(grep '^diff --git' "$patch_file" | sed 's|.*b/||')

    if [ "${#patch_targets[@]}" -eq 0 ]; then
        return 1
    fi

    added_lines="$(grep '^+[^+]' "$patch_file" | sed 's/^+//' | head -5)"
    while IFS= read -r line; do
        trimmed="${line#"${line%%[![:space:]]*}"}"
        [ -z "$trimmed" ] && continue
        if ! grep -qF "$trimmed" "${patch_targets[@]}" 2>/dev/null; then
            return 1
        fi
    done <<< "$added_lines"

    return 0
}

SYNC_MODE="${1:---preserve-current}"
case "$SYNC_MODE" in
    --preserve-current|--recorded-gitlink)
        ;;
    *)
        echo "usage: $(basename "$0") [--preserve-current|--recorded-gitlink]" >&2
        exit 1
        ;;
esac

echo "==> Syncing codex submodule..."
if ! git -C "$SUBMODULE_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
    if git -C "$REPO_DIR" submodule update --init --recursive shared/third_party/codex >/dev/null 2>&1; then
        echo "==> Initialized codex submodule from parent repo metadata"
    else
        echo "==> Parent repo has no codex submodule metadata; bootstrapping checkout from $SUBMODULE_URL"
        rm -rf "$SUBMODULE_DIR"
        git clone --filter=blob:none --no-checkout "$SUBMODULE_URL" "$SUBMODULE_DIR"
    fi
elif [ "$SYNC_MODE" = "--recorded-gitlink" ]; then
    git -C "$REPO_DIR" submodule update --init --recursive shared/third_party/codex
else
    recorded_commit="$(git -C "$REPO_DIR" ls-files --stage shared/third_party/codex | awk 'NR == 1 { print $2 }')"
    current_commit="$(git -C "$SUBMODULE_DIR" rev-parse HEAD)"

    if [ -z "$recorded_commit" ]; then
        echo "==> No recorded gitlink found in parent repo; preserving current codex checkout ${current_commit:0:9}"
    elif [ "$current_commit" = "$recorded_commit" ]; then
        echo "==> codex submodule already at recorded gitlink ${current_commit:0:9}"
    else
        echo "==> Preserving current codex checkout ${current_commit:0:9} (recorded gitlink ${recorded_commit:0:9})"
    fi
fi

for PATCH_FILE in "${PATCH_FILES[@]}"; do
    PATCH_NAME="$(basename "$PATCH_FILE")"
    if [ ! -f "$PATCH_FILE" ]; then
        echo "error: missing patch file: $PATCH_FILE" >&2
        exit 1
    fi

    if patch_content_present "$PATCH_FILE"; then
        echo "==> $PATCH_NAME already applied (content check)."
    elif git -C "$SUBMODULE_DIR" apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
        echo "==> $PATCH_NAME already applied."
    elif git -C "$SUBMODULE_DIR" apply --check "$PATCH_FILE" >/dev/null 2>&1; then
        echo "==> Applying $PATCH_NAME to submodule..."
        git -C "$SUBMODULE_DIR" apply "$PATCH_FILE"
    elif patch_already_upstreamed "$PATCH_FILE"; then
        echo "==> $PATCH_NAME already present upstream; skipping patch apply."
    else
        echo "error: $PATCH_NAME no longer applies cleanly to codex $(git -C "$SUBMODULE_DIR" rev-parse --short HEAD)" >&2
        echo "error: refresh $PATCH_FILE before rebuilding the bridge" >&2
        exit 1
    fi
done

echo "==> codex submodule ready at $(git -C "$SUBMODULE_DIR" rev-parse --short HEAD)"
