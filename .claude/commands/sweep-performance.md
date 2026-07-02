# Performance Sweep: Dispatch subagents to audit and fix performance issues

Audit xrspatial modules for performance bottlenecks, OOM risk under 30TB dask
workloads, and backend-specific anti-patterns. Subagents fix HIGH and
MEDIUM-severity findings via /rockout in the same agent that did the audit,
in parallel.

Optional arguments: $ARGUMENTS
(e.g. `--top 5`, `--exclude slope,aspect`, `--only-io`, `--reset-state`,
`--no-fix`)

**Read `.claude/commands/_sweep-common.md` first.** It defines module
discovery, the standard flag set, module groups, the CUDA probe, the
state-CSV contract, the severity rubric, the repro gate, and the agent
contract. This file adds only what is specific to the performance sweep.

---

## Step 0 -- Parse arguments and probe CUDA

Parse the standard flags per _sweep-common.md. For this sweep,
`--high-only` uses the `high_count` state column: drop modules whose state
row shows `high_count == 0` AND `last_inspected` within the last 30 days
(never filters a never-inspected module).

Run the CUDA availability probe and capture `CUDA_AVAILABLE`.

## Step 1 -- Discover modules and gather metadata

Discover modules per _sweep-common.md. Collect the common metadata fields
(last_modified, total_commits, loc) plus:

| Field | How |
|-------|-----|
| **has_dask_backend** | grep the file(s) for `_run_dask`, `map_overlap`, `map_blocks` |
| **has_cuda_backend** | grep the file(s) for `@cuda.jit`, `import cupy` |
| **is_io_module** | module is geotiff or reproject |
| **has_existing_bench** | a file matching the module name exists in `benchmarks/benchmarks/` |

## Step 2 -- Load inspection state

Read `.claude/sweep-performance-state.csv` per the state-CSV contract in
_sweep-common.md. Schema (one row per module):

```
module,last_inspected,oom_verdict,bottleneck,high_count,issue,notes
slope,2026-04-15,SAFE,compute-bound,0,,"optional single-line notes"
```

- `oom_verdict` is one of `SAFE`, `RISKY`, `WILL OOM`, or `N/A`.
- `bottleneck` is one of `IO-bound`, `memory-bound`, `compute-bound`, `graph-bound`.
- `issue` is normally an integer, but may be a string token like
  `false-positive`, `fixed-in-tree`, or empty.

## Step 3 -- Score each module

```
days_since_inspected = (today - last_inspected).days   # 9999 if never
days_since_modified  = (today - last_modified).days

score = (days_since_inspected * 3)
      + (loc * 0.1)
      + (total_commits * 0.5)
      + (has_dask_backend * 200)
      + (has_cuda_backend * 150)
      + (is_io_module * 300)
      - (days_since_modified * 0.2)
      - (has_existing_bench * 100)
```

## Step 4 -- Apply filters from $ARGUMENTS

Apply the standard flags (`--top N` default 3, `--exclude`, `--only-<group>`,
`--high-only`, `--reset-state`, `--no-fix`, `--include-experimental`) per
_sweep-common.md.

## Step 5 -- Print the ranked table and launch subagents

### 5a. Print the ranked table

Print a markdown table showing ALL scored modules (not just selected ones),
sorted by score descending:

```
| Rank | Module          | Score  | Last Inspected | Dask | CUDA | IO  | LOC  |
|------|-----------------|--------|----------------|------|------|-----|------|
| 1    | geotiff         | 30600  | never          | yes  | no   | yes | 1400 |
| 2    | viewshed        | 30050  | never          | yes  | yes  | no  | 800  |
| ...  | ...             | ...    | ...            | ...  | ...  | ... | ...  |
```

### 5b. Launch subagents for the top N modules

Launch one Agent per selected module per the dispatch rules in
_sweep-common.md (single message, `isolation: "worktree"`, `mode: "auto"`).

Each agent's prompt must be self-contained and follow this template (adapt
the module name, paths, and metadata):

~~~
You are auditing the xrspatial module "{module}" for performance issues.

This module has {commits} commits and {loc} lines of code.

Read these files: {module_files}

Also read xrspatial/utils.py for _validate_raster() behavior, and
xrspatial/tests/general_checks.py for cross-backend test helpers.

CUDA available on this host: {cuda_available}

If CUDA_AVAILABLE is true:
- For Cat 3 (GPU transfer) and Cat 6 (OOM verdict), validate findings
  by actually running the cupy and dask+cupy paths. Construct a small
  cupy-backed DataArray and execute the function end-to-end. Time the
  result and confirm there is no host-device round trip.
- For register-pressure findings, compile the kernel with
  `numba.cuda.compile_ptx` or run it on a small input and report the
  observed register count rather than guessing from source.

If CUDA_AVAILABLE is false:
- Inspect the cupy / dask+cupy paths by reading the source only.
- Skip executing CUDA kernels and skip cupy benchmarking. Add the
  token `cuda-unavailable` to the `notes` column of the state CSV.

**Your task:**

1. Read all listed files thoroughly, including the matching test file(s)
   under xrspatial/tests/.

2. Audit for these 6 categories. For each, look for the specific patterns
   described. Only flag issues ACTUALLY present in the code.

   **Cat 1 — Dask materialization**
   - HIGH: `.values` on a dask-backed DataArray or CuPy array
   - HIGH: `.compute()` inside a loop
   - HIGH: `np.array()` or `np.asarray()` wrapping a dask or CuPy array
   - MEDIUM: `da.stack()` without a following `.rechunk()`

   **Cat 2 — Dask chunking and overlap**
   - MEDIUM: `map_overlap` with depth >= chunk_size / 4
   - MEDIUM: Missing `boundary` argument in `map_overlap`
   - MEDIUM: Same function called twice on same input without caching
   - MEDIUM: Python `for` loop iterating over dask chunks

   **Cat 3 — GPU transfer**
   - HIGH: `.data.get()` followed by CuPy operations (GPU→CPU→GPU round-trip)
   - HIGH: `cupy.asarray()` inside a loop
   - MEDIUM: Mixing NumPy and CuPy ops in same function without clear reason
   - MEDIUM: Register pressure — count float64 local variables in `@cuda.jit`
     kernels; flag if >20
   - MEDIUM: Thread blocks >16x16 on kernels with >20 float64 locals

   **Cat 4 — Memory allocation**
   - MEDIUM: Unnecessary `.copy()` on arrays never mutated downstream
   - MEDIUM: Large temporary arrays that could be fused into the kernel
   - LOW: `np.zeros_like()` + fill loop where `np.empty()` would suffice

   **Cat 5 — Numba anti-patterns**
   - MEDIUM: Missing `@ngjit` on nested for-loops over `.data` arrays
   - MEDIUM: `@jit` without `nopython=True`
   - LOW: Type instability — initializing with int then assigning float
   - LOW: Column-major iteration on row-major arrays (inner loop should be
     last axis)

   **Cat 6 — 30TB / 16GB OOM verdict**
   For each dask code path, follow it end-to-end. Decide whether peak memory
   scales with chunk size or with the full array. Optionally write a small
   script in the session scratchpad (with a unique name including the module
   name) that constructs the dask task graph and reports task count and
   fan-in:

   ```python
   import dask.array as da
   import xarray as xr
   import json

   arr = da.zeros((2560, 2560), chunks=(256, 256), dtype='float64')
   raster = xr.DataArray(arr, dims=['y', 'x'])
   # add coords if needed
   try:
       result = MODULE_FUNCTION(raster, **DEFAULT_ARGS)
       graph = result.__dask_graph__()
       task_count = len(graph)
       print(json.dumps({
           "success": True,
           "task_count": task_count,
           "tasks_per_chunk": round(task_count / 100.0, 2),
       }))
   except Exception as e:
       print(json.dumps({"success": False, "error": str(e)}))
   ```

   The script must NEVER call `.compute()` — graph construction only.

   Verdict: one of `SAFE`, `RISKY`, `WILL OOM`, or `N/A` (no dask backend).

3. Classify the module's bottleneck as ONE of:
   `IO-bound`, `memory-bound`, `compute-bound`, `graph-bound`.

4. For each real issue found, assign a severity (CRITICAL/HIGH/MEDIUM/LOW)
   per the rubric in _sweep-common.md and note the exact file and line
   number. Apply the repro gate: for CRITICAL/HIGH findings the
   reproduction is a timing comparison, task-graph report, or memory
   observation executed on this host (numpy/dask+numpy always; cupy only
   when CUDA is available) demonstrating the cost.

5. If any CRITICAL, HIGH, or MEDIUM issue is found, run /rockout to fix it
   end-to-end (GitHub issue, worktree branch, fix, tests, and PR). Include
   the OOM verdict, bottleneck classification, and affected backends in the
   rockout prompt so it has full performance context. For LOW issues,
   document them but do not fix. Skip /rockout entirely if the parent
   sweep was run with --no-fix; record findings in the state notes instead.

   BENCHMARK REQUIREMENT: a /rockout PR that fixes a HIGH finding must add
   or extend an asv benchmark under `benchmarks/benchmarks/` covering the
   fixed code path (model on the existing benchmark files there), so the
   regression cannot silently return. Mention the benchmark in the PR body.

6. After finishing (whether you found issues or not), update
   `.claude/sweep-performance-state.csv` following the state-CSV contract
   in .claude/commands/_sweep-common.md (csv.DictReader/DictWriter pattern,
   one line per record). Header:

   `module,last_inspected,oom_verdict,bottleneck,high_count,issue,notes`

   Set `high_count` to the integer count of HIGH findings. Then `git add`
   and commit it to the worktree branch so the state update is included in
   the PR.

Additional performance-specific rules:
- For CUDA code, verify register pressure and bounds before flagging.
- The 30TB graph simulation NEVER calls `.compute()` — it constructs the
  dask graph and inspects it.

{agent contract from _sweep-common.md, verbatim}
~~~

### 5c. Print a status line

After dispatching, print:

```
Launched {N} performance audit agents: {module1}, {module2}, {module3}
```

## Step 6 -- State updates

State is updated by the subagents themselves (see agent prompt step 6).
To reset all tracking: `/sweep-performance --reset-state`
