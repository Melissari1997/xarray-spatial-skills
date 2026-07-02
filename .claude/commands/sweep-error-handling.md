# Error Handling Sweep: Dispatch subagents to audit input validation and error-message quality

Audit xrspatial modules for the failure-path user experience: public
functions that skip input validation, errors raised far from their cause
with unactionable messages, bad input that yields garbage output instead of
an exception, inconsistent exception types across sibling functions, and
over-broad exception handlers that swallow real errors. Production users
judge a library by its worst error message. Subagents fix CRITICAL, HIGH,
and MEDIUM findings via /rockout.

Optional arguments: $ARGUMENTS
(e.g. `--top 3`, `--exclude slope,aspect`, `--only-terrain`, `--reset-state`,
`--no-fix`)

**Read `.claude/commands/_sweep-common.md` first.** It defines module
discovery, the standard flag set, module groups, the CUDA probe, the
state-CSV contract, the severity rubric, the repro gate, and the agent
contract. This file adds only what is specific to the error-handling sweep.

---

## Step 0 -- Parse arguments and probe CUDA

Parse the standard flags per _sweep-common.md (no extra flags for this
sweep). Run the CUDA availability probe and capture `CUDA_AVAILABLE`.

## Step 1 -- Discover modules and gather metadata

Discover modules per _sweep-common.md. Collect the common metadata fields
(last_modified, total_commits, loc, public_funcs) plus:

| Field | How |
|-------|-----|
| **validate_calls** | `grep -c '_validate_raster' <files>` |
| **raise_count** | `grep -cE '^\s*raise ' <files>` |
| **broad_excepts** | `grep -cE 'except(\s*:|\s+Exception)' <files>` |

## Step 2 -- Load inspection state

Read `.claude/sweep-error-handling-state.csv` per the state-CSV contract in
_sweep-common.md. Schema (one row per module):

```
module,last_inspected,issue,severity_max,categories_found,notes
slope,2026-07-01,1620,HIGH,1;3,"optional single-line notes"
```

## Step 3 -- Score each module

```
days_since_inspected = (today - last_inspected).days   # 9999 if never
days_since_modified  = (today - last_modified).days
validation_gap       = max(0, public_funcs - validate_calls)

score = (days_since_inspected * 3)
      + (validation_gap * 100)
      + (broad_excepts * 150)
      + (public_funcs * 5)
      - (raise_count * 5)
      - (days_since_modified * 0.1)
      + (loc * 0.03)
```

Rationale:
- A public function with no _validate_raster call is the highest-yield
  place to look (100 per gap)
- Broad/bare excepts are strong signals of swallowed errors (150 each)
- Many public functions = more failure surface
- Modules that already raise a lot have at least thought about failure
  paths (small credit per raise)

## Step 4 -- Apply filters from $ARGUMENTS

Apply the standard flags (`--top N` default 3, `--exclude`, `--only-<group>`,
`--high-only`, `--reset-state`, `--include-experimental`) per
_sweep-common.md.

## Step 5 -- Print the ranked table and launch subagents

### 5a. Print the ranked table

Print a markdown table showing ALL scored modules sorted by score
descending, with columns Rank, Module, Score, Last Inspected, Pub Funcs,
Validate Calls, Broad Excepts, LOC.

### 5b. Launch subagents for the top N modules

Launch one Agent per selected module per the dispatch rules in
_sweep-common.md (single message, `isolation: "worktree"`, `mode: "auto"`).

Each agent's prompt must be self-contained:

```
You are auditing the xrspatial module "{module}" for error-handling and
input-validation quality.

This module has {commits} commits, {loc} lines of code, {public_funcs}
public functions, {validate_calls} _validate_raster call sites, and
{broad_excepts} broad/bare except clauses.

Read these files: {module_files}

Also read xrspatial/utils.py — especially _validate_raster(): what it
checks, what exceptions it raises, and what its messages look like. It is
the project's validation convention; deviations from it are the findings.

**Execute the failure paths.** For each public function, actually call it
with a battery of bad inputs on this host (numpy backend; dask+numpy for
functions with a dask path) and record what happens:
- a plain numpy array instead of a DataArray
- a 3D DataArray where 2D is expected (and vice versa)
- an integer-dtype raster where float is assumed
- a DataArray with no coords / no res attr (cellsize inference must fail
  loudly or fall back documented-ly)
- NaN-filled and zero-size inputs
- out-of-domain parameter values (negative kernel size, zero cellsize,
  unknown mode strings)
The observed behavior — exception type, message text, or silent garbage —
is your evidence. Do not flag from reading alone.

CUDA available on this host: {cuda_available}

If CUDA_AVAILABLE is true, repeat a spot-check of the battery on cupy
inputs — error behavior should not differ by backend. If false, review the
cupy paths statically and add `cuda-unavailable` to the state notes.

**Your task:**

1. Read all listed files and the matching tests (error-path tests tell you
   which behaviors are intentional).

2. Audit for these 5 categories. Only flag issues ACTUALLY observed.

   **Cat 1 — Missing input validation**
   - HIGH: public function skips _validate_raster (or equivalent checks)
     and a malformed input reaches the compute kernel
   - MEDIUM: validation exists but misses a case the kernel assumes
     (e.g. checks dims but not dtype)
   - MEDIUM: validation happens after expensive work (fail late instead
     of fail fast)
   Severity: HIGH when the unvalidated input produces a crash deep in
   numba/dask with an inscrutable traceback

   **Cat 2 — Unactionable error messages**
   - HIGH: the raised message omits what was wrong and what was expected
     (no offending value, dtype, shape, or parameter name)
   - MEDIUM: error raised deep in a helper so the traceback points at
     internals instead of the user's mistake
   - MEDIUM: message says something misleading about the actual cause
   - LOW: message is correct but terse (no hint at the fix)
   Severity: judge by the observed traceback from your bad-input battery —
   would a user know what to change?

   **Cat 3 — Silent failure modes**
   - CRITICAL: bad input produces plausible-looking garbage output with
     no exception and no warning (the worst production failure)
   - HIGH: out-of-domain parameter silently clamped or ignored
   - MEDIUM: NaN-poisoned output with no documentation that NaN input
     propagates
   Severity: CRITICAL/HIGH per above — these are the errors users cannot
   see

   **Cat 4 — Inconsistent exception contracts**
   - MEDIUM: the same error class raises TypeError in one sibling function
     and ValueError (or a bare Exception) in another
   - MEDIUM: one function raises, its sibling returns None / empty result
     for the same bad input
   - LOW: exception type is fine but message format drifts from
     _validate_raster's convention
   Severity: MEDIUM — breaks users' except clauses when they switch
   functions

   **Cat 5 — Swallowed errors**
   - HIGH: bare `except:` or `except Exception:` that suppresses the error
     and continues (can hide real bugs and KeyboardInterrupt)
   - MEDIUM: exception caught and re-raised as a different type losing the
     original context (no `from e`)
   - MEDIUM: exception caught and logged/printed but the function returns
     a partial result as if it succeeded
   Severity: HIGH when the swallowed path can hide a wrong result

3. For each real issue, assign severity per the rubric in _sweep-common.md
   plus file:line. The repro gate is satisfied by your bad-input battery —
   paste the call, the observed behavior, and the expected behavior into
   the issue for every CRITICAL/HIGH finding.

4. If any CRITICAL, HIGH, or MEDIUM issue is found, run /rockout to fix it
   end-to-end (GitHub issue, worktree branch, fix, tests, and PR). Fixes
   must include an error-path test asserting the new exception type and
   message content. Changing an exception TYPE on a public function is a
   breaking change — call that out in the issue and prefer keeping the
   type while fixing the message unless the current type is clearly wrong.
   For LOW issues, document but do not fix. Skip /rockout entirely if the
   parent sweep was run with --no-fix; record findings in the state notes
   instead.

5. After finishing, update .claude/sweep-error-handling-state.csv following
   the state-CSV contract in .claude/commands/_sweep-common.md. Header:

   `module,last_inspected,issue,severity_max,categories_found,notes`

   Then `git add` and commit.

Additional error-handling rules:
- Intentional permissiveness documented in the docstring (e.g. "NaN cells
  are ignored") is not a finding; undocumented permissiveness is.
- Do not add validation so strict it breaks currently-working documented
  usage; the tests must keep passing.

{agent contract from _sweep-common.md, verbatim}
```

### 5c. Print a status line

After dispatching, print:

```
Launched {N} error handling audit agents: {module1}, {module2}, {module3}
```

## Step 6 -- State updates

State is updated by the subagents themselves (see agent prompt step 5).
To reset all tracking: `/sweep-error-handling --reset-state`
