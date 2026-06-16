# xarray-spatial-skills

The AI-assistant tooling for
[xarray-spatial](https://github.com/xarray-contrib/xarray-spatial) and
xarray-spatial-contrib: the commands and rules that run automated code audits,
sweeps, and reviews across several AI coding tools.

These files used to live in the library repo. They were moved here so the
library repo stays focused on library code and the tooling has one source of
truth.

## Layout

The same set of commands is mirrored across four tools, each in the layout that
tool expects:

| Path | Tool | Format |
|------|------|--------|
| `.claude/commands/` | Claude Code | `*.md` |
| `.codex/commands/`  | Codex       | `*.md` |
| `.kilo/command/`    | Kilo        | `*.md` |
| `.cursor/rules/`    | Cursor      | `*.mdc` |
| `.cursorrules`      | Cursor      | global context file |

## Runtime artifacts (not tracked)

When the commands run, they read and write repo-root-relative state:
`sweep-*-state.csv`, per-tool `worktrees/`, and `settings.local.json`. That
state is generated wherever the tooling runs and is gitignored here (see
`.gitignore`), so it isn't part of the versioned tooling.

## Distribution

This repo holds the definitions. Copy them into a target repo with `sync.sh`:

```bash
./sync.sh /path/to/xarray-spatial-contrib            # apply
./sync.sh /path/to/xarray-spatial-contrib --dry-run  # preview
```

`sync.sh` mirrors the four definition directories and `.cursorrules` into the
target. Deletions are scoped to each definition directory, so the target's own
runtime state (`sweep-*-state.csv`, `settings.local.json`, `worktrees/`) stays
put. Check `git status` and `git diff` in the target, then commit there.
