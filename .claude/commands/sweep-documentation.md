# Documentation Sweep: Dispatch subagents to audit modules for documentation coverage and quality

Audit xrspatial modules for documentation gaps and quality issues: missing or
incomplete docstrings, docstring/signature drift, broken or outdated runnable
examples, public functions absent from the API reference, and documentation
that misstates behavior (wrong dtype/shape or backend-support claims).
Subagents fix findings via /rockout.

Optional arguments: $ARGUMENTS
(e.g. `--top 3`, `--exclude slope,aspect`, `--only-terrain`, `--reset-state`,
`--no-fix`)

**Read `.claude/commands/_sweep-common.md` first.** It defines module
discovery, the standard flag set, module groups, the CUDA probe, the
state-CSV contract, the severity rubric, the repro gate, and the agent
contract. This file adds only what is specific to the documentation sweep.

---

## Step 0 -- Parse arguments and probe CUDA

Parse the standard flags per _sweep-common.md (no extra flags for this
sweep). Run the CUDA availability probe and capture `CUDA_AVAILABLE`. For
this sweep the flag decides whether docstring examples that reference cupy /
dask+cupy can actually be executed or must be reviewed statically.

## Step 1 -- Discover modules and gather metadata

Discover modules per _sweep-common.md. Collect the common metadata fields
(last_modified, total_commits, loc, public_funcs) plus:

| Field | How |
|-------|-----|
| **example_blocks** | `grep -c '>>>' <files>` (sum for subpackages) |
| **recent_docs_commits** | `git log --oneline --grep='doc\|docstring\|example\|docs' -- <path>` |

## Step 2 -- Load inspection state

Read `.claude/sweep-documentation-state.csv` per the state-CSV contract in
_sweep-common.md. Schema (one row per module):

```
module,last_inspected,issue,severity_max,categories_found,notes,doc_coverage
```

- `doc_coverage` is a short at-a-glance token like `12/14` (public functions
  fully documented / total public functions) or empty.

## Step 3 -- Score each module

```
days_since_inspected = (today - last_inspected).days   # 9999 if never
days_since_modified  = (today - last_modified).days
has_recent_docs_work = 1 if recent_docs_commits is non-empty, else 0
example_deficit      = max(0, public_funcs - example_blocks)  # public funcs lacking a paired example

score = (days_since_inspected * 3)
      + (public_funcs * 5)
      + (example_deficit * 30)
      + (total_commits * 0.3)
      - (days_since_modified * 0.1)
      - (has_recent_docs_work * 300)
      + (loc * 0.03)
```

Rationale:
- Modules never inspected dominate (9999 * 3)
- More public functions = more documentation surface to get right (5 per func)
- Public functions without a paired example are the strongest candidates
  (30 per deficit)
- Modules with recent documentation work heavily deprioritized (someone just
  documented them)
- Recently modified modules slightly deprioritized (someone just touched them)
- Larger files have a bit more surface area (0.03 per line)

## Step 4 -- Apply filters from $ARGUMENTS

Apply the standard flags (`--top N` default 3, `--exclude`, `--only-<group>`,
`--high-only`, `--reset-state`, `--include-experimental`) per
_sweep-common.md.

## Step 5 -- Print the ranked table and launch subagents

### 5a. Print the ranked table

Print a markdown table showing ALL scored modules (not just selected ones),
sorted by score descending:

```
| Rank | Module          | Score  | Last Inspected | Last Modified | Pub Funcs | Examples | LOC  |
|------|-----------------|--------|----------------|---------------|-----------|----------|------|
| 1    | multispectral   | 30180  | never          | 45 days ago   | 14        | 6        | 1200 |
| 2    | focal           | 29998  | never          | 120 days ago  | 9         | 3        | 800  |
| ...  | ...             | ...    | ...            | ...           | ...       | ...      | ...  |
```

### 5b. Launch subagents for the top N modules

Launch one Agent per selected module per the dispatch rules in
_sweep-common.md (single message, `isolation: "worktree"`, `mode: "auto"`).

Each agent's prompt must be self-contained and follow this template (adapt
the module name, paths, and metadata):

```
You are auditing the xrspatial module "{module}" for documentation coverage and
quality issues.

This module has {commits} commits, {loc} lines of code, {public_funcs} public
functions, and {example_blocks} docstring example blocks.

Read these files: {module_files}

Also read:
- xrspatial/__init__.py to determine exactly which functions in this module are
  public (exported there). Only public functions are in scope for required
  documentation.
- the matching API reference page(s) under docs/source/reference/*.rst for this
  module (the autosummary blocks that should list this module's public funcs).
- the existing docstring-validation tests, which codify the project's
  expectations and are the patterns to model your checks on:
  xrspatial/tests/test_multispectral.py::test_docstring_params_match_signature
  xrspatial/tests/test_proximity.py::test_docstring_states_all_backends
  xrspatial/tests/test_accessor.py::test_accessor_docstring_matches_source

The project uses NumPy-style (numpydoc) docstrings throughout: Parameters,
Returns, Notes, References, Examples sections. Examples use `.. sourcecode::
python` or `.. plot::` blocks with `>>>` lines.

**Measured truth first.** Before reading for style, gather observed
failures so Cat 2/3 findings start from evidence, not inspection:
- Run the three docstring-validation tests above; where one is
  parameterized over functions, run it and note which of THIS module's
  functions fail.
- Extract each `>>>` example block for this module's public functions and
  execute it (numpy/dask examples always; cupy examples only per the CUDA
  rules below). Capture tracebacks and stale-output mismatches.
These observed failures are your primary Cat 2/Cat 3 findings; anything
found only by reading gets a second look before flagging.

CUDA available on this host: {cuda_available}

If CUDA_AVAILABLE is true:
- When a docstring example references cupy or dask+cupy, actually run it to
  confirm it executes and produces sane output.
- Validate Category 3 findings by running the example rather than reasoning
  from source alone.

If CUDA_AVAILABLE is false:
- Review cupy / dask+cupy example blocks statically and flag patterns by
  inspection only. Skip executing them.
- Add the token `cuda-unavailable` to the `notes` column of the state CSV.

**Your task:**

1. Read all listed files thoroughly, including the matching test file(s) under
   xrspatial/tests/ so you understand the documented contract before flagging a
   docstring as wrong -- a test may already codify the current behavior.

2. Audit for these 5 documentation categories. For each, look for the specific
   patterns described. Only flag issues ACTUALLY present in the code.

   **Cat 1 — Missing / Incomplete Docstrings (presence & structure)**
   - A public function (exported in xrspatial/__init__.py) or the module itself
     has no docstring at all
   - A public API function's docstring is missing a required NumPy section
     (Parameters, Returns, or Examples)
   - A non-trivial public function has only a one-line stub docstring
   Severity: HIGH if a public function has no docstring; MEDIUM if a major
   section (Parameters/Returns/Examples) is absent; LOW for minor omissions on
   internal helpers

   **Cat 2 — Docstring / Signature Drift**
   - A parameter described in the docstring does not exist in the signature
   - A signature parameter is undocumented in the Parameters section
   - Parameter order in the docstring disagrees with the signature
   - A documented default value disagrees with the signature default
   - A documented type contradicts the type annotation
   (model the check on test_docstring_params_match_signature)
   Severity: HIGH if a documented parameter does not exist (actively misleads
   users); MEDIUM for default / type / ordering drift

   **Cat 3 — Broken or Outdated Runnable Examples**
   - An `>>>` example block (or `.. plot::` block) whose imports are wrong or
     missing
   - Example code that raises when executed
   - Example using a renamed or removed API (drifted from current code)
   - Example output that is clearly stale relative to current behavior
   Validate by executing the example (see "Measured truth first" above).
   Severity: HIGH if a public-facing example errors on copy-paste; MEDIUM if it
   runs but produces clearly stale / incorrect output

   **Cat 4 — API Reference Coverage Gaps (rst)**
   - A public function exported in xrspatial/__init__.py for this module is
     absent from every autosummary block under docs/source/reference/*.rst
   - A reference page lists a function that no longer exists or is no longer
     public (stale entry)
   - A function is duplicated across reference pages
   Severity: HIGH if a public function is reachable nowhere in the API
   reference; MEDIUM for a stale or duplicated entry

   **Cat 5 — Documentation Accuracy / Backend-Claim Drift**
   - The Returns description states a dtype or shape that contradicts what the
     code actually returns
   - The docstring claims CuPy / Dask / "all four backends" support that the
     code does not actually provide (or omits a backend it does support)
   - NaN / nodata semantics that the function implements are undocumented
   (model on test_docstring_states_all_backends)
   Severity: HIGH if a stated backend / dtype claim is wrong; MEDIUM if a real
   behavior is undocumented

3. For each real issue found, assign a severity (CRITICAL/HIGH/MEDIUM/LOW)
   per the rubric in _sweep-common.md and note the exact file and line
   number. Apply the repro gate: for CRITICAL/HIGH Cat 2/3/5 findings the
   reproduction is the executed example or check whose output shows the
   drift; paste it into the issue.

4. If any CRITICAL, HIGH, or MEDIUM issue is found, run /rockout to fix it
   end-to-end (GitHub issue, worktree branch, fix, and PR). For LOW issues,
   document them but do not fix. Skip /rockout entirely if the parent sweep
   was run with --no-fix; record findings in the state notes instead.

   DOC-ONLY CONSTRAINT: fixes edit docstrings, .rst reference pages, and
   examples ONLY -- never function behavior. If fixing a Category 3 example
   surfaces a genuine code bug (the documented behavior is correct but the code
   is wrong), do NOT change behavior to match the doc: file a separate accuracy
   issue and leave the example flagged.

5. After finishing (whether you found issues or not), update
   .claude/sweep-documentation-state.csv following the state-CSV contract in
   .claude/commands/_sweep-common.md (csv.DictReader/DictWriter pattern, one
   line per record). Header:

   `module,last_inspected,issue,severity_max,categories_found,notes,doc_coverage`

   Set `doc_coverage` to `<fully documented public funcs>/<total public funcs>`.
   Then `git add` and commit it to the worktree branch so the state update is
   included in the PR.

Additional documentation-specific rules:
- "Public" means exported in xrspatial/__init__.py. Internal helpers and
  private functions are not required to have full numpydoc docstrings; do not
  flag them under Cat 1/Cat 4.
- For backend-claim checks (Cat 5), verify the claim against the actual
  ArrayTypeFunctionMapping dispatch in the module, not against assumptions.
- A documented contract that the code violates is an accuracy bug; file it
  separately rather than editing the docstring to match buggy code.

{agent contract from _sweep-common.md, verbatim}
```

### 5c. Print a status line

After dispatching, print:

```
Launched {N} documentation audit agents: {module1}, {module2}, {module3}
```

## Step 6 -- State updates

State is updated by the subagents themselves (see agent prompt step 5).
To reset all tracking: `/sweep-documentation --reset-state`
