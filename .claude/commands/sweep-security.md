# Security Sweep: Dispatch subagents to audit modules for security vulnerabilities

Audit xrspatial modules for security issues specific to numeric/GPU raster
libraries: unbounded allocations, integer overflow, NaN logic bombs, GPU
kernel bounds, file path injection, and dtype confusion. Subagents fix
CRITICAL, HIGH, and MEDIUM severity issues via /rockout.

Optional arguments: $ARGUMENTS
(e.g. `--top 3`, `--exclude slope,aspect`, `--only-io`, `--reset-state`,
`--no-fix`)

**Read `.claude/commands/_sweep-common.md` first.** It defines module
discovery, the standard flag set, module groups, the CUDA probe, the
state-CSV contract, the severity rubric, the repro gate, and the agent
contract. This file adds only what is specific to the security sweep.

---

## Step 0 -- Parse arguments and probe CUDA

Parse the standard flags per _sweep-common.md (no extra flags for this
sweep). Run the CUDA availability probe and capture `CUDA_AVAILABLE`.

## Step 1 -- Discover modules and gather metadata

Discover modules per _sweep-common.md. Collect the common metadata fields
(last_modified, total_commits, loc) plus:

| Field | How |
|-------|-----|
| **has_cuda_kernels** | grep file(s) for `@cuda.jit` |
| **has_file_io** | grep file(s) for `open(`, `mkstemp`, `os.path`, `pathlib` |
| **has_numba_jit** | grep file(s) for `@ngjit`, `@njit`, `@jit`, `numba.jit` |
| **allocates_from_dims** | grep file(s) for `np.empty(height`, `np.zeros(height`, `np.empty(H`, `np.empty(h `, `cp.empty(`, and width variants |
| **has_shared_memory** | grep file(s) for `cuda.shared.array` |

## Step 2 -- Load inspection state

Read `.claude/sweep-security-state.csv` per the state-CSV contract in
_sweep-common.md. Schema (one row per module):

```
module,last_inspected,issue,severity_max,categories_found,followup_issues,notes
cost_distance,2026-04-10,1150,HIGH,1;2,,"optional single-line notes"
```

- `followup_issues` is a semicolon-separated integer list (empty when null).

## Step 3 -- Score each module

```
days_since_inspected = (today - last_inspected).days   # 9999 if never
days_since_modified  = (today - last_modified).days

score = (days_since_inspected * 3)
      + (has_file_io * 400)
      + (allocates_from_dims * 300)
      + (has_cuda_kernels * 250)
      + (has_shared_memory * 200)
      + (has_numba_jit * 100)
      + (loc * 0.05)
      - (days_since_modified * 0.2)
```

Rationale:
- File I/O is the only external-escape vector (400)
- Unbounded allocation is a DoS vector across all backends (300)
- CUDA bugs cause silent memory corruption (250)
- Shared memory overflow is a CUDA sub-risk (200)
- Numba JIT is ubiquitous -- lower weight avoids noise (100)
- Larger files have more surface area (0.05 per line)
- Recently modified code slightly deprioritized

## Step 4 -- Apply filters from $ARGUMENTS

Apply the standard flags (`--top N` default 3, `--exclude`, `--only-<group>`,
`--high-only`, `--reset-state`, `--include-experimental`) per
_sweep-common.md.

## Step 5 -- Print the ranked table and launch subagents

### 5a. Print the ranked table

Print a markdown table showing ALL scored modules (not just selected ones),
sorted by score descending:

```
| Rank | Module          | Score  | Last Inspected | CUDA | FileIO | Alloc | Numba | LOC  |
|------|-----------------|--------|----------------|------|--------|-------|-------|------|
| 1    | geotiff         | 30600  | never          | yes  | yes    | no    | yes   | 1400 |
| 2    | hydro           | 30300  | never          | yes  | no     | yes   | yes   | 8200 |
| ...  | ...             | ...    | ...            | ...  | ...    | ...   | ...   | ...  |
```

### 5b. Launch subagents for the top N modules

Launch one Agent per selected module per the dispatch rules in
_sweep-common.md (single message, `isolation: "worktree"`, `mode: "auto"`).

Each agent's prompt must be self-contained and follow this template (adapt
the module name, paths, and metadata):

```
You are auditing the xrspatial module "{module}" for security vulnerabilities.

This module has {commits} commits and {loc} lines of code.

Read these files: {module_files}

Also read xrspatial/utils.py to understand _validate_raster() behavior.

CUDA available on this host: {cuda_available}

If CUDA_AVAILABLE is true:
- For Cat 4 (GPU kernel bounds), validate suspected missing bounds
  guards by running the kernel on adversarial input shapes (1x1, Nx1,
  large prime dimensions) and confirm no out-of-bounds access. Use
  `compute-sanitizer` if installed; otherwise rely on test runs that
  exercise edge sizes.
- For Cat 1 (unbounded allocation) on cupy paths, confirm the
  allocation actually executes on the GPU and observe peak memory via
  `cupy.cuda.runtime.memGetInfo()` rather than reasoning from source.

If CUDA_AVAILABLE is false:
- Inspect the cupy / dask+cupy paths and CUDA kernels by reading the
  source only.
- Skip executing CUDA kernels. Add the token `cuda-unavailable` to the
  `notes` column of the state CSV.

**Your task:**

1. Read all listed files thoroughly.

2. Audit for these 6 security categories. For each, look for the specific
   patterns described. Only flag issues ACTUALLY present in the code.

   **Cat 1 — Unbounded Allocation / Denial of Service**
   - np.empty(), np.zeros(), np.full() where size comes from array dimensions
     (height*width, H*W, nrows*ncols) without a configurable max or memory check
   - CuPy equivalents (cp.empty, cp.zeros)
   - Queue/heap arrays sized at height*width without bounds validation
   Severity: HIGH if no memory guard exists; MEDIUM if a partial guard exists

   **Cat 2 — Integer Overflow in Index Math**
   - height*width multiplication in int32 (overflows silently at ~46340x46340)
   - Flat index calculations (r*width + c) in numba JIT without overflow check
   - Queue index variables in int32 that could overflow for large arrays
   Severity: HIGH for int32 overflow in production paths; MEDIUM for int64
   overflow only possible with unrealistic dimensions (>3 billion pixels)

   **Cat 3 — NaN/Inf as Logic Errors**
   - Division without zero-check in numba kernels
   - log/sqrt of potentially negative values without guard
   - Accumulation loops that could hit Inf (summing many large values)
   - Missing NaN propagation: NaN input silently produces finite output
   - Incorrect NaN check: using == instead of != for NaN detection in numba
   Severity: HIGH if in flood routing, erosion, viewshed, or cost_distance
   (safety-critical modules); MEDIUM otherwise

   **Cat 4 — GPU Kernel Bounds Safety**
   - CUDA kernels missing `if i >= H or j >= W: return` bounds guard
   - cuda.shared.array with fixed size that could overflow with adversarial
     input parameters
   - Missing cuda.syncthreads() after shared memory writes before reads
   - Thread block dimensions that could cause register spill or launch failure
   Severity: CRITICAL if bounds guard is missing (out-of-bounds GPU write);
   HIGH for shared memory overflow or missing syncthreads

   **Cat 5 — File Path Injection**
   - File paths constructed from user strings without os.path.realpath() or
     os.path.abspath() canonicalization
   - Path traversal via ../ not prevented
   - Temporary file creation in user-controlled directories
   Severity: CRITICAL if user-provided path is used without any
   canonicalization; HIGH if partial canonicalization is bypassable

   **Cat 6 — Dtype Confusion**
   - Public API functions that do NOT call _validate_raster() on their inputs
   - Numba kernels that assume float64 but could receive float32 or int arrays
   - Operations where dtype mismatch causes silent wrong results (not an error)
   - CuPy/NumPy backend inconsistency in dtype handling
   Severity: HIGH if wrong results are silent; MEDIUM if an error occurs but
   the error message is misleading

3. For each real issue found, assign a severity (CRITICAL/HIGH/MEDIUM/LOW)
   per the rubric in _sweep-common.md and note the exact file and line
   number. Apply the repro gate: CRITICAL/HIGH findings on CPU-runnable
   paths (Cat 1-3, 5, 6) need a runnable reproduction executed on this
   host — e.g. the crafted input that triggers the overflow, traversal, or
   silent wrong result. GPU-only findings without CUDA stay static; mark
   them `unverified-static`.

4. If any CRITICAL, HIGH, or MEDIUM issue is found, run /rockout to fix it
   end-to-end (GitHub issue, worktree branch, fix, tests, and PR).
   For LOW issues, document them but do not fix. Skip /rockout entirely if
   the parent sweep was run with --no-fix; record findings in the state
   notes instead.

5. After finishing (whether you found issues or not), update
   .claude/sweep-security-state.csv following the state-CSV contract in
   .claude/commands/_sweep-common.md (csv.DictReader/DictWriter pattern,
   one line per record). Header:

   `module,last_inspected,issue,severity_max,categories_found,followup_issues,notes`

   Then `git add` and commit it to the worktree branch so the state update
   is included in the PR.

Additional security-specific rules:
- Only flag real, exploitable issues.
- For CUDA code, verify bounds guards are truly missing -- many kernels
  already have `if i >= H or j >= W: return`.

{agent contract from _sweep-common.md, verbatim}
```

### 5c. Print a status line

After dispatching, print:

```
Launched {N} security audit agents: {module1}, {module2}, {module3}
```

## Step 6 -- State updates

State is updated by the subagents themselves (see agent prompt step 5).
To reset all tracking: `/sweep-security --reset-state`
