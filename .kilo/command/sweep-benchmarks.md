# Benchmark Coverage Sweep: Dispatch subagents to audit and extend asv benchmark coverage

Audit xrspatial modules for benchmark coverage gaps in the asv suite under
`benchmarks/benchmarks/`: public functions with no benchmark at all,
benchmarks that only exercise the numpy backend, inputs too small to
reflect real workloads, and benchmarks that are broken or silently skipped.
Without benchmark coverage, the performance sweep's fixes have no
regression safety net. Fixes here are *adding or repairing benchmarks*,
never source changes. Subagents fix CRITICAL, HIGH, and MEDIUM findings via
rockout.

Optional arguments: {{ARGUMENTS}}
(e.g. `--top 3`, `--exclude slope,aspect`, `--only-terrain`, `--reset-state`,
`--no-fix`)

**Read `.kilo/command/_sweep-common.md` first.** It defines module
discovery, the standard flag set, module groups, the CUDA probe, the
state-CSV contract, the severity rubric, the repro gate, and the agent
contract. This file adds only what is specific to the benchmark sweep.

---

## Step 0 -- Parse arguments and probe CUDA

Parse the standard flags per _sweep-common.md (no extra flags for this
sweep). Run the CUDA availability probe and capture `CUDA_AVAILABLE`. For
this sweep the flag decides whether cupy benchmarks can be executed locally
or only added following the suite's existing GPU-guard pattern.

## Step 1 -- Discover modules and gather metadata

Discover modules per _sweep-common.md. Collect the common metadata fields
(last_modified, total_commits, loc, public_funcs) plus:

| Field | How |
|-------|-----|
| **bench_file** | file matching the module name under `benchmarks/benchmarks/` (or none) |
| **bench_loc** | `wc -l < <bench_file>` (0 if none) |
| **bench_backends** | grep the bench file for `cupy`, `dask` — which backends it parameterizes |
| **has_dask_backend** | grep module file(s) for `_run_dask`, `map_overlap`, `map_blocks` |
| **has_cuda_backend** | grep module file(s) for `@cuda.jit`, `import cupy` |

## Step 2 -- Load inspection state

Read `.kilo/worktrees/sweep-benchmarks-state.csv` per the state-CSV contract in
_sweep-common.md. Schema (one row per module):

```
module,last_inspected,issue,severity_max,categories_found,notes
slope,2026-07-01,1640,MEDIUM,2,"bench covers numpy+dask; cupy param added"
```

## Step 3 -- Score each module

```
days_since_inspected = (today - last_inspected).days   # 9999 if never
days_since_modified  = (today - last_modified).days
has_bench            = 1 if bench_file exists else 0
backend_gap          = number of backends the module implements but the
                       bench file does not parameterize (0 if no bench)

score = (days_since_inspected * 3)
      + ((1 - has_bench) * 500)
      + (backend_gap * 150)
      + (public_funcs * 5)
      + (has_dask_backend * 100)
      + (has_cuda_backend * 75)
      - (days_since_modified * 0.1)
      + (loc * 0.03)
```

Rationale:
- A module with no benchmark at all is the biggest gap (500)
- A benchmark that misses implemented backends gives false confidence (150
  per missing backend)
- Dask/CUDA modules are where regressions are most expensive to miss

## Step 4 -- Apply filters from {{ARGUMENTS}}

Apply the standard flags (`--top N` default 3, `--exclude`, `--only-<group>`,
`--high-only`, `--reset-state`, `--include-experimental`) per
_sweep-common.md.

## Step 5 -- Print the ranked table and launch subagents

### 5a. Print the ranked table

All scored modules sorted by score descending: Rank, Module, Score, Last
Inspected, Bench File, Bench Backends, Module Backends, LOC.

### 5b. Launch subagents for the top N modules

Launch one Agent per selected module per the dispatch rules in
_sweep-common.md (single message, `isolation: "worktree"`, `mode: "auto"`).

Each agent's prompt must be self-contained:

```
You are auditing the xrspatial module "{module}" for asv benchmark
coverage.

This module has {public_funcs} public functions and implements these
backends: numpy{, dask}{, cupy}. Its benchmark file is {bench_file}
({bench_loc} lines, parameterizing: {bench_backends}).

Read these files:
- {module_files}
- {bench_file} (if it exists)
- 2-3 existing benchmark files under benchmarks/benchmarks/ that DO
  parameterize backends well — they are the pattern to follow
- benchmarks/asv.conf.json (or equivalent) for how the suite is configured

CUDA available on this host: {cuda_available}

If CUDA_AVAILABLE is true: new cupy benchmarks must execute locally
(`asv dev -b <pattern>` or a direct call of the benchmark class) before
rockout opens a PR.
If CUDA_AVAILABLE is false: add cupy parameterization following the
suite's existing GPU-guard pattern, note that it was not executed locally,
and add `cuda-unavailable` to the state notes.

**Your task:**

1. Build the coverage matrix: for each public function, which backends and
   which input sizes does the benchmark suite exercise?

2. Audit for these 4 categories. Only flag gaps ACTUALLY present.

   **Cat 1 — Missing benchmarks**
   - HIGH: a public function with a nontrivial compute path has no
     benchmark at all
   - MEDIUM: benchmarked only indirectly (called inside another
     function's benchmark)
   Severity: HIGH for dask/CUDA modules (regressions there are the
   expensive ones); MEDIUM otherwise

   **Cat 2 — Backend coverage gaps**
   - HIGH: module implements a dask or cupy backend the benchmark never
     parameterizes — a backend-specific regression would ship unseen
   - MEDIUM: dask benchmark exists but uses a single chunk (so it
     measures the numpy path plus overhead, not real chunked execution)
   Severity: HIGH per above

   **Cat 3 — Unrepresentative inputs**
   - MEDIUM: benchmark input so small (< ~256x256) that setup overhead
     dominates and real scaling behavior is invisible
   - MEDIUM: only one input size — no way to see complexity regressions
   - LOW: input data pattern degenerate (all zeros) where the algorithm's
     cost depends on data (e.g. queue-based hydro tools)
   Severity: MEDIUM

   **Cat 4 — Broken or silently-skipped benchmarks**
   - HIGH: benchmark file fails to import or raises during setup — run
     `asv dev -b {module}` (or import the benchmark module directly) and
     observe; a broken benchmark reports nothing and nobody notices
   - MEDIUM: benchmark skipped by an environment guard that is wrong
     (skips even when the dependency is present)
   Severity: HIGH — a broken benchmark is worse than a missing one

3. For each real gap, assign severity per the rubric in _sweep-common.md.
   The repro-gate evidence: the coverage matrix for Cat 1/2, the observed
   timing/skip output for Cat 3/4 — executed on this host and pasted into
   the issue.

4. If any CRITICAL, HIGH, or MEDIUM gap is found, run rockout to add or
   repair benchmarks. Benchmark-only PRs — never source changes. Model new
   benchmarks on the suite's existing well-parameterized files. Every new
   benchmark must be executed once locally (numpy/dask always; cupy per
   the CUDA rules) to prove it runs. If running a benchmark surfaces a
   real performance bug, file a separate performance issue and link it.
   For LOW gaps, document but do not fix. Skip rockout entirely if the
   parent sweep was run with --no-fix; record findings in the state notes
   instead.

5. After finishing, update .kilo/worktrees/sweep-benchmarks-state.csv following
   the state-CSV contract in .kilo/command/_sweep-common.md. Header:

   `module,last_inspected,issue,severity_max,categories_found,notes`

   Then `git add` and commit.

Additional benchmark-sweep rules:
- Keep total added benchmark runtime reasonable — the suite runs in CI;
  prefer one realistic size plus one small size over a size ladder.
- Do not change asv.conf.json machine/environment settings; only add
  benchmark code.

{agent contract from _sweep-common.md, verbatim}
```

### 5c. Print a status line

After dispatching, print:

```
Launched {N} benchmark coverage audit agents: {module1}, {module2}, {module3}
```

## Step 6 -- State updates

State is updated by the subagents themselves (see agent prompt step 5).
To reset all tracking: `sweep-benchmarks --reset-state`
