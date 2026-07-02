# Reference Validation Sweep: Dispatch subagents to validate algorithms against reference implementations

Validate xrspatial algorithms against independent reference implementations
— `gdaldem` for terrain, `scipy.ndimage` for focal/convolution/morphology,
`richdem` / WhiteboxTools for curvature and hydrology — on shared synthetic
inputs. This is the strongest correctness signal a spatial algorithm
library can have: not "the backends agree with each other" but "the
algorithm agrees with the tools the GIS community already trusts."
Divergence findings become accuracy issues via /rockout; parity findings
become golden-value regression tests so the parity cannot silently break.

Optional arguments: $ARGUMENTS
(e.g. `--top 3`, `--exclude slope,aspect`, `--only-terrain`, `--reset-state`,
`--no-fix`)

**Read `.claude/commands/_sweep-common.md` first.** It defines module
discovery, the standard flag set, module groups, the CUDA probe, the
state-CSV contract, the severity rubric, the repro gate, and the agent
contract. This file adds only what is specific to the reference-validation
sweep.

---

## Step 0 -- Parse arguments, probe CUDA, and probe reference tools

Parse the standard flags per _sweep-common.md. Run the CUDA availability
probe. Then probe once for each reference tool:

```bash
python -c "from osgeo import gdal; print(gdal.__version__)" 2>/dev/null || gdaldem --version 2>/dev/null
python -c "import scipy.ndimage; print(scipy.__version__)" 2>/dev/null
python -c "import richdem; print(richdem.__version__)" 2>/dev/null
python -c "import whitebox; print('ok')" 2>/dev/null
```

Capture `GDAL_AVAILABLE`, `SCIPY_AVAILABLE`, `RICHDEM_AVAILABLE`,
`WBT_AVAILABLE` and interpolate them into each subagent prompt. A module
whose every reference tool is missing scores 0 for `has_reference` below
and is effectively skipped this run.

## Step 1 -- Discover modules and gather metadata

Discover modules per _sweep-common.md. Collect the common metadata fields
(last_modified, total_commits, loc) plus:

| Field | How |
|-------|-----|
| **has_reference** | 1 if the module appears in the reference map below AND at least one of its reference tools is available on this host, else 0 |
| **has_golden_test** | grep the module's test file for `golden`, `gdal`, `reference`, `scipy.ndimage` — 1 if a reference/golden comparison already exists |

Reference map (module → reference implementations):

| Module | Reference |
|--------|-----------|
| slope, aspect, hillshade | gdaldem slope / aspect / hillshade |
| terrain_metrics | gdaldem roughness / TRI / TPI |
| curvature | richdem curvature |
| focal, convolution | scipy.ndimage (generic_filter, convolve) |
| morphology | scipy.ndimage (grey_erosion, grey_dilation, binary ops) |
| edge_detection | scipy.ndimage (sobel, laplace) |
| bilateral | scipy / skimage bilateral where available |
| hydro (subpackage) | richdem / WhiteboxTools flow accumulation and direction |
| proximity | scipy.ndimage.distance_transform_edt (for euclidean mode) |
| zonal | scipy.ndimage.labeled_comprehension |
| reproject | rioxarray / GDAL warp |

Modules not in the map (perlin, worley, viewshed, glcm, ...) have no
practical reference here; they stay in the ranked table with
`has_reference = 0` so the table shows what this sweep cannot cover.

## Step 2 -- Load inspection state

Read `.claude/sweep-reference-validation-state.csv` per the state-CSV
contract in _sweep-common.md. Schema (one row per module):

```
module,last_inspected,issue,severity_max,verdict,tolerance,notes
slope,2026-07-01,1601,HIGH,DIVERGES,1e-6,"gdal 3.8; Horn stencil; edge rows differ"
```

- `verdict` is one of `MATCHES` (within tolerance), `DIVERGES`,
  `CONVENTION-DIFF` (delta fully explained by a documented convention
  difference), `NO-REFERENCE`, or empty.
- `tolerance` records the comparison tolerance used (e.g. `1e-6 rel`).

## Step 3 -- Score each module

```
days_since_inspected = (today - last_inspected).days   # 9999 if never
days_since_modified  = (today - last_modified).days

score = (days_since_inspected * 3)
      + (has_reference * 2000)
      + ((1 - has_golden_test) * 300)
      + (total_commits * 0.3)
      - (days_since_modified * 0.1)
      + (loc * 0.03)
```

Rationale:
- No point dispatching an agent at a module with no runnable reference
  (has_reference dominates everything except never-inspected staleness)
- Modules that already have a golden test are deprioritized — the parity
  is already pinned
- Churn slightly raises priority: a heavily-edited algorithm is the one
  most likely to have drifted from its reference

## Step 4 -- Apply filters from $ARGUMENTS

Apply the standard flags (`--top N` default 3, `--exclude`, `--only-<group>`,
`--high-only`, `--reset-state`, `--include-experimental`) per
_sweep-common.md. Drop `has_reference = 0` modules from selection (they
still appear in the table).

## Step 5 -- Print the ranked table and launch subagents

### 5a. Print the ranked table

Print a markdown table showing ALL scored modules sorted by score
descending, with columns Rank, Module, Score, Last Inspected, Reference,
Golden Test, Verdict (from state), LOC.

### 5b. Launch subagents for the top N modules

Launch one Agent per selected module per the dispatch rules in
_sweep-common.md (single message, `isolation: "worktree"`, `mode: "auto"`).

Each agent's prompt must be self-contained:

```
You are validating the xrspatial module "{module}" against reference
implementations: {reference_list}.

Read these files: {module_files}
Also read the matching test file(s) under xrspatial/tests/ and
xrspatial/tests/general_checks.py.

Reference tool availability on this host:
GDAL: {gdal_available}, scipy: {scipy_available},
richdem: {richdem_available}, WhiteboxTools: {wbt_available}
Skip any comparison whose tool is unavailable and add the token
`<tool>-unavailable` (e.g. `gdal-unavailable`) to the state notes.

CUDA available on this host: {cuda_available}. Run reference comparisons
against the numpy backend; if CUDA is available, also confirm the cupy
result matches the numpy result on the same inputs (backend parity is a
prerequisite for reference parity).

**Your task:**

1. Read the module and identify, from docstrings and References sections,
   which published algorithm it claims to implement (e.g. Horn 1981 slope,
   Zevenbergen-Thorne curvature). The claimed algorithm decides which
   reference mode to compare against (e.g. `gdaldem slope` defaults to
   Horn; `-alg ZevenbergenThorne` selects the other).

2. Build 3 synthetic test inputs as GeoTIFF + DataArray pairs so both
   xrspatial and the reference tool read identical data:
   - a 64x64 Gaussian hill with realistic projected cellsize (e.g. 30 m)
   - a tilted plane (analytically known slope/aspect everywhere)
   - a rough surface (seeded random walk) to exercise general terrain
   Write them to the session scratchpad with rioxarray or GDAL. Where the
   function has an analytic ground truth (the tilted plane), compare
   against the ANALYTIC value too — a case where xrspatial and the
   reference agree with each other but not with the math is two bugs, not
   zero.

3. Run xrspatial and each available reference implementation on the same
   inputs. Compare interior pixels first (edge/boundary conventions
   legitimately differ across tools), then edges separately. Choose and
   record an explicit tolerance (start at rtol=1e-6 for float64 paths;
   loosen only with a stated reason).

4. Classify the outcome:
   - MATCHES: within tolerance on interior pixels for the same documented
     algorithm.
   - CONVENTION-DIFF: delta fully explained by a documented convention
     difference (stencil choice, azimuth origin, edge padding, units).
     Verify the explanation quantitatively — apply the convention
     transform and confirm the residual drops within tolerance. If the
     convention is not stated in the xrspatial docstring, that is a
     MEDIUM documentation finding.
   - DIVERGES: unexplained numerical disagreement. Severity per the
     rubric in _sweep-common.md: HIGH if realistic inputs diverge beyond
     tolerance (users get different answers than the GIS stack they came
     from); CRITICAL if the analytic ground truth shows xrspatial is the
     wrong one on a public API.

5. Findings and fixes:
   - DIVERGES: run /rockout to file and fix an accuracy issue. The repro
     gate is inherently satisfied — your comparison script IS the
     reproduction; include it and the observed deltas in the issue body.
     If root-causing shows the reference tool is the wrong one, document
     that with the analytic evidence and file a MEDIUM doc issue to state
     the difference instead.
   - MATCHES with no existing golden test: run /rockout to ADD a
     golden-value regression test that pins the parity (small input,
     hardcoded expected values generated from the verified comparison,
     with a comment naming the reference tool + version). Test-only PR;
     no source changes.
   - CONVENTION-DIFF with undocumented convention: /rockout a doc-only
     fix stating the convention and the matching reference flags.
   Skip /rockout entirely if the parent sweep was run with --no-fix;
   record findings in the state notes instead.

6. After finishing, update .claude/sweep-reference-validation-state.csv
   following the state-CSV contract in .claude/commands/_sweep-common.md.
   Header:

   `module,last_inspected,issue,severity_max,verdict,tolerance,notes`

   Record the reference tool versions in notes. Then `git add` and commit.

Additional reference-validation rules:
- Never install reference tools yourself; use what the host has and note
  what is missing.
- Compare like with like: same nodata handling, same dtype, same cellsize
  units. A comparison harness bug is not a finding.
- One comparison script per module, kept in the scratchpad; paste it into
  any issue you file so the finding is reproducible by a human.

{agent contract from _sweep-common.md, verbatim}
```

### 5c. Print a status line

After dispatching, print:

```
Launched {N} reference validation agents: {module1}, {module2}, {module3}
```

## Step 6 -- State updates

State is updated by the subagents themselves (see agent prompt step 6).
To reset all tracking: `/sweep-reference-validation --reset-state`
