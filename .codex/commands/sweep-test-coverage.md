# Test Coverage Gap Sweep: Dispatch subagents to audit backend and edge-case test coverage

Audit xrspatial modules for test coverage gaps: missing backend coverage
(numpy / cupy / dask+numpy / dask+cupy), missing edge cases (NaN, Inf,
empty input, single-pixel, all-equal input), missing parameter-coverage
tests. Closes the gaps that the accuracy sweep keeps finding bugs in.
Subagents fix CRITICAL, HIGH, and MEDIUM findings via /rockout — fixes
here are *adding tests*, not changing source code.

Optional arguments: $ARGUMENTS
(e.g. `--top 3`, `--exclude slope,aspect`, `--only-terrain`, `--reset-state`,
`--no-fix`)

**Read `.codex/commands/_sweep-common.md` first.** It defines module
discovery, the standard flag set, module groups, the CUDA probe, the
state-CSV contract, the severity rubric, the repro gate, and the agent
contract. This file adds only what is specific to the test-coverage sweep.

---

## Step 0 -- Parse arguments and probe CUDA

Parse the standard flags per _sweep-common.md (no extra flags for this
sweep). Run the CUDA availability probe and capture `CUDA_AVAILABLE`. For
this sweep the flag decides whether new cupy / dask+cupy tests can be
executed locally or only added with the project's GPU-skip guard.

## Step 1 -- Discover modules and gather metadata

Discover modules per _sweep-common.md. Collect the common metadata fields
(last_modified, total_commits, loc, public_funcs) plus measured coverage:

| Field | How |
|-------|-----|
| **test_loc** | `wc -l < xrspatial/tests/test_<module>.py` (or 0 if absent) |
| **branch_cov** | measured branch coverage percent — see below (0 if no test file) |

Measure `branch_cov` with one batched run over the selected candidates
(coverage is the measured truth here, the way flake8 output is for the
style sweep):

```bash
NUMBA_DISABLE_JIT=1 python -m pytest xrspatial/tests/test_<module>.py \
    --cov=xrspatial.<module> --cov-branch --cov-report=json:<scratchpad>/cov_<module>.json -q
```

`NUMBA_DISABLE_JIT=1` is required: coverage instrumentation clashes with
numba's extension registration under pytest-cov (observed as `KeyError:
duplicate registration`), and disabling JIT is also what makes kernel
bodies traceable — compiled code is invisible to coverage.

Parse `totals.percent_covered` from each JSON (round to an integer). For
subpackages, use `--cov=xrspatial.<subpackage>` and the subpackage's test
file(s). If the test run errors, record `branch_cov = 0` and note
`tests-broken` — a broken test file is itself a HIGH finding for the agent.
Keep the per-module JSON files; each agent gets its module's uncovered-line
report.

## Step 2 -- Load inspection state

Read `.codex/sweep-test-coverage-state.csv` per the state-CSV contract in
_sweep-common.md. Schema (one row per module):

```
module,last_inspected,issue,severity_max,categories_found,branch_cov,notes
slope,2026-05-01,1042,HIGH,1;3,87,"optional single-line notes"
```

(Older state files may lack the `branch_cov` column; the read-update-write
pattern backfills it as empty for rows not yet re-inspected.)

## Step 3 -- Score each module

```
days_since_inspected = (today - last_inspected).days   # 9999 if never
days_since_modified  = (today - last_modified).days

score = (days_since_inspected * 3)
      + (public_funcs * 5)
      + ((100 - branch_cov) * 4)
      + (total_commits * 0.3)
      - (days_since_modified * 0.1)
      + (loc * 0.03)
```

Rationale:
- Modules never inspected dominate
- Measured branch-coverage deficit is the strongest signal (up to 400 for a
  totally untested module) — observed truth, not a LOC-ratio proxy
- Public functions weighted: each public function is an independent
  test surface
- Recently modified slightly deprioritized

## Step 4 -- Apply filters from $ARGUMENTS

Apply the standard flags (`--top N` default 3, `--exclude`, `--only-<group>`,
`--high-only`, `--reset-state`, `--include-experimental`) per
_sweep-common.md.

## Step 5 -- Print the ranked table and launch subagents

### 5a. Print the ranked table

Show all scored modules sorted by score descending. Include a `Branch Cov`
column (measured percent) alongside Rank, Module, Score, Last Inspected,
Pub Funcs, LOC.

### 5b. Launch subagents for the top N modules

Launch one Agent per selected module per the dispatch rules in
_sweep-common.md (single message, `isolation: "worktree"`, `mode: "auto"`).

Each agent's prompt must be self-contained:

```
You are auditing the xrspatial module "{module}" for test coverage gaps.

This module has {commits} commits, {loc} lines of source, {test_loc} lines
of tests, and MEASURED branch coverage of {branch_cov}%.

Read these files:
- {module_files}
- xrspatial/tests/test_{module}.py (if it exists)
- xrspatial/tests/general_checks.py (cross-backend test helpers)
- xrspatial/utils.py (ArrayTypeFunctionMapping, _validate_raster)
- xrspatial/conftest.py (shared fixtures)

The parent already ran pytest with branch coverage; the uncovered-line
report for this module is at {cov_json_path}. Start from it: every
uncovered branch is a candidate gap, and every gap you flag should
correspond to genuinely unexercised behavior, not just an uncovered line
of boilerplate. Re-run the coverage command yourself if you need fresher
data after reading the tests.

CUDA available on this host: {cuda_available}

If CUDA_AVAILABLE is true:
- New cupy / dask+cupy tests must execute locally before /rockout opens
  a PR. Use the cross-backend helpers in general_checks.py so the new
  test exercises all four backends on a CUDA host.
- Verify the test actually fails before the fix and passes after — do
  not commit a test that was never observed running on a GPU.

If CUDA_AVAILABLE is false:
- New cupy / dask+cupy tests are still added (CI runs them on a GPU
  host) but must be guarded with the project's existing GPU-skip
  decorator so local runs without CUDA do not error. Note that the
  test was not executed locally.
- Add the token `cuda-unavailable` to the `notes` column of the state
  CSV so a future re-run on a GPU host knows to re-validate that the
  newly added cupy tests pass.

**Your task:**

1. Read the module and its tests thoroughly. Build a mental matrix:
   for each public function, which backends and which edge cases are
   currently tested? Cross-check the matrix against the uncovered-line
   report.

2. Audit for these 5 coverage-gap categories. Only flag gaps ACTUALLY
   present (the test file does not exercise the path).

   **Cat 1 — Backend coverage**
   - HIGH: function has a numpy path that is tested, but the cupy /
     dask+numpy / dask+cupy paths are not exercised at all
   - HIGH: dispatch table (ArrayTypeFunctionMapping) registers a backend
     but no test invokes it
   - MEDIUM: cross-backend equivalence not asserted (test_numpy_equals_cupy,
     test_numpy_equals_dask, test_numpy_equals_dask_cupy missing)
   - MEDIUM: only the eager path tested with realistic input shapes; the
     dask path tested only on a 4x4 toy
   Severity: HIGH if a real bug could ship undetected (the GLCM bug
   #1408 was caught precisely because backend coverage existed)

   **Cat 2 — NaN / Inf / nodata edge cases**
   - HIGH: function operates on raster data but no test passes a NaN
     input
   - HIGH: NaN appears in tests only as a non-edge cell, never at the
     boundary or in a position that interacts with the kernel
   - HIGH: Inf / -Inf inputs not tested at all (often surfaces silent
     failure modes)
   - MEDIUM: all-NaN input not tested (boundary of the algorithm)
   - MEDIUM: NaN input dtype is float; but integer dtype with the
     module's documented sentinel is not tested
   Severity: HIGH if NaN-related bugs in this module class have shipped
   before (see flood, glcm, sky_view_factor) — they have

   **Cat 3 — Geometric edge cases**
   - HIGH: 1x1 single-pixel raster not tested
   - HIGH: Nx1 or 1xN strip not tested (kernel boundary degeneracies)
   - MEDIUM: empty raster (0 rows or 0 cols) not tested
   - MEDIUM: all-equal-value raster not tested (zero variance, zero
     gradient → divide-by-zero opportunity)
   - MEDIUM: very large raster not benchmarked (no asv coverage)
   - LOW: raster with non-square cells (different cellsize_x and
     cellsize_y) not tested
   Severity: HIGH for 1x1 / Nx1 — these reveal kernel-bound bugs

   **Cat 4 — Parameter coverage**
   - HIGH: a parameter with multiple modes (e.g. `boundary='reflect'`,
     `'edge'`, `'wrap'`, `'nan'`) has only the default mode tested
   - HIGH: a `bool` flag has only one branch tested
   - MEDIUM: a numeric parameter has only one value tested (e.g.
     `kernel_size` only tested at 3, never at 5 or 7)
   - MEDIUM: error paths not tested (does invalid input raise the
     expected exception?)
   - LOW: kwargs documented in docstring but no test passes them
   Severity: HIGH if the untested mode is what advanced users rely on

   **Cat 5 — Metadata preservation tests**
   - HIGH: no test asserts that input attrs (`res`, `crs`, `transform`)
     are preserved in the output (this is the metadata-propagation
     sweep's smoke detector)
   - HIGH: no test asserts that input coords are preserved
   - MEDIUM: no test asserts that input dim names propagate (function
     would silently rename `lat`/`lon` → `y`/`x`)
   - MEDIUM: no test for the eager-vs-dask attrs equivalence
   Severity: HIGH if this module reads attrs for math (cellsize,
   resolution) — its result correctness depends on these being correct

3. For each real gap, assign severity per the rubric in _sweep-common.md
   plus which test should be added. The repro-gate evidence for a
   CRITICAL/HIGH gap is the coverage report line(s) or a demonstration
   that the new test exercises a previously-unexercised path (coverage
   before/after).

4. If any CRITICAL, HIGH, or MEDIUM gap is found, run /rockout to add
   tests. The fix in this sweep is *test-only* — do not modify source
   unless a test surfaces a bug, in which case file a separate accuracy
   issue. For LOW gaps, document but do not add tests. Skip /rockout
   entirely if the parent sweep was run with --no-fix; record findings in
   the state notes instead.

5. After finishing (whether you found issues or not), update
   .codex/sweep-test-coverage-state.csv following the state-CSV contract
   in .codex/commands/_sweep-common.md (csv.DictReader/DictWriter pattern,
   one line per record). Header:

   `module,last_inspected,issue,severity_max,categories_found,branch_cov,notes`

   Set `branch_cov` to the measured percent AFTER your added tests (re-run
   the coverage command), so the state row records the improvement. Then
   `git add` and commit.

Additional test-coverage-specific rules:
- If a test exists but is sloppy, that is not a coverage gap — that's a
  test quality issue out of scope here.
- Some functions genuinely do not need NaN coverage (procedural noise
  generators that take no raster input). Use judgment.
- If the module's test file itself fails to run (`tests-broken` in the
  parent metadata), fixing the test file so it runs is your first HIGH
  finding.

{agent contract from _sweep-common.md, verbatim}
```

### 5c. Print a status line

After dispatching, print:

```
Launched {N} test coverage audit agents: {module1}, {module2}, {module3}
```

## Step 6 -- State updates

State is updated by the subagents themselves (see agent prompt step 5).
To reset all tracking: `/sweep-test-coverage --reset-state`
