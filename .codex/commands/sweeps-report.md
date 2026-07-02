# Sweeps Report: Cross-sweep health dashboard from the state CSVs

Read-only rollup of every sweep's accumulated state. Parses all
`.codex/sweep-*-state.csv` files and prints a health dashboard: which
modules are stale or never-inspected per sweep, where the worst findings
are, the LOW-findings backlog buried in notes columns, and what
re-validation debt (cuda-unavailable, gdal-unavailable, ...) is
outstanding. Launches no agents, writes no files, changes no state.

This file is intentionally named `sweeps-report.md` so /deep-sweep's
`sweep-*.md` discovery glob does not treat it as a dispatchable audit.

Optional arguments: $ARGUMENTS
(e.g. `--module slope` to filter to one module's row across all sweeps)

---

## Step 1 -- Collect state files

Glob `.codex/sweep-*-state.csv`. For each, the sweep name is the middle
segment. Parse with csv.DictReader. Missing files just mean that sweep has
never run — include the sweep in the grid as all-never-inspected only if
its command file `.codex/commands/sweep-{name}.md` exists.

Also enumerate the full module list per the discovery rules in
`.codex/commands/_sweep-common.md`, so modules never inspected by any
sweep still appear. (sweep-dependencies keys by `unit`, not module — give
it its own small section rather than forcing it into the module grid.)

## Step 2 -- Print the dashboard

Print these sections, most actionable first:

### 1. Module × sweep staleness grid

One row per module, one column per sweep. Cell values:
- `--` never inspected
- `NNd` days since last inspection, suffixed with `!` if severity_max was
  HIGH or CRITICAL at last inspection (e.g. `45d!`)
- `ok` inspected within 30 days, nothing above MEDIUM

Sort rows so the most-neglected modules (most `--` cells) come first.

### 2. Open severity summary

Per sweep: count of rows whose last inspection recorded CRITICAL/HIGH,
with module names and issue numbers. These are inspections that produced
findings — check whether the linked issues/PRs actually closed.

### 3. LOW-findings backlog

Harvest every non-empty `notes` field that describes documented-but-unfixed
LOW findings. Group by module. If a module has accumulated 3+ LOW notes
across sweeps, suggest bundling them into one cleanup issue (a single
/rockout prompt) instead of leaving them to rot.

### 4. Re-validation debt

Every row whose notes contain an `-unavailable` token (`cuda-unavailable`,
`gdal-unavailable`, `richdem-unavailable`, `pip-audit-unavailable`, ...):
list module, sweep, token, and inspection date. If the current host now has
the capability (probe per _sweep-common.md), flag those rows as
re-runnable today.

### 5. Suggested next actions

End with 3-5 concrete suggestions derived from the data, e.g.:
- `/sweep-<name>` for the sweep with the most never-inspected modules
- `/deep-sweep <module>` for the module with the most `--` cells or the
  most `!` markers
- re-run suggestions from section 4 when the capability is now present
Do NOT run any of them — suggest only.

---

## General rules

- Strictly read-only: no agents, no /rockout, no state-file writes, no
  probing beyond the cheap capability checks in section 4.
- If no state files exist at all, say so and list the available `/sweep-*`
  commands to get started.
- Keep the dashboard compact — wide tables beat long prose here.
