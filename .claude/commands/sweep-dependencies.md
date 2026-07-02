# Dependency Sweep: Audit packaging, optional-import, and dependency hygiene

Deep-sweep scope: library-wide — /deep-sweep skips this sweep.

Audit xarray-spatial's dependency and packaging hygiene: optional
dependencies (cupy, dask, numba-cuda, rioxarray, ...) imported without
guards so a missing extra breaks unrelated imports; declared minimum
versions that no CI job actually exercises; known CVEs in the dependency
set; and distribution metadata (extras, py.typed, wheel contents). Unlike
the per-module sweeps, the audit unit here is a dependency group, not an
xrspatial module. Subagents fix CRITICAL, HIGH, and MEDIUM findings via
/rockout.

Optional arguments: $ARGUMENTS
(e.g. `--top 2`, `--exclude gpu`, `--reset-state`, `--no-fix`)

**Read `.claude/commands/_sweep-common.md` first.** It defines the standard
flag set, the state-CSV contract, the severity rubric, the repro gate, and
the agent contract. Module discovery and the `--only-<group>` module groups
do NOT apply to this sweep — the units below replace them.

---

## Step 0 -- Parse arguments and probe CUDA

Parse `--top N` (default 2), `--exclude unit1,unit2`, `--reset-state`,
`--no-fix`, `--high-only` per _sweep-common.md. Run the CUDA availability
probe and capture `CUDA_AVAILABLE`.

## Step 1 -- Enumerate audit units and gather metadata

The audit units are dependency groups, discovered from the packaging
metadata (read `setup.py` / `setup.cfg` / `pyproject.toml`, whichever the
repo uses):

| Unit | Covers |
|------|--------|
| `core` | required install deps (xarray, numba, numpy, ...) |
| `gpu` | cupy, numba-cuda, and every `import cupy` site |
| `dask` | dask, distributed, and every dask-path import |
| `io` | rioxarray, rasterio, GDAL-adjacent deps used by geotiff/reproject |
| `viz-misc` | remaining extras (matplotlib, datashader, ...) as declared |
| `packaging` | the distribution itself: extras definitions, py.typed, wheel contents, classifiers |

For each unit, collect:

| Field | How |
|-------|-----|
| **declared_pins** | the version constraints declared for the unit's packages |
| **import_sites** | `grep -rn 'import <pkg>' xrspatial/ --include='*.py' \| grep -v tests \| wc -l` per package |
| **unguarded_imports** | of those, count at module top level with no try/except or delayed-import wrapper |
| **last_modified** | `git log -1 --format=%aI -- <packaging files>` |

## Step 2 -- Load inspection state

Read `.claude/sweep-dependencies-state.csv` per the state-CSV contract in
_sweep-common.md, with `unit` in place of `module` as the row key. Schema:

```
unit,last_inspected,issue,severity_max,categories_found,notes
gpu,2026-07-01,1630,HIGH,1;2,"cupy import unguarded in 3 modules"
```

## Step 3 -- Score each unit

```
days_since_inspected = (today - last_inspected).days   # 9999 if never

score = (days_since_inspected * 3)
      + (unguarded_imports * 200)
      + (import_sites * 2)
```

Optional deps with unguarded imports dominate — they are the "pip install
xarray-spatial fails to import without a GPU" class of bug.

## Step 4 -- Apply filters from $ARGUMENTS

`--top N` (default 2), `--exclude`, `--high-only`, `--reset-state` per
_sweep-common.md. The module-group `--only-*` flags do not apply.

## Step 5 -- Print the ranked table and launch subagents

### 5a. Print the ranked table

All units, sorted by score descending: Rank, Unit, Score, Last Inspected,
Import Sites, Unguarded, Declared Pins.

### 5b. Launch subagents for the top N units

Launch one Agent per selected unit per the dispatch rules in
_sweep-common.md (single message, `isolation: "worktree"`, `mode: "auto"`).

Each agent's prompt must be self-contained:

```
You are auditing the xarray-spatial dependency unit "{unit}" for packaging
and dependency hygiene.

Unit packages: {packages}. Declared constraints: {declared_pins}.
Import sites: {import_sites} ({unguarded_imports} unguarded at module top
level).

Read the packaging metadata (setup.py / setup.cfg / pyproject.toml), the
CI workflow files under .github/workflows/, and every file
`grep -rln '{package}' xrspatial/ --include='*.py'` returns for this
unit's packages.

CUDA available on this host: {cuda_available}

**Your task:**

1. Audit for these 4 categories. Only flag issues ACTUALLY observed.

   **Cat 1 — Optional-import guards**
   - HIGH: an optional dependency ({unit} extra) imported unguarded at
     module top level, so importing xrspatial (or a submodule reachable
     from `import xrspatial`) fails when the extra is not installed.
     Verify by simulation on this host: run python with the import blocked
     (`import sys; sys.modules['<pkg>'] = None` — forces ImportError on
     import) and confirm `import xrspatial` still succeeds and only the
     GPU/dask-specific call paths raise a clear error.
   - MEDIUM: guard exists but the failure message doesn't say which extra
     to install (`pip install xarray-spatial[gpu]`)
   - MEDIUM: guard swallows ImportError so the feature silently degrades
     with no signal
   Severity: HIGH — install-time breakage is the first impression

   **Cat 2 — Untested version floors**
   - HIGH: a declared minimum version (`>=X`) that no CI job installs —
     the floor is a guess; check .github/workflows/ for a min-deps job
   - MEDIUM: no upper-bound policy on a dependency with a history of
     breaking releases, or a hard `==` pin in a library (over-pinning)
   - MEDIUM: constraint declared in two places (setup vs environment
     files) with different values
   Severity: HIGH when the floor is provably wrong (the code uses an API
   added after the declared minimum — check changelogs for the specific
   symbol)

   **Cat 3 — Known vulnerabilities**
   - Run `pip-audit` (or `pip install pip-audit` fails → skip with note
     `pip-audit-unavailable`) against the resolved environment and against
     the declared constraints.
   - HIGH: a CVE reachable through xrspatial's usage of the package
   - MEDIUM: a CVE in a declared dependency not obviously reachable
   Severity: cap at MEDIUM unless reachability is demonstrated — this is
   a numeric library, not a network service; do not inflate.

   **Cat 4 — Distribution metadata (packaging unit only)**
   - MEDIUM: extras not defined for genuinely optional stacks (gpu, dask)
     so users cannot `pip install xarray-spatial[gpu]`
   - MEDIUM: py.typed missing while the code carries type hints
   - MEDIUM: wheel includes tests/ or excludes data files the code loads
     at runtime (build a wheel into the scratchpad and inspect it)
   - LOW: stale classifiers / requires-python drift

2. For each real issue, assign severity per the rubric in _sweep-common.md
   plus file:line (or metadata-file location). The repro gate for
   CRITICAL/HIGH findings: the blocked-import simulation output, the CI
   config lines showing the untested floor, or the pip-audit report —
   executed on this host and pasted into the issue.

3. If any CRITICAL, HIGH, or MEDIUM issue is found, run /rockout to fix it
   (issue, branch, fix, PR). Version-constraint changes must state the
   evidence for the new floor in the PR body. For LOW issues, document but
   do not fix. Skip /rockout entirely if the parent sweep was run with
   --no-fix; record findings in the state notes instead.

4. After finishing, update .claude/sweep-dependencies-state.csv following
   the state-CSV contract in .claude/commands/_sweep-common.md, keying
   rows by `unit`. Header:

   `unit,last_inspected,issue,severity_max,categories_found,notes`

   Then `git add` and commit.

Additional dependency-sweep rules:
- Never upgrade or install packages in the user's environment to test a
  hypothesis (pip-audit itself is the one allowed install, in the
  worktree's venv if one exists). Simulate missing packages with the
  sys.modules block instead of uninstalling.
- CI changes (adding a min-deps job) are in scope for a /rockout PR, but
  keep them minimal and modeled on the existing workflow files.

{agent contract from _sweep-common.md, verbatim — read "module" as "unit"
and skip the raster-specific lines (hydro sampling, backend dispatch)}
```

### 5c. Print a status line

After dispatching, print:

```
Launched {N} dependency audit agents: {unit1}, {unit2}
```

## Step 6 -- State updates

State is updated by the subagents themselves (see agent prompt step 4).
To reset all tracking: `/sweep-dependencies --reset-state`
