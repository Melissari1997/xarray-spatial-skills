#!/usr/bin/env bash
#
# sync.sh — distribute the xarray-spatial AI-assistant tooling into a target repo.
#
# This repo is the source of truth for the tool definitions (Claude/Codex/Kilo
# commands, Cursor rules, .cursorrules). This script copies them into a target
# repository (e.g. xarray-spatial-contrib or xarray-spatial), leaving the
# target's runtime state (sweep-*-state.csv, settings.local.json, worktrees/)
# untouched — those live alongside the definitions but are never synced.
#
# Usage:
#   ./sync.sh /path/to/target-repo [--dry-run]
#
# Each definition directory is mirrored with deletion scoped to that directory,
# so a command removed here is removed in the target, but sibling runtime files
# (which live at the tool dir's top level, not inside commands/) are preserved.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  # Print the leading comment block (skipping the shebang), stopping at the
  # first non-comment line.
  awk 'NR==1 && /^#!/ {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}"
}

TARGET=""
DRY=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY="--dry-run" ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "error: unknown option '$arg'" >&2; usage; exit 1 ;;
    *) TARGET="$arg" ;;
  esac
done

if [ -z "$TARGET" ]; then
  echo "error: no target repo given" >&2
  usage
  exit 1
fi
if [ ! -d "$TARGET" ]; then
  echo "error: target '$TARGET' is not a directory" >&2
  exit 1
fi
if ! command -v rsync >/dev/null 2>&1; then
  echo "error: rsync is required but not found on PATH" >&2
  exit 1
fi

# Definition directories to mirror (relative to repo root). --delete is scoped
# to each of these, so runtime files outside them (e.g. .claude/sweep-*.csv) are
# never removed.
DIRS=(
  ".claude/commands"
  ".codex/commands"
  ".kilo/command"
  ".cursor/rules"
)

echo "Source: $SRC"
echo "Target: $TARGET"
[ -n "$DRY" ] && echo "(dry run — no changes will be written)"
echo

for d in "${DIRS[@]}"; do
  if [ -z "$DRY" ]; then
    mkdir -p "$TARGET/$d"
  fi
  rsync -a --delete $DRY "$SRC/$d/" "$TARGET/$d/"
  echo "  synced $d/"
done

rsync -a $DRY "$SRC/.cursorrules" "$TARGET/.cursorrules"
echo "  synced .cursorrules"

echo
echo "Done. Review changes in the target repo (git status / git diff) before committing."
