# Accuracy Sweep: Dispatch subagents to audit modules for numerical accuracy issues

Audit xrspatial modules for numerical accuracy issues: floating point
precision loss, incorrect NaN propagation, off-by-one errors in neighborhood
operations, missing or wrong Earth curvature corrections, backend
inconsistencies (numpy vs cupy vs dask results differ), and divergence from
reference implementations. Subagents fix findings via rockout.

Optional arguments: {{ARGUMENTS}}
(e.g. `--top 3`, `--exclude slope,aspect`, `--only-terrain`, `--reset-state`,
`--no-fix`)

**Read `.kilo/command/_sweep-common.md` first.** It defines module
discovery, the standard flag set, module groups, the CUDA probe, the
state-CSV contract, the severity rubric, the repro gate, and the agent
contract. This file adds only what is specific to the accuracy sweep.

---

## Step 0 -- Parse arguments and probe CUDA

Parse the standard flags per _sweep-common.md (no extra flags for this
sweep). Run the CUDA availability probe and capture `CUDA_AVAILABLE`.

## Step 1 -- Discover modules and gather metadata

Discover modules per _sweep-common.md. Collect the common metadata fields
(last_modified, total_commits, loc) plus:

| Field | How |
|-------|-----|
| **recent_accuracy_commits** | `git log --oneline --grep='accuracy\|precision\|numerical\|geodesic' -- <path>` |

## Step 2 -- Load inspection state

Read `.kilo/worktrees/sweep-accuracy-state.csv` per the state-CSV contract in
_sweep-common.md. Schema (one row per module):

```
module,last_inspected,issue,severity_max,categories_found,notes
slope,2026-03-28,1042,HIGH,1;3,"optional single-line notes"
```

## Step 3 -- Score each module

```
days_since_inspected = (today - last_inspected).days   # 9999 if never
days_since_modified  = (today - last_modified).days
has_recent_accuracy_work = 1 if recent_accuracy_commits is non-empty, else 0

score = (days_since_inspected * 3)
      + (total_commits * 0.5)
      - (days_since_modified * 0.2)
      - (has_recent_accuracy_work * 500)
      + (loc * 0.05)
```

Rationale:
- Modules never inspected dominate (9999 * 3)
- More commits = more complex = more likely to have accuracy bugs
- Recently modified modules slightly deprioritized (someone just touched them)
- Modules with existing accuracy work heavily deprioritized
- Larger files have more surface area (0.05 per line)

## Step 4 -- Apply filters from {{ARGUMENTS}}

Apply the standard flags (`--top N` default 3, `--exclude`, `--only-<group>`,
`--high-only`, `--reset-state`, `--include-experimental`) per
_sweep-common.md.

## Step 5 -- Print the ranked table and launch subagents

### 5a. Print the ranked table

Print a markdown table showing ALL scored modules (not just selected ones),
sorted by score descending:

```
| Rank | Module          | Score  | Last Inspected | Last Modified | Commits | LOC  |
|------|-----------------|--------|----------------|---------------|---------|------|
| 1    | viewshed        | 30012  | never          | 45 days ago   | 23      | 800  |
| 2    | flood           | 29998  | never          | 120 days ago  | 18      | 600  |
| ...  | ...             | ...    | ...            | ...           | ...     | ...  |
```

### 5b. Launch subagents for the top N modules

Launch one Agent per selected module per the dispatch rules in
_sweep-common.md (single message, `isolation: "worktree"`, `mode: "auto"`).

Each agent's prompt must be self-contained and follow this template (adapt
the module name, paths, and metadata):

```
You are auditing the xrspatial module "{module}" for numerical accuracy issues.

This module has {commits} commits and {loc} lines of code.

Read these files: {module_files}

Also read xrspatial/utils.py to understand _validate_raster() behavior and
xrspatial/tests/general_checks.py for the cross-backend comparison helpers.

CUDA available on this host: {cuda_available}

If CUDA_AVAILABLE is true:
- When auditing the cupy / dask+cupy backends, actually run the matching
  tests in xrspatial/tests/ against those backends. The cross-backend
  helpers in general_checks.py already dispatch to all four backends —
  invoke them directly so cupy and dask+cupy paths execute, not just
  numpy.
- For CUDA-specific findings (kernel correctness, NaN propagation in
  device code, backend divergence), validate by running the kernel on
  a small input rather than reasoning from source alone.

If CUDA_AVAILABLE is false:
- Read the cupy / dask+cupy paths and flag patterns by inspection only.
- Skip executing tests on those backends. Add the token
  `cuda-unavailable` to the `notes` column of the state CSV.

**Your task:**

1. Read all listed files thoroughly, including the matching test file(s)
   under xrspatial/tests/ so you understand expected behavior.

2. Audit for these 6 accuracy categories. For each, look for the specific
   patterns described. Only flag issues ACTUALLY present in the code.

   **Cat 1 — Floating Point Precision Loss**
   - Accumulation loops that sum many small values into a large running
     total without Kahan summation or compensated accumulation
   - float32 used where float64 is required for stable intermediate results
     (e.g. large grids, long gradients, iterative solvers)
   - Subtraction of nearly-equal large quantities (catastrophic cancellation)
   - Division by small numbers without a stability floor
   Severity: HIGH if the result is visibly wrong on realistic inputs;
   MEDIUM if only observable on adversarial inputs

   **Cat 2 — NaN / Inf Propagation Errors**
   - NaN input silently produces a finite output (masked, skipped, or
     treated as zero without being documented)
   - NaN check using `==` instead of `!= x` for NaN detection in numba
   - Neighborhood operations that ignore NaN pixels but do not update the
     normalization denominator, biasing the result
   - Inf / -Inf inputs treated as numbers in comparisons without guards
   - Divide-by-zero producing Inf that then corrupts downstream accumulation
   Severity: HIGH if NaN input yields a wrong but finite output;
   MEDIUM if the behavior is documented but still surprising

   **Cat 3 — Off-by-One Errors in Neighborhood Operations**
   - Loop bounds that exclude the last row/column (e.g. `range(H-1)` where
     `range(H)` is intended)
   - `map_overlap` depth that is smaller than the actual stencil radius
   - Boundary handling that duplicates or skips edge pixels
   - Asymmetric kernel indexing (one-sided rather than centered)
   - CUDA kernel bounds guard that is `i > H` instead of `i >= H`
   Severity: HIGH if it causes a silent wrong result at all chunk boundaries;
   MEDIUM if it only affects a single-pixel edge

   **Cat 4 — Missing or Wrong Earth Curvature / Projection Corrections**
   - Geodesic calculations that assume a flat projection without curvature
     correction (see slope.py, aspect.py, geodesic.py for the reference
     pattern: `u += (e² + n²) / (2R)`)
   - Haversine / great-circle distance using the wrong Earth radius
     constant, or using a spherical approximation where WGS84 is needed
   - Mixing projected and geographic coordinates in the same calculation
     without a transform
   - Using cell size in degrees as if it were meters
   Severity: HIGH if the correction is missing entirely on a public API;
   MEDIUM if the correction is present but uses a questionable constant

   **Cat 5 — Backend Inconsistency (numpy vs cupy vs dask)**
   - numpy and cupy paths use different algorithms that can diverge on
     identical inputs (e.g. different boundary handling, different NaN
     semantics, different numerical precision)
   - dask path silently falls back to materializing the full array
   - dask `map_overlap` chunk function returns a different shape than the
     input, corrupting the reassembled array
   - A backend raises on valid input that another backend accepts
   - Result dtype differs across backends without documentation
   Severity: HIGH if numerically different results on the same input;
   MEDIUM if only metadata (dtype, coords) differs

   **Cat 6 — Reference Divergence**
   Where this module has a well-known reference implementation available on
   this host, run both on a small synthetic DEM (e.g. a 64x64 Gaussian hill
   with realistic cellsize) and compare within a stated tolerance:
   - slope / aspect / hillshade / terrain_metrics (roughness, TRI, TPI):
     compare against `gdaldem` if the `gdal` CLI or `osgeo` is importable
   - focal / convolution / morphology: compare against `scipy.ndimage`
   - curvature / hydro: compare against `richdem` if importable
   If the reference tool is not installed, skip the comparison and add the
   token `<tool>-unavailable` (e.g. `gdal-unavailable`) to the state notes.
   Account for legitimate convention differences (e.g. Horn vs
   Zevenbergen-Thorne stencils, azimuth origin) before calling a delta a
   divergence — a documented convention difference is not a finding.
   Severity: HIGH if results diverge beyond tolerance for the SAME
   documented algorithm; MEDIUM if the divergence traces to an undocumented
   convention choice

3. Useful invariants for building reproductions (Cat 1-4, 6): a constant
   (flat) input must give zero slope/gradient; results should be invariant
   under 90° rotation of the input (modulo the matching rotation of
   direction-valued outputs); translating the input translates the output;
   scaling elevation by k scales gradients by k. A violated invariant is a
   ready-made repro script.

4. For each real issue found, assign a severity (CRITICAL/HIGH/MEDIUM/LOW)
   per the rubric in _sweep-common.md and note the exact file and line
   number. Apply the repro gate: CRITICAL/HIGH findings need a runnable
   reproduction executed on this host before filing.

5. If any CRITICAL, HIGH, or MEDIUM issue is found, run rockout to fix it
   end-to-end (GitHub issue, worktree branch, fix, tests, and PR) —
   including the reproduction in the issue body. For LOW issues, document
   them but do not fix. Skip rockout entirely if the parent sweep was run
   with --no-fix; record findings in the state notes instead.

6. After finishing (whether you found issues or not), update
   .kilo/worktrees/sweep-accuracy-state.csv following the state-CSV contract in
   .kilo/command/_sweep-common.md (csv.DictReader/DictWriter pattern,
   one line per record). Header:

   `module,last_inspected,issue,severity_max,categories_found,notes`

   Then `git add` and commit it to the worktree branch so the state update
   is included in the PR.

Additional accuracy-specific rules:
- For backend comparisons, check that the cross-backend tests in
  xrspatial/tests/general_checks.py actually exercise the code path you
  are suspicious of; missing test coverage is itself a finding (note it
  for the test-coverage sweep in the state notes).

{agent contract from _sweep-common.md, verbatim}
```

### 5c. Print a status line

After dispatching, print:

```
Launched {N} accuracy audit agents: {module1}, {module2}, {module3}
```

## Step 6 -- State updates

State is updated by the subagents themselves (see agent prompt step 6).
To reset all tracking: `sweep-accuracy --reset-state`
