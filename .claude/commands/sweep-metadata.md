# Metadata Propagation Sweep: Dispatch subagents to audit modules for metadata preservation

Audit xrspatial modules for metadata propagation bugs: attrs (especially
`res`, `crs`, `transform`, `nodatavals`, `_FillValue`), coords (x/y values
and dims), and dim names. Spatial libs lose CRS/transform silently and the
result looks correct but is wrong. The sky_view_factor cellsize bug
(#1407) was exactly this class of issue. Subagents fix CRITICAL, HIGH, and
MEDIUM findings via /rockout.

Optional arguments: $ARGUMENTS
(e.g. `--top 3`, `--exclude slope,aspect`, `--only-terrain`, `--reset-state`,
`--no-fix`)

**Read `.claude/commands/_sweep-common.md` first.** It defines module
discovery, the standard flag set, module groups, the CUDA probe, the
state-CSV contract, the severity rubric, the repro gate, and the agent
contract. This file adds only what is specific to the metadata sweep.

---

## Step 0 -- Parse arguments and probe CUDA

Parse the standard flags per _sweep-common.md (no extra flags for this
sweep). Run the CUDA availability probe and capture `CUDA_AVAILABLE`.

## Step 1 -- Discover modules and gather metadata

Discover modules per _sweep-common.md. Collect the common metadata fields
(last_modified, total_commits, loc, public_funcs). No sweep-specific extras.

## Step 2 -- Load inspection state

Read `.claude/sweep-metadata-state.csv` per the state-CSV contract in
_sweep-common.md. Schema (one row per module):

```
module,last_inspected,issue,severity_max,categories_found,notes
slope,2026-05-01,1042,HIGH,1;3,"optional single-line notes"
```

## Step 3 -- Score each module

```
days_since_inspected = (today - last_inspected).days   # 9999 if never
days_since_modified  = (today - last_modified).days

score = (days_since_inspected * 3)
      + (public_funcs * 5)
      + (total_commits * 0.3)
      - (days_since_modified * 0.2)
      + (loc * 0.05)
```

Rationale:
- Modules never inspected dominate (9999 * 3)
- More public functions = more API surface that could lose metadata
- More commits = more refactor risk for metadata propagation
- Recently modified modules slightly deprioritized
- Larger files have more surface area

## Step 4 -- Apply filters from $ARGUMENTS

Apply the standard flags (`--top N` default 3, `--exclude`, `--only-<group>`,
`--high-only`, `--reset-state`, `--include-experimental`) per
_sweep-common.md.

## Step 5 -- Print the ranked table and launch subagents

### 5a. Print the ranked table

Print a markdown table showing ALL scored modules sorted by score
descending, with columns Rank, Module, Score, Last Inspected, Pub Funcs,
Commits, LOC.

### 5b. Launch subagents for the top N modules

Launch one Agent per selected module per the dispatch rules in
_sweep-common.md (single message, `isolation: "worktree"`, `mode: "auto"`).

Each agent's prompt must be self-contained and follow this template (adapt
the module name, paths, and metadata):

```
You are auditing the xrspatial module "{module}" for metadata propagation issues.

This module has {commits} commits and {loc} lines of code.

Read these files: {module_files}

Also read xrspatial/utils.py to understand:
- _validate_raster() behavior — what does it accept/reject?
- get_dataarray_resolution() — what attrs does it pull from?
- ngjit / ArrayTypeFunctionMapping dispatch helpers

Read xrspatial/tests/general_checks.py for cross-backend test helpers.

**Execute, don't infer.** Metadata behavior is observed, not read. For
EVERY public function you audit, construct a tiny georeferenced input
(e.g. a 8x8 DataArray with real x/y coords, `res`, `crs`, `transform`,
`nodatavals`, `_FillValue` attrs, an extra passthrough coord, and
non-default dim names where the function claims to support them), run the
function end-to-end on the numpy AND dask+numpy backends — these run on
every host — and inspect attrs/coords/dims/dtype of the actual returned
object. Cat 1-4 findings must come from an observed input→output
discrepancy, not from reading the return statement.

CUDA available on this host: {cuda_available}

If CUDA_AVAILABLE is true:
- Extend the same end-to-end check to cupy and dask+cupy DataArrays so
  Cat 5 (backend-inconsistent metadata) findings are observed on all four
  backends.

If CUDA_AVAILABLE is false:
- Inspect the cupy / dask+cupy paths by reading the source only; the
  numpy and dask+numpy end-to-end checks above still apply in full.
- Add the token `cuda-unavailable` to the `notes` column of the state CSV.

**Your task:**

1. Read all listed files thoroughly, including the matching test file(s)
   under xrspatial/tests/ so you understand expected behavior. Pay
   particular attention to whether tests assert on attrs/coords/dims of
   the returned DataArray.

2. Audit for these 5 metadata-propagation categories. Only flag issues
   ACTUALLY present in the code.

   **Cat 1 — attrs preservation**
   - HIGH: result DataArray has empty attrs even though input had attrs
     (`return xr.DataArray(out_data, dims=...)` instead of `dims=in.dims,
     attrs=in.attrs`)
   - HIGH: function silently drops `res`, `crs`, `transform`, or
     `nodatavals` from input attrs
   - HIGH: function reads `attrs['res']` for math but does not re-emit it
     on output (downstream callers see no res, recompute from coords,
     get different answer)
   - MEDIUM: function copies attrs but adds an inferred attr that
     overwrites a user-provided value (e.g. always sets `nodatavals` to
     `[np.nan]` even if input had `[-9999]`)
   - MEDIUM: attrs propagated for the eager path but lost on the dask path
     (or vice versa)
   Severity: HIGH if downstream spatial computation is affected (slope of
   a no-CRS raster gives wrong cell-size answers); MEDIUM otherwise

   **Cat 2 — coords preservation**
   - HIGH: result has integer-index coords (0,1,2,...) when input had
     georeferenced coords (lon/lat or projected x/y)
   - HIGH: coordinate values are stale by half-a-pixel after resampling
     (centre vs corner convention drift)
   - HIGH: coord dtype changes (float64 → float32) silently between input
     and output
   - MEDIUM: extra coords from input (e.g. `time`, `band`) are dropped on
     output even though they should pass through
   - MEDIUM: coord names renamed without the function documenting why
     (`x` → `lon`, `y` → `lat`, etc.)
   Severity: HIGH if downstream coord-based math (clipping, interp) breaks

   **Cat 3 — dim names and order**
   - HIGH: output dim order differs from input dim order without
     documentation (e.g. input `(y, x)`, output `(x, y)`)
   - HIGH: output has fewer/more dims than input without the function
     docstring saying so (e.g. reduces over `y` but doesn't reflect that
     in the dim list)
   - MEDIUM: function assumes hardcoded dim names (`y`, `x`) and silently
     mis-aligns when input uses (`lat`, `lon`) or (`row`, `col`)
   - MEDIUM: dask backend preserves dims, numpy backend does not (or vice
     versa)
   Severity: HIGH if it breaks chained xarray operations

   **Cat 4 — dtype and nodata semantics**
   - HIGH: function reads `attrs['nodatavals']` for input mask but does
     not propagate it to output (so a chained call sees the old nodata,
     possibly wrong)
   - HIGH: output dtype hardcoded to float64 even when input was uint8
     (memory blowup; downstream stats wrong)
   - MEDIUM: NaN used as the nodata sentinel internally but output dtype
     is integer (NaN cannot represent — silent conversion to MIN_INT or 0)
   - MEDIUM: `_FillValue` attr present on input but not on output
   Severity: HIGH if nodata mask is silently flipped or dtype change
   causes wrong arithmetic downstream

   **Cat 5 — backend-inconsistent metadata**
   - HIGH: numpy and cupy backends emit attrs differently (e.g. numpy
     keeps `crs`, cupy drops it, or numpy emits `_FillValue`, cupy emits
     `nodatavals`)
   - HIGH: dask path's metadata is computed from chunk-local stats not
     global stats (e.g. `attrs['min']` is per-chunk min, not global min)
   - MEDIUM: only one of the four backends (numpy / cupy / dask+numpy /
     dask+cupy) preserves attrs
   - MEDIUM: result name (`.name`) inconsistent across backends
   Severity: HIGH if a chained pipeline silently produces different
   numbers depending on which backend is active

3. For each real issue found, assign a severity (CRITICAL/HIGH/MEDIUM/LOW)
   per the rubric in _sweep-common.md and note the exact file and line
   number. The end-to-end scripts from "Execute, don't infer" are your
   repro-gate evidence — paste the relevant input/output snippet into the
   issue for every CRITICAL/HIGH finding.

4. If any CRITICAL, HIGH, or MEDIUM issue is found, run /rockout to fix it
   end-to-end (GitHub issue, worktree branch, fix, tests, and PR). A fix
   that touches metadata-emitting code must verify every backend runnable
   on this host before opening the PR. For LOW issues, document them but
   do not fix. Skip /rockout entirely if the parent sweep was run with
   --no-fix; record findings in the state notes instead.

5. After finishing (whether you found issues or not), update
   .claude/sweep-metadata-state.csv following the state-CSV contract in
   .claude/commands/_sweep-common.md (csv.DictReader/DictWriter pattern,
   one line per record). Header:

   `module,last_inspected,issue,severity_max,categories_found,notes`

   Then `git add` and commit it to the worktree branch so the state update
   lands in the PR.

Additional metadata-specific rules:
- A test may codify the current behavior intentionally (e.g. an
  aggregation that genuinely drops a dim) — check before flagging.

{agent contract from _sweep-common.md, verbatim}
```

### 5c. Print a status line

After dispatching, print:

```
Launched {N} metadata propagation audit agents: {module1}, {module2}, {module3}
```

## Step 6 -- State updates

State is updated by the subagents themselves (see agent prompt step 5).
To reset all tracking: `/sweep-metadata --reset-state`
