# Style Sweep: Dispatch subagents to audit modules for PEP8 and coding-style issues

Audit xrspatial modules for Python style issues that the project's own
tooling already knows how to detect: PEP8 violations (flake8 E/W codes),
unused imports and dead locals (flake8 F codes), import-ordering drift
(isort), and bug-prone style anti-patterns (bare except, mutable defaults,
shadowed builtins). The project configures flake8 (`max-line-length=100`)
and isort (`line_length=100`) in `setup.cfg` but does not gate them in CI,
so drift is invisible. Subagents fix HIGH and MEDIUM findings via rockout;
LOW findings are recorded but not auto-fixed to avoid nitpick PRs.

Optional arguments: {{ARGUMENTS}}
(e.g. `--top 3`, `--exclude slope,aspect`, `--only-terrain`, `--reset-state`,
`--no-fix`)

**Read `.kilo/command/_sweep-common.md` first.** It defines module
discovery, the standard flag set, module groups, the CUDA probe, the
state-CSV contract, the severity rubric, the repro gate, and the agent
contract. This file adds only what is specific to the style sweep. Two
common sections do NOT apply here: skip the CUDA probe (style is static and
applies uniformly across backend paths), and the repro gate is satisfied by
flake8/isort output itself — no separate reproduction script is needed.

---

## Step 0 -- Parse arguments

Parse the standard flags per _sweep-common.md (no extra flags for this
sweep). No CUDA probe.

## Step 1 -- Discover modules and gather metadata

Discover modules per _sweep-common.md. Collect the common metadata fields
(last_modified, total_commits, loc, public_funcs) plus:

| Field | How |
|-------|-----|
| **flake8_baseline** | `flake8 <module_files> 2>&1 \| wc -l` — observed lint count using the existing `setup.cfg` `[flake8]` config |

## Step 2 -- Load inspection state

Read `.kilo/worktrees/sweep-style-state.csv` per the state-CSV contract in
_sweep-common.md. Schema (one row per module):

```
module,last_inspected,issue,severity_max,categories_found,notes
slope,2026-05-01,1042,MEDIUM,1;4,"optional single-line notes"
```

## Step 3 -- Score each module

```
days_since_inspected = (today - last_inspected).days   # 9999 if never
days_since_modified  = (today - last_modified).days

score = (days_since_inspected * 3)
      + (flake8_baseline * 25)
      + (loc * 0.05)
      + (total_commits * 0.2)
      - (days_since_modified * 0.1)
```

Rationale:
- Never-inspected modules dominate (9999 * 3)
- `flake8_baseline` is the measured truth — observed lint count, not a
  proxy. A module with 40 existing violations should outrank a clean
  module of similar size.
- Larger files have more surface area (0.05 per line)
- Churn correlates with style drift across many small commits (0.2)
- Recently modified modules slightly deprioritized to avoid stomping on
  in-flight work

## Step 4 -- Apply filters from {{ARGUMENTS}}

Apply the standard flags (`--top N` default 3, `--exclude`, `--only-<group>`,
`--high-only`, `--reset-state`, `--include-experimental`) per
_sweep-common.md.

## Step 5 -- Print the ranked table and launch subagents

### 5a. Print the ranked table

Print a markdown table showing ALL scored modules (not just selected ones),
sorted by score descending:

```
| Rank | Module          | Score  | Last Inspected | flake8 | LOC  | Commits |
|------|-----------------|--------|----------------|--------|------|---------|
| 1    | geotiff         | 31050  | never          | 42     | 1400 | 85      |
| 2    | hydro           | 30900  | never          | 28     | 8200 | 64      |
| ...  | ...             | ...    | ...            | ...    | ...  | ...     |
```

### 5b. Launch subagents for the top N modules

Launch one Agent per selected module per the dispatch rules in
_sweep-common.md (single message, `isolation: "worktree"`, `mode: "auto"`).

Each agent's prompt must be self-contained and follow this template (adapt
the module name, paths, and metadata):

```
You are auditing the xrspatial module "{module}" for Python style issues.

This module has {commits} commits, {loc} lines of code, and an observed
flake8 baseline of {flake8_baseline} violations.

Read these files: {module_files}

Also read setup.cfg to confirm the project's flake8 and isort config
(max-line-length=100, line_length=100, exclude .git/.asv/__pycache__).

**Your task:**

1. Run the project's own style tooling against the module files:

   ```
   flake8 {module_files}
   isort --check-only --diff {module_files}
   ```

   These tools are authoritative — every issue they report is in scope.

2. Classify each reported issue into one of these 5 categories. Only flag
   issues ACTUALLY reported by the tools or grep — do not invent style
   nitpicks the linters do not flag.

   **Cat 1 — flake8 E-codes (PEP8 errors)**
   - E1xx indentation, E2xx whitespace, E3xx blank lines, E5xx line length,
     E7xx statement-level (e.g. E711 comparison to None, E712 to True/False,
     E721 type comparison, E741 ambiguous name)
   Severity: MEDIUM (real PEP8 violations against the configured style)

   **Cat 2 — flake8 W-codes (PEP8 warnings)**
   - W191 indentation contains tabs, W291/W293 trailing whitespace, W391
     blank line at end of file, W605 invalid escape sequence
   Severity: LOW unless W605 (invalid escape — can mask intent), in which
   case bump to MEDIUM and add to Cat 5 as well

   **Cat 3 — flake8 F-codes (pyflakes: bug-masking lint)**
   - F401 unused import, F811 redefinition of unused name, F821 undefined
     name, F841 local assigned but unused, F823 local used before assignment
   Severity: HIGH — these frequently hide refactor leftovers and real
   bugs (F821 is always HIGH; F401 on a module shipped to users can mean
   a removed re-export)

   **Cat 4 — Import ordering (isort)**
   - Any diff produced by `isort --check-only --diff` against the
     configured `line_length=100`
   Severity: MEDIUM

   **Cat 5 — Bug-prone style anti-patterns**
   Grep for and review:
   - Bare `except:` (without an exception type) — `grep -nE '^\s*except\s*:' <files>`
   - Mutable default args — `grep -nE 'def [^(]+\([^)]*=\s*(\[|\{)' <files>`
   - `== None`, `!= None`, `== True`, `== False` — already caught by flake8
     E711/E712 but list separately here so the rockout PR addresses them
     together as a behavioural class
   - Shadowing builtins as variable or parameter names: `list`, `dict`,
     `set`, `id`, `type`, `input`, `filter`, `map`, `next`, `iter`
   Severity: HIGH — these are the only style findings that change runtime
   behaviour (bare except swallows KeyboardInterrupt; mutable defaults
   are shared across calls; shadowed builtins corrupt the namespace).

3. For each real issue found, assign a severity (HIGH/MEDIUM/LOW) and note
   the exact file and line number. Group same-category issues into a single
   finding when they're trivially related (e.g. 12 trailing-whitespace
   lines = one Cat 2 finding, not twelve). The tool output IS the evidence
   — no separate reproduction script is required for this sweep.

4. If any HIGH or MEDIUM issue is found, run rockout to fix it end-to-end
   (GitHub issue, worktree branch, fix, tests, and PR). One rockout per
   module — the PR should bundle all HIGH+MEDIUM findings for that module
   into a single coherent style cleanup. Skip rockout entirely if the
   parent sweep was run with --no-fix; record findings in the state notes
   instead.

   For LOW findings (W-codes, single-line E501 on a long URL, cosmetic
   E2xx that don't reduce readability), document them in the state CSV
   notes column but do NOT open a PR. Per-line nitpick PRs are net
   negative.

   The rockout PR description should:
   - List which categories were addressed (e.g. "Cat 3 (F401, F841), Cat 4
     (isort), Cat 5 (bare except)")
   - Confirm no behavioural change is intended for Cat 1/2/4 fixes
   - Call out any Cat 3/5 fix that does change behaviour (e.g. removing
     an unused import that was actually re-exporting a symbol)

5. After finishing (whether you found issues or not), update
   `.kilo/worktrees/sweep-style-state.csv` following the state-CSV contract in
   .kilo/command/_sweep-common.md (csv.DictReader/DictWriter pattern
   with the `_oneline` sanitizer, one line per record). Header:

   `module,last_inspected,issue,severity_max,categories_found,notes`

   Then `git add` and commit it to the worktree branch so the state update
   is included in the PR.

Additional style-specific rules:
- Only flag issues the tools actually report (flake8, isort) or that grep
  confirms for Cat 5. Style is subjective; the project has already drawn
  the line at the configured `setup.cfg` settings. The sweep's job is
  enforcement, not policy.
- Do NOT run black, ruff format, autopep8, or any other auto-formatter.
  The project has not adopted a formatter and choosing one is a policy
  decision, not a sweep finding. Limit fixes to what flake8 + isort + the
  Cat 5 grep flag.
- Do NOT widen the flake8 config to silence findings. If a finding is a
  false positive (e.g. E501 on a URL where wrapping hurts readability),
  add a per-line `# noqa: E501` rather than changing the global config.
- For the hydro subpackage: run flake8 + isort across all `.py` files in
  the subpackage and treat them as one audit unit. Issues in dinf/mfd
  variants that mirror d8 should be fixed together in the same rockout PR.
- Style fixes are static and apply uniformly across backend paths — no
  separate backend verification is needed (unlike security or accuracy
  sweeps).

{agent contract from _sweep-common.md, verbatim — its repro-gate line is
satisfied by the linter output for this sweep}
```

### 5c. Print a status line

After dispatching, print:

```
Launched {N} style audit agents: {module1}, {module2}, {module3}
```

## Step 6 -- State updates

State is updated by the subagents themselves (see agent prompt step 5).
To reset all tracking: `sweep-style --reset-state`
