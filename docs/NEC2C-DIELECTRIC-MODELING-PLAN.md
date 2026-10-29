# NEC2C-N5HXR dielectric modeling and reporting plan

Status: **implementation plan aligned with the implemented NEC2C contract**

Authoritative solver interface:

- `~/homebrew/nec2c/docs/ANTENNA-TURTLE-INTEGRATION.md`
- `~/homebrew/nec2c/docs/nec2c-results-v1.schema.json`

The earlier companion proposal,
[NEC2C-N5HXR-DIELECTRIC-INTEGRATION-SPEC.md](NEC2C-N5HXR-DIELECTRIC-INTEGRATION-SPEC.md),
is retained as design history. Where it differs from the two solver documents
above, the implemented solver interface is authoritative.

Reference solver: `nec2c-n5hxr 1.3.1`, dielectric feature revision 1,
resource-format versions 1 through 3, and result-schema version 1.

## 1. Purpose and compatibility boundary

Add optional NEC2C-N5HXR cuboid dielectric volumes to Antenna Turtle while
preserving the ordinary NEC2 path. The first end-to-end use is a controlled
comparison between an existing wire antenna and the same antenna with a nearby
dielectric panel.

The implementation preserves these boundaries:

1. With no enabled dielectric volumes, a legacy executable and its current
   human-report parser continue to work unchanged.
2. Antenna Turtle owns turtle placement, material declarations, scenario
   selection, resource generation, result adaptation, and visualization.
3. NEC2C-N5HXR owns resource validation, meshing, ground compatibility,
   solving, physical output, and authoritative diagnostics.
4. OpenEMS solids and NEC2C dielectric volumes remain explicit backend
   representations. No object silently changes electromagnetic meaning when
   another backend is selected.

When an N5HXR executable is available, Antenna Turtle uses result-schema v1
for both classic and dielectric-active runs. This lets a reference/no-`DF`
case and a loaded case use the same executable and adapter. An ordinary NEC2C
binary continues to use the existing text path.

## 2. Revision-1 scope

Supported:

- global-axis-aligned cuboids placed through the turtle transform;
- scalar, isotropic, nonmagnetic materials with `ER >= 1`;
- lossless materials and constant conductivity;
- free space, PEC ground, and supported Sommerfeld-Norton ground cases;
- the dense reference solver initially, while preserving the N5HXR solver
  metadata and vocabulary for GMRES/FFT follow-on work;
- voltage-driven wire antennas;
- impedance, wire currents, patch currents, volume polarization currents,
  power accounting, complex far fields, and requested exterior near fields;
- per-run enabling/disabling of all declared dielectric volumes; and
- deterministic paired `.nec`/`.diel` export.

Deferred or rejected in revision 1:

- conductor/dielectric contact, penetration, or burial;
- arbitrary rotated cuboids and overlapping interiors;
- anisotropic, magnetic, nonlinear, or inferred environmental materials;
- frequency-table resource version 3;
- automatic FFT lattice design or silent solver fallback;
- converting general Manifold bodies to bounding boxes; and
- `LD`, `NT`, `TL`, or NEC symmetry in a dielectric-active job.

Unsupported combinations fail with an object name and actionable diagnostic;
they are never silently omitted or reinterpreted.

## 3. Geometry representation and public API

The solver consumes analytic axis-aligned boxes, so `cuboid` is a
backend-neutral primitive backed by a lightweight analytic registry. When
Manifold is available, the same declaration also creates the existing solid
body for OpenEMS and solid rendering. Without Manifold, it remains available
to NEC2C-N5HXR, `show-model`, and portable reports. This avoids recovering
original cuboids from Boolean mesh output.

Use the existing Manifold-independent `em-material` value:

```racket
(define wall-material
  (dielectric name wall
              er 3.2
              conductivity 0.012))
```

Place the ordinary cuboid at the current turtle pose:

```racket
(cuboid
 name nearby-wall
 size (list 0.35 0.08 0.60)
 material wall-material
 anchor center)
```

Public contextual grammar:

```racket
(cuboid
  name name-or-string
  size (list x-length y-length z-length)
  material em-material
  [anchor origin|center|bottom|top])
```

Lower-level API:

```racket
(add-model-cuboid
 name material size
 #:anchor [anchor 'center])
  -> model-cuboid?

(model-cuboids) -> (listof model-cuboid?)

(clear-model-cuboids) -> void?
```

`reset-model!` clears the registry through a reset hook. Each entry stores its
name, material, local dimensions, captured transform, and declaration order.
Negative or zero dimensions are errors. A dielectric cuboid participates in
both compatible backends by default. The run-level `#:dielectrics?` switch,
not a second geometry declaration, selects reference versus loaded NEC runs.

### 3.1 Transform and alignment rules

Translation, reflection, scale, and right-angle axis permutations are
accepted. An oblique cuboid remains valid for OpenEMS, but NEC2C-N5HXR export
rejects it because resource revision 1 requires global-axis-aligned boxes.
Alignment recognition uses a numerical tolerance,
but exported bounds are canonicalized from transformed endpoints so intended
shared faces receive byte-identical coordinates. The exporter does not snap
gaps or overlaps.

### 3.2 Material DSL availability

The `dielectric` material declaration and analytic `cuboid` form must be
provided without loading Manifold. Material syntax lives in a small
Manifold-free module. With solid support, `cuboid` records both the analytic
primitive and the existing Manifold body under one identity; in the minimal
language it records only the analytic primitive. Other OpenEMS bodies retain
their existing behavior.

## 4. Material and resource mapping

Revision 1 accepts dielectric `em-material` values with relative permeability
one and relative permittivity at least one. Emit deterministic resource
version 2 even for lossless materials:

| Antenna Turtle declaration | Version-2 resource mapping |
| --- | --- |
| ER, no loss | `MATERIAL id ER value` |
| ER plus conductivity | `MATERIAL id ER value SIGMA value` |
| narrowband loss tangent | convert to constant `SIGMA` at an explicit reference frequency |
| broadband/relaxation law | reject until version-3 table support |

Loss-tangent conversion uses
`sigma = 2*pi*f*epsilon0*ER*tan(delta)`. The manifest records the original
declaration, reference frequency, and converted conductivity and warns that a
sweep uses a narrowband approximation.

Mesh policy is run/model configuration:

```racket
(nec2c-dielectric-mesh
 max-kh 0.5
 max-cells 1000
 max-aspect 2.0)
```

Antenna Turtle checks types and conservative limits. The solver remains
authoritative for subdivision, active cells, memory estimates, clearances,
ground compatibility, and solver eligibility.

Runner keywords are reserved from the first release:

```racket
#:dielectrics? boolean              ; default #t when enabled volumes exist
#:dielectric-solver 'dense|'gmres|'fft
#:solver-tolerance (or/c #f positive-real)       ; #f preserves NEC2C's 1e-12
#:solver-iterations (or/c #f (integer-in 1 10000)) ; #f preserves NEC2C's 300
```

The initial default is `'dense`. No requested solver is changed or silently
replaced. Tolerance and iteration controls apply to the iterative `gmres` and
`fft` solvers. `#:dielectrics? #f` omits `DF` entirely and exercises the
classic solver path.

## 5. Deck/resource lifecycle

`export-nec2c` gains:

```racket
(export-nec2c path #:dielectrics? [enabled? #t])
```

With active volumes it emits `model.nec`, `model.diel`, and a deck-relative
`DF "model.diel"` card after `GE`. Material and region IDs follow canonical
model order while comments preserve user names. Without active volumes it
emits the traditional deck only.

Treat the deck as the commit point for the pair: write temporary files, rename
the resource first, and rename the deck last. A consumer can then never see a
new deck referring to an incomplete resource. Temporary-run filenames remain
short (`analysis.nec`, `analysis.diel`, `analysis.json`) for compatibility
with inherited NEC filename limits.

The existing base-deck decorator must discover `DF`, copy its resource beside
the staged deck, and rewrite the reference when necessary. Copying only the
`.nec` file is invalid. Hand-authored `DF` decks are accepted, but Antenna
Turtle rewrites resource content only when it owns the pair.

## 6. Capability negotiation and execution

Probe each executable identity once with `--capabilities-json`; cache by
resolved executable path and file identity/mtime so replacing the binary
invalidates the cache. Do not infer features from `-v` text.

Dielectric mode requires:

- `program = "nec2c-n5hxr"`;
- capability schema version 1;
- dielectric feature revision 1;
- dielectric resource version 2;
- result schema version 1;
- the selected solver and ground mode; and
- validation support when explicit preflight is requested.

A legacy executable remains valid for no-`DF` runs. Enabled volumes with a
legacy or incompatible executable fail before launch and list the missing
capability.

N5HXR runs use a fresh result path:

```text
nec2c --result-json analysis.json -ianalysis.nec -oanalysis.out
```

Success requires all three conditions from the producer contract:

1. process exit status zero;
2. parseable result-schema-v1 JSON; and
3. top-level `completion.status == "ok"`.

On failure, preserve `.nec`, `.diel`, `.out`, JSON, stdout, and stderr. If a
handled failure document exists, include its diagnostics in the Racket
exception. A missing or malformed failure document is itself reported without
hiding the process output.

Add an explicit preflight entry point using `--validate-only --result-json`.
The normal solve need not run preflight twice, because execution performs the
same validation. Preflight is useful for model editors, fixtures, and geometry
diagnosis and may succeed for a classic input without a feed.

## 7. Result-schema-v1 adapter

Create a dedicated decoder (recommended file:
`private/nec2c-result-json.rkt`) rather than extending the human-report parser.
It must:

- validate the schema and every structure/enum it consumes;
- ignore unknown unconsumed fields for forward compatibility;
- preserve producer metadata, diagnostics, validation information, and raw
  execution identity;
- distinguish absent, JSON `null`, empty array, failed execution, and omitted
  request;
- use each `rows-v1.columns` array to map values rather than assuming column
  positions;
- join mesh data by `(mesh_state_id, cell_id)` and ground data by
  `ground_state_id`;
- preserve execution and request order and repeated-frequency executions; and
- reject an unknown value of an enum that the client is actively consuming.

Do not merge physical arrays from failed executions. A requested RP/NE/NH
output appearing in `omitted_requests` is a completeness error for the
corresponding high-level operation, with the solver reason retained.

The adapter should expose immutable transparent values for producer metadata,
diagnostics, mesh states, ground states, executions, volume-current samples,
and coupled power, plus the decoded raw contract for auditability. Append
source-compatible automatic metadata fields to the current run/artifact
records, or introduce a companion record, so existing constructors and access
patterns do not need immediate rewrites. Artifact metadata must expose the
resource and machine-result paths.

The implementation should not depend on a particular driven near-field
`kind` spelling. The current producer emits excitation and field metadata
sufficient to identify the result; preserve `kind` and display it rather than
turning it into client control flow.

## 8. Adapting fields to existing results

Keep `nec2c-port-result`, `nec2c-pattern-grid`, and
`nec2c-pattern-sample` as the public comparison currency. For each successful
driven execution, adapt feeds and complex far fields from the machine result.

Using accepted power `Pacc`, free-space impedance `eta0`, and the producer's
range-normalized fields:

```text
G_theta = 2*pi*|r E_theta|^2 / (eta0*Pacc)
G_phi   = 2*pi*|r E_phi|^2   / (eta0*Pacc)
G_total = G_theta + G_phi
```

Store accepted-power-normalized gain in dBi as the canonical pattern value.
Retain both complex components so the current polarization code can derive
axial ratio, tilt, sense, and phase. A solver-convention fixture must verify
the mapping between theta/phi and the existing vertical/horizontal labels.

Also preserve enough information to derive without rerunning:

- directivity (normalize by radiated power);
- realized gain for a declared reference impedance, normally 50 ohms; and
- equal-source-voltage complex field comparisons.

Do not collapse lower-half-space flux, dielectric absorption, structure loss,
or network loss into one generic “loss” value. If the producer supplies a
relative power-balance defect above 0.003, surface the warning prominently.

## 9. Modeling and report output

### 9.1 Geometry

Render dielectric volumes directly from eight corners and six faces in:

- `show-model`;
- the portable NEC2 HTML report's 3-D view; and
- pattern scenes when model display is enabled.

Use translucent material-specific coloring and identify these as dielectric,
not PEC. The report records name, dimensions, global bounds, source material,
resource material/region IDs, enabled state, and mesh controls. This path must
work without Manifold; `show-solid-model` remains optional and is not the only
way to inspect the simulation geometry.

### 9.2 Solver provenance and diagnostics

Record producer identity, capability/schema versions, a client-computed
resource digest (the producer does not emit one),
mesh-state ID and realization frequency, ground-state ID, selected solver,
unknown count, convergence/residual metadata, power basis, all power terms,
balance defect, warnings, and errors. Preserve the exact job/execution/request
indices used for each displayed result.

### 9.3 Volume polarization currents

Join each current row to geometry by `(mesh_state_id, cell_id)`. Render solver
cells in the 3-D view with:

- phasor magnitude;
- instantaneous signed X/Y/Z component;
- optional vector glyphs; and
- phase animation using retained complex components.

Label the quantity as volume polarization-current density in A/m², distinct
from wire current in A and patch surface current density. Never join cells
across mesh states merely because their numeric `cell_id` matches.

### 9.4 Far and near fields

The comparison viewer defaults to accepted-power gain but offers directivity,
realized gain, and equal-voltage field views when their required basis exists.
For requested near-field planes, preserve rectangular/spherical coordinates,
component units, excitation metadata, and the producer's validity guarantees.
The solver rejects invalid clearance requests, so a successful response must
not invent zero-valued samples. The renderer may still mask known conductor or
dielectric interiors for presentation, but that mask is not solver data.

## 10. Quarter-wave comparison fixture

Use `projects/quarter.rkt` as the geometry source. Add a lossless ER=6 panel
measuring 100 × 100 × 15 mm, broad face toward the antenna, with its nearest
face 0.20 free-space wavelength from the feedpoint. Declare it once and toggle
it per run:

```racket
(define obstruction-material
  (dielectric name validation-panel er 6.0))

(from-here
  (move forward (+ (* 0.20 wavelength) 0.0075))
  (cuboid
   name nearby-panel
   size (list 0.015 0.100 0.100)
   material obstruction-material
   anchor center))

(define reference-pattern
  (nec2c-radiation-grid
   #:frequency 1296 #:theta-step 2 #:phi-step 2
   #:dielectrics? #f))

(define loaded-pattern
  (nec2c-radiation-grid
   #:frequency 1296 #:theta-step 2 #:phi-step 2
   #:dielectrics? #t
   #:dielectric-solver 'dense))
```

Use `max-cells 1000`; the expected 400–600 active cells (approximately
1,200–1,800 volume unknowns) should be large enough to perturb the pattern but
small enough for the dense reference solver. Choose the panel azimuth by
explicit preflight against the completed wire geometry. Keep this example out
of the default fast test suite; retain a smaller contract fixture for CI.

Start lossless to make accepted/radiated power and redistribution auditable.
After convergence and a mesh-refinement comparison, add a separate
`conductivity 0.01` S/m scenario to exercise absorption.

This is initially a regression and sensitivity fixture, not validation of the
dielectric formulation. The report must retain bounds, material provenance,
clearances, cell divisions, residual, power defect, and refinement settings.

## 11. Implementation map

### AT-D0: contract fixtures and decoder foundation

- Retain a small classic result-schema-v1 fixture, a dielectric fixture, a
  repeated-`FR`/mesh-state fixture, and a handled-failure fixture.
- Add tests for null versus empty sections, omitted requests, column
  reordering, unknown ignored fields, and unknown consumed enums.
- Test a live executable only when its capability probe succeeds; fixture tests
  remain runnable on machines with ordinary NEC2C or no NEC2C.

### AT-D1: model and export

- Add `private/material-dsl.rkt` if needed to make material declarations
  independent of Manifold.
- Add an analytic volume registry/DSL, reset behavior, transform validator,
  deterministic resource-v2 serializer, and pair-aware artifact staging.
- Update `private/export-nec2c.rkt`, the base-deck decorator, and public
  exports.
- Test exact touching, overlap, oblique orientation, invalid material,
  deterministic IDs, pair commit ordering, and disabled export.

### AT-D2: capability, execution, and adaptation

- Add cached capability discovery and explicit validation API.
- Add result-schema-v1 process handling to `private/nec2c.rkt` and decode in
  `private/nec2c-result-json.rkt`.
- Adapt classic and dielectric N5HXR results to existing port/pattern values;
  preserve the legacy executable path unchanged.
- Test triple-success enforcement, retained failure artifacts, execution
  identity, gain equations, polarization conventions, and power warnings.

### AT-D3: visualization and reporting

- Extend `private/view.rkt`/`show-model` with analytic dielectric boxes.
- Extend `private/nec2c-html-report.rkt` with dielectric geometry, metadata,
  solver diagnostics, normalization choices, and volume-current animation.
- Add the reference/loaded quarter-panel example and portable comparison
  report.
- Ensure all report-generation tests pass without Manifold installed.

### AT-D4: acceleration and richer materials

- Enable assembled GMRES and FFT selection once solver compatibility and
  failure diagnostics have dedicated fixtures.
- Add version-3 material tables.
- Add larger environmental cases, near-field comparisons, OpenEMS references,
  and mesh/material sensitivity reports.

## 12. Acceptance criteria

The first integrated milestone is complete when:

1. The legacy suite passes without N5HXR and traditional decks are unchanged.
2. A right-angle turtle-placed cuboid produces a deterministic version-2
   resource and portable relative `DF` reference.
3. Pair staging/decorating never separates a deck from its resource.
4. Capability negotiation and the process/JSON/completion triple-success rule
   are enforced, with complete retained failure artifacts.
5. Invalid overlap, orientation, material, clearance, ground, and solver
   combinations produce actionable diagnostics.
6. Classic and dielectric schema-v1 fixtures produce existing impedance and
   pattern objects with verified absolute gain and polarization conventions.
7. The quarter fixture runs reference and loaded cases without rebuilding its
   wire geometry and displays both using accepted-power gain by default.
8. `show-model` and the HTML report show dielectric geometry without requiring
   Manifold.
9. The report records sufficient geometry, material, mesh, ground, solver,
   convergence, power, and execution identity to audit the result.
10. Complex volume polarization-current density can be selected and
    phase-animated without rerunning.
11. A dielectric mesh refinement indicates whether the observed impedance and
    pattern changes are numerically stable.

## 13. Decisions now fixed

1. Public placement form: the existing `(cuboid ... material ...)`; dielectric
   cuboids automatically participate in both compatible backends.
2. The analytic cuboid registry is canonical; Manifold is an optional derived
   representation, not a modeling, export, or report dependency.
3. Constant ER/conductivity via deterministic resource version 2 first;
   version-3 tables later.
4. Dense reference solver first, with no silent fallback and accelerated
   solvers immediately afterward.
5. Accepted-power-normalized gain is the canonical comparison value; raw
   complex fields and other normalization bases are retained.
6. Result-schema v1 is mandatory for N5HXR integration; there is no
   transitional coupled-text parser.
7. Repeated frequencies remain distinct executions and mesh states; clients
   join by producer IDs rather than frequency value alone.
8. Successful plane-wave results may have `power: null`; null is not zero.
9. Handled failures should be consumed when present, but clients still handle
   absent/incomplete failure documents defensively.
10. Volume-current visualization is part of the first report milestone.
11. Fixture panel: lossless ER=6, 100 × 100 × 15 mm, nearest face 0.20λ from
    the feed, `max-cells 1000`, with azimuth selected by preflight.

No unresolved API decision blocks implementation. The first development slice
should be AT-D0 plus the Manifold-free material/volume registry portion of
AT-D1; that establishes stable data structures before changing process launch
or report code.
