# API Consistency Sweep: Dispatch subagents to audit parameter naming and signature drift

Audit xrspatial modules for API consistency issues across analogous public
functions: parameter naming drift (`cellsize` vs `cell_size` vs `res`,
`agg` vs `raster` vs `data`), inconsistent return-type shapes, missing or
mismatched type hints, docstring/signature divergence. Cheap to find; makes
the library feel polished and predictable. Subagents fix CRITICAL, HIGH,
and MEDIUM findings via /rockout — but flag deprecation impact in the
issue since renames are breaking changes.

Optional arguments: $ARGUMENTS
(e.g. `--top 3`, `--exclude slope,aspect`, `--only-terrain`, `--reset-state`,
`--no-fix`)

**Read `.codex/commands/_sweep-common.md` first.** It defines module
discovery, the standard flag set, module groups, the CUDA probe, the
state-CSV contract, the severity rubric, the repro gate, and the agent
contract. This file adds only what is specific to the API-consistency sweep.

---

## Step 0 -- Parse arguments and probe CUDA

Parse the standard flags per _sweep-common.md (no extra flags for this
sweep). Run the CUDA availability probe and capture `CUDA_AVAILABLE`.

## Step 1 -- Discover modules, gather metadata, build the parameter inventory

Discover modules per _sweep-common.md. Collect the common metadata fields
(last_modified, total_commits, loc, public_funcs).

Then build a library-wide parameter inventory ONCE in the parent, so every
agent compares against the whole library instead of 2-3 anecdotal siblings:

```python
import ast, glob

rows = []
for path in glob.glob("xrspatial/**/*.py", recursive=True):
    if "/tests/" in path or "__pycache__" in path:
        continue
    try:
        tree = ast.parse(open(path).read())
    except SyntaxError:
        continue
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and not node.name.startswith("_"):
            args = node.args
            defaults = [None] * (len(args.args) - len(args.defaults)) + list(args.defaults)
            for a, d in zip(args.args, defaults):
                rows.append((path, node.name, a.arg,
                             ast.unparse(a.annotation) if a.annotation else "",
                             ast.unparse(d) if d is not None else ""))
for r in rows:
    print(",".join(r))
```

Hold the output in memory (or the scratchpad) and paste the relevant slice —
all rows whose parameter name or concept matches the audited module's
parameters — into each agent prompt as `{param_inventory}`.

## Step 2 -- Load inspection state

Read `.codex/sweep-api-consistency-state.csv` per the state-CSV contract
in _sweep-common.md. Schema (one row per module):

```
module,last_inspected,issue,severity_max,categories_found,notes
slope,2026-05-01,1042,HIGH,1;3,"optional single-line notes"
```

## Step 3 -- Score each module

```
days_since_inspected = (today - last_inspected).days   # 9999 if never
days_since_modified  = (today - last_modified).days

score = (days_since_inspected * 3)
      + (public_funcs * 8)
      + (total_commits * 0.3)
      - (days_since_modified * 0.1)
      + (loc * 0.03)
```

Rationale:
- Public function count weighted heavily — consistency issues are
  cross-function comparisons, so more functions = more comparison surface
- Modules never inspected dominate
- Recently modified slightly deprioritized

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

Each agent's prompt must be self-contained:

```
You are auditing the xrspatial module "{module}" for API consistency issues.

This module has {commits} commits and {loc} lines of code.

Read these files: {module_files}

Also read xrspatial/__init__.py to see what is publicly re-exported, and
xrspatial/utils.py for shared helpers.

Library-wide parameter inventory (path, function, param, annotation,
default) for every parameter name/concept this module uses — this is your
comparison baseline, so drift findings are global, not anecdotal:

{param_inventory}

For return-shape and semantics comparisons, also read 2-3 sibling modules
with analogous functions (e.g. for aspect: slope.py and curvature.py; for
erosion: morphology.py; for glcm: focal.py and convolution.py).

CUDA available on this host: {cuda_available}

If CUDA_AVAILABLE is true:
- When checking signature parity, also import the cupy backend variants
  and confirm they accept the same kwargs. Run a quick smoke test on a
  cupy DataArray for each public function so signature drift between
  numpy and cupy paths surfaces.

If CUDA_AVAILABLE is false:
- Inspect the cupy backend signatures by reading the source only.
- Add the token `cuda-unavailable` to the `notes` column of the state CSV.

**Your task:**

1. Read all listed files thoroughly. For each public function, build a
   small mental table of (function name, signature, return type).

2. Audit for these 5 API-consistency categories. Only flag issues ACTUALLY
   present.

   **Cat 1 — Parameter naming drift**
   - HIGH: same concept named differently across analogous public
     functions in this module or elsewhere in the inventory. Common
     offenders:
     `cellsize` vs `cell_size` vs `res` vs `resolution`
     `agg` vs `raster` vs `data` vs `array`
     `x` vs `xs` vs `x_coords`
     `nodata` vs `_FillValue` vs `nodata_value`
     `cmap` vs `color_map` vs `colormap`
     `kernel` vs `weights` vs `mask`
   - MEDIUM: same concept named consistently inside this module but
     different from sibling modules
   - MEDIUM: positional-vs-keyword convention drift (sibling functions
     accept the same arg, one as positional, one as keyword-only)
   Severity: HIGH if both names exist in the public API at the same time
   (real user-facing inconsistency); MEDIUM otherwise

   **Cat 2 — Return shape drift**
   - HIGH: analogous functions return different types (one returns
     DataArray, sibling returns Dataset for the same conceptual op)
   - HIGH: tuple-return vs single-return drift (one function returns
     `(slope, aspect)`, analog returns `slope` only — caller cannot
     interchange)
   - MEDIUM: result coord/attr conventions differ (one function emits
     `attrs['units']`, sibling does not)
   - MEDIUM: in-place vs returned-copy semantics drift
   Severity: HIGH if it breaks substitutability between sibling functions

   **Cat 3 — Type hints and docstrings**
   - MEDIUM: missing type hints on a public function while sibling
     functions in this module have them
   - MEDIUM: type hint says `xr.DataArray` but the docstring example
     passes a numpy array (or vice versa) — docs/types disagree
   - MEDIUM: docstring lists a parameter that does not exist in the
     signature (or omits one that does)
   - MEDIUM: docstring says "Returns: DataArray" but the function returns
     a tuple
   - LOW: docstring style drift (numpy-style vs google-style mix)
   Severity: MEDIUM (these are documentation bugs that mislead users)

   **Cat 4 — Default value inconsistency**
   - HIGH: same parameter has different defaults in analogous functions
     (e.g. `kernel_size=3` in one function, `kernel_size=5` in sibling,
     no documented reason) — check against the inventory's default column
   - MEDIUM: default uses a mutable type (`def f(x=[])`) — Python anti-pattern
   - MEDIUM: default `None` plus internal substitution where a literal
     default would be clearer and equally correct
   Severity: HIGH if user-surprise is likely (silent behavior change
   when switching between sibling functions)

   **Cat 5 — Public API surface drift**
   - HIGH: function is called by tests and notebooks but is not in
     `xrspatial/__init__.py` or in the module's `__all__` (orphan API)
   - HIGH: function in `__all__` but undocumented in the docstring
   - MEDIUM: deprecated alias still exported with no `DeprecationWarning`
   - MEDIUM: private-looking name (`_foo`) but is referenced in tests as
     if public
   - LOW: `from .module import *` patterns that bring inconsistent
     symbols into the public namespace
   Severity: HIGH for orphan APIs (users find them, depend on them, then
   break when they vanish)

3. For each real issue, assign severity per the rubric in _sweep-common.md
   plus file:line. Apply the repro gate: for CRITICAL/HIGH findings, the
   reproduction is a short script demonstrating the user-facing surprise
   (e.g. the same call pattern working on one sibling and TypeError-ing on
   another), executed on this host.

4. If any CRITICAL, HIGH, or MEDIUM issue is found, run /rockout to fix it.
   IMPORTANT: parameter renames are breaking changes — for HIGH
   parameter-rename fixes, the rockout PR must add a deprecation
   shim (accept both old and new names; emit DeprecationWarning on the
   old name; update docs). Document this in the issue body. For LOW
   issues, document but do not fix. Skip /rockout entirely if the parent
   sweep was run with --no-fix; record findings in the state notes instead.

5. After finishing (whether you found issues or not), update
   .codex/sweep-api-consistency-state.csv following the state-CSV
   contract in .codex/commands/_sweep-common.md (csv.DictReader/DictWriter
   pattern, one line per record). Header:

   `module,last_inspected,issue,severity_max,categories_found,notes`

   Then `git add` and commit.

Additional API-consistency-specific rules:
- The lib has 40+ modules — do not list every minor naming difference;
  focus on user-facing surprise.
- Cross-cutting concerns (e.g. the cellsize naming convention) often span
  the whole library; if a rename is safe in one module but the inventory
  shows it breaks 20 others, surface that as a notes comment, do not file
  a per-module issue.
- Renames are breaking. The fix path is a deprecation shim, not a hard
  rename, unless the function has a clearly orphan/private status.

{agent contract from _sweep-common.md, verbatim}
```

### 5c. Print a status line

After dispatching, print:

```
Launched {N} API consistency audit agents: {module1}, {module2}, {module3}
```

## Step 6 -- State updates

State is updated by the subagents themselves (see agent prompt step 5).
To reset all tracking: `/sweep-api-consistency --reset-state`
