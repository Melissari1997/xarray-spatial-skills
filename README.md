# xarray-spatial-skills

Canonical home for the AI-assistant tooling associated with
[xarray-spatial](https://github.com/xarray-contrib/xarray-spatial) and
xarray-spatial-contrib — the commands and rules that drive automated code
audits, sweeps, and reviews across multiple AI coding tools.

These definitions previously lived inside the library repo. They have been
extracted here so the library repo stays focused on library code, and so the
tooling has a single source of truth.

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

The command files reference repo-root-relative runtime state when they run —
`sweep-*-state.csv`, per-tool `worktrees/`, `settings.local.json`. These are
generated wherever the tooling executes and are gitignored here (see
`.gitignore`); they are not part of the versioned tooling.

## Distribution

How this tooling is distributed back into the library repos (git submodule,
symlink, sync script, etc.) is **to be decided**. For now this repo is the
canonical store of the definitions.
