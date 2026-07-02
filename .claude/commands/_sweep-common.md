# Sweep Common: Shared contract for all /sweep-* commands

This file is NOT a runnable command. It defines the shared machinery every
`/sweep-*` command uses: module discovery, standard flags, module groups,
CUDA probing, the state-CSV contract, the severity rubric, the repro gate,
and the agent contract. Each sweep file references the sections below by
name instead of repeating them. If you were asked to run this file
directly, stop and run one of the `/sweep-*` commands instead.

---

## Module discovery

Enumerate candidate modules:

**Single-file modules:** Every `.py` file directly under `xrspatial/`,
excluding `__init__.py`, `_version.py`, `__main__.py`, `_template_data.py`,
`templates.py`, `utils.py`, `accessor.py`, `preview.py`,
`dataset_support.py`, `diagnostics.py`, `analytics.py`, `validate.py`.

**Subpackage modules:** Every directory under `xrspatial/` that contains
`.py` files, excluding `tests/`, `datasets/`, `experimental/`, and
`__pycache__/`. Treat each subpackage as a single audit unit; list all
`.py` files within it (excluding `__init__.py`). As of this writing that
yields: `geotiff/`, `reproject/`, `hydro/`, `interpolate/`, `mcda/`,
`gpu_rtx/` — but always re-derive the list from the filesystem so new
subpackages enter scope automatically.

If `--include-experimental` was passed, add `experimental/` and `datasets/`
as subpackage units too.

## Standard flags

Every sweep parses these from $ARGUMENTS (multiple may combine):

| Flag | Effect |
|------|--------|
| `--top N` | Audit only the top N scored modules (default: 3) |
| `--exclude mod1,mod2` | Remove named modules from scope |
| `--only-<group>` | Restrict to one module group (see Module groups) |
| `--reset-state` | Delete the sweep's state CSV before scoring and treat every module as never-inspected |
| `--no-fix` | Audit only: subagents do not run /rockout and open no PRs. The state CSV is still updated, with findings summarized in `notes`. |
| `--high-only` | Drop modules whose state row shows `severity_max` below HIGH (or, for sweeps with a `high_count` column, `high_count == 0`) AND `last_inspected` within the past 30 days. Never filters a never-inspected module. |
| `--include-experimental` | Add the `experimental/` and `datasets/` subpackages to discovery |

A sweep may define extra flags; its own file documents them.

## Module groups

`--only-<group>` restricts discovery to the named group:

| Group | Modules |
|-------|---------|
| `terrain` | slope, aspect, curvature, terrain, terrain_metrics, hillshade, sky_view_factor |
| `focal` | focal, convolution, morphology, bilateral, edge_detection, glcm |
| `hydro` | flood, cost_distance, geodesic, surface_distance, viewshed, erosion, diffusion, hydro (subpackage) |
| `io` | geotiff, reproject, rasterize, polygonize |
| `stats` | zonal, classify, kde, mahalanobis, emerging_hotspots, dasymetric, balanced_allocation, normalize, multispectral |
| `synth` | perlin, bump, worley, terrain, fire, resample, sieve, polygon_clip, contour, corridor, pathfinding, proximity, visibility, interpolate (subpackage), mcda (subpackage), gpu_rtx (subpackage) |

## Common metadata fields

Collect per module with these commands (sweeps add their own fields on top):

| Field | How |
|-------|-----|
| **last_modified** | `git log -1 --format=%aI -- <path>` (for subpackages, most recent file) |
| **total_commits** | `git log --oneline -- <path> \| wc -l` |
| **loc** | `wc -l < <path>` (for subpackages, sum all files) |
| **public_funcs** | count of public functions exported for this module in `xrspatial/__init__.py` (fallback: `grep -cE '^def [a-z]' <files>`) |

Store results in memory -- do NOT write intermediate files.

## CUDA availability probe

Before dispatching agents, probe the host once:

```bash
python -c "from numba import cuda; print(cuda.is_available())" 2>/dev/null
```

Capture the result as `CUDA_AVAILABLE` (`true` if the command prints `True`,
`false` otherwise — including import failure). Interpolate the flag into
every subagent prompt.

Meaning for agents:
- **CUDA true:** run the cupy and dask+cupy paths for real. Findings against
  GPU code must be validated by executing a small input, not by reading
  source. A /rockout fix touching CUDA code must include a cupy run in its
  verification step before opening the PR.
- **CUDA false:** review cupy / dask+cupy paths statically only, and add the
  token `cuda-unavailable` to the state CSV `notes` column so a future run
  on a GPU host knows to re-validate.
- **Either way:** the numpy and dask+numpy backends run on every host.
  Static-only review is never acceptable for those two paths when the repro
  gate (below) requires execution.

## State CSV contract

Each sweep owns one state file: `.claude/sweep-{name}-state.csv`, one row
per module, header defined in the sweep file. Conventions:

- `categories_found` (where present) is a semicolon-separated integer list
  (empty when null). Use empty strings, not `null`, for missing values.
- `notes` is CSV-quoted; newlines must be flattened so every module stays
  exactly one physical line.
- The file is tracked in git and uses git's default 3-way text merge (no
  `merge=union`; see issue #2754). Two parallel sweeps that touch the CSV
  surface a normal merge conflict rather than silently unioning duplicate
  rows. Resolve a conflict by keeping one row per `module` (latest
  `last_inspected` wins), a single header, and one physical line per record
  -- or just re-run the read-update-write cycle below, which rewrites the
  whole canonical file.

Read, update, and write via this pattern -- never hand-edit the file
(substitute the sweep's `path`, `header`, and row fields):

```python
import csv
from pathlib import Path

path = Path(".claude/sweep-{name}-state.csv")
header = [...]  # the sweep's schema, in order

rows = {}
if path.exists():
    with path.open() as f:
        for r in csv.DictReader(f):
            rows[r["module"]] = r  # last write wins on dupes

rows["{module}"] = {...}  # all header keys; today's ISO date for last_inspected

def _oneline(v):
    # Git merges these CSVs line by line, so a newline inside a quoted
    # field splits the record on a merge. Force one physical line per
    # record by collapsing embedded newlines to " | ".
    return "" if v is None else str(v).replace("\r\n", " | ").replace("\r", " | ").replace("\n", " | ")

with path.open("w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=header, quoting=csv.QUOTE_MINIMAL)
    w.writeheader()
    for m in sorted(rows):
        w.writerow({k: _oneline(v) for k, v in rows[m].items()})
```

After writing, `git add` the state file and commit it to the worktree
branch so the state update lands in any resulting PR. Verify state after a
sweep with `column -t -s, .claude/sweep-{name}-state.csv | less`.

## Severity rubric

Applies library-wide; sweep files refine it per category.

- **CRITICAL** — memory corruption, out-of-bounds writes, or a wrong result
  that silently poisons downstream analysis with no way for the user to
  notice (e.g. wrong CRS-dependent math).
- **HIGH** — wrong or misleading result on realistic inputs; a public API
  that errors on copy-paste usage; a bug class that has shipped before.
- **MEDIUM** — wrong only on edge-case inputs; inconsistency that surprises
  but does not corrupt; documented-but-wrong claims.
- **LOW** — cosmetic, internal-only, or requires adversarial inputs no real
  workflow produces. Documented in state notes, never auto-fixed.

## Repro gate

Before /rockout files an issue for any CRITICAL or HIGH finding, the agent
must produce a runnable reproduction: a short script or failing test,
actually executed on this host, whose output demonstrates the defect.
Include the reproduction (code + observed output) in the issue body.

- Applies to every backend runnable on the host: numpy and dask+numpy
  always; cupy and dask+cupy only when CUDA_AVAILABLE is true. A GPU-only
  finding on a non-GPU host stays a static finding: file it, mark it
  `unverified-static` in the issue and state notes, and let a GPU host
  re-validate.
- MEDIUM findings: a reproduction is strongly encouraged but not required.
- /sweep-style is exempt — flake8/isort output is already the evidence.
- A finding that cannot be reproduced when the code path is runnable is a
  false positive. Do not file it.

## Agent contract

Include this block verbatim in every subagent prompt (after the
sweep-specific instructions):

```
Ground rules (from .claude/commands/_sweep-common.md):
- Only flag issues ACTUALLY present in the code. Do not report hypothetical
  issues or patterns that "could" occur with imaginary inputs. False
  positives are worse than missed issues; when in doubt, skip.
- Read the matching test file(s) under xrspatial/tests/ before flagging --
  a test may codify the current behavior intentionally.
- Repro gate: every CRITICAL/HIGH finding needs a runnable reproduction
  executed on this host before /rockout files it (numpy and dask+numpy
  always run here; cupy only if CUDA is available). Unreproducible-but-
  runnable findings are false positives.
- This repo uses ArrayTypeFunctionMapping to dispatch across numpy / cupy /
  dask+numpy / dask+cupy. Check all backend paths, not just numpy.
- Do NOT flag the use of numba @jit itself. Focus on what the JIT code
  does, not that it uses JIT.
- For the hydro subpackage: audit one representative variant (d8) in
  detail, then note which dinf/mfd files share the same pattern. Do not
  read all 29 files line by line.
- Never call `.compute()` in a dask graph-construction probe.
- Update the sweep's state CSV via the csv.DictReader/DictWriter pattern in
  _sweep-common.md (never hand-edit), then git add and commit it on your
  worktree branch.
```

## General rules for the parent command

- Do NOT modify any source files from the parent. Subagents handle fixes
  via /rockout (unless `--no-fix`).
- Keep parent output concise -- the ranked table and dispatch line are the
  deliverables.
- If $ARGUMENTS is empty, use defaults: top 3, no group filter, no
  exclusions, fixes enabled.
- Launch all N agents in a single message with `isolation: "worktree"` and
  `mode: "auto"` so they run concurrently.
- For subpackage modules, the subagent reads ALL `.py` files in the
  subpackage directory, not just `__init__.py`.
