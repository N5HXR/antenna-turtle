# Model Shaker — Revision 1 Specification

Status: **Ready for implementation review**

## 1. Purpose

Add a deterministic robustness-audit facility that reruns the current Antenna
Turtle wire model under small, controlled perturbations using a selected
simulation engine. The report answers:

> Does the modeled result remain substantially stable when numerically or
> physically insignificant details are changed?

The shaker is a diagnostic tool, not an optimizer and not a proof that a model
is correct. Stability increases confidence; instability identifies a model,
feed, or requested measurement that needs closer inspection.

## 2. Initial scope

The public design is engine-agnostic. The first argument selects a backend:

```racket
(model-shake 'nec2c ...)
(model-shake 'openems ...)
```

Common physical perturbations and result summaries belong to the model-shaker
layer. Numerical perturbations and some measurements are capabilities of the
selected engine. Unsupported requested capabilities produce a clear error;
the front end does not silently substitute a different experiment.

The first useful release should support two explicitly distinct classes of
perturbation.

### 2.1 Numerical perturbations

These preserve the authored physical geometry:

- bounded stochastic wire-segmentation changes; and
- a small frequency offset when requested, primarily to distinguish a shifted
  resonance from a wholesale change in antenna behavior.

Revision 1 does not move excitation away from the authored feedpoint or change
its authored formulation. Feed perturbations are deferred unless experience
demonstrates a need.

### 2.2 Physical-tolerance perturbations

These intentionally alter the already-constructed wire scene within explicit
bounds. Physical shaking is a core part of the first useful feature, not a
requirement that the programmer rewrite geometry construction as a function.

Initial physical perturbation families should include:

- displacement of existing wire vertices and junctions;
- small changes to wire length and endpoint position where constraints allow;
- transverse bow or kink applied to nominally straight conductors
  ("non-straightening").

Revision 1 does not vary wire diameter. Diameter tolerance is a distinct
manufacturing property and may be added later as an explicit perturbation.

Excursion is based primarily on a percentage of each baseline edge explicitly
authored by the DSL, not its solver segment length and not wavelength. An
authored edge is one `move`/`spread` operation, or one line between consecutive
`point` calls in a `with-points` scope. Subdivision introduced later by NEC2C,
OpenEMS conversion, rendering, or any other model-generation phase does not
change the physical tolerance scale. This keeps short feed networks and
phasing details on an appropriate scale. An optional absolute cap may prevent
unusually long authored edges from receiving implausibly large excursions.

Revision 1 exposes this as one dimensionless physical-severity parameter,
`#:degree`. A value of `0.01` permits physical excursions up to one percent of
the applicable authored-edge length. This is deliberately a literal fraction,
not an opaque `low`/`medium`/`high` preset.

The default degree is `0.01`.

- An interior bow or wander point uses the length of its originating authored
  edge.
- An existing vertex or junction uses the shortest incident authored edge,
  preventing a long element from imposing an excessive movement on a small
  attached feed structure. Any protected incident edge fixes that vertex
  entirely.
- An optional `#:maximum-excursion` caps the resulting physical distance in
  metres.
- Revision 1 has no absolute excursion floor.

`#:maximum-excursion` defaults to `#f`, meaning no absolute cap. The programmer
may supply a cap for models containing unusually long authored edges.

`#:degree` controls physical geometry only. Engine-specific numerical shaking,
such as NEC2C segmentation bounds, remains explicit so the same degree never
acquires different hidden meanings across engines.

Physical perturbations operate on a frozen copy of the current generated wire
scene. They require no knowledge of the turtle program or its construction
parameters. Moving a junction moves every incident conductor endpoint and
attached component together. A perturbation that would disconnect or reconnect
the model is rejected unless a future API explicitly requests a
topology-changing experiment.

Non-straightening may insert degree-two intermediate nodes into a conductor and
replace one straight edge with a connected polyline. This is considered
topology-preserving: the perturbed graph must be homeomorphic to the baseline
graph after degree-two subdivision vertices are suppressed. The original wire
scene remains unchanged.

Revision 1 inserts one midpoint into each eligible authored edge and displaces
it randomly within the edge's bounded excursion. This intentionally favors a
small, explainable kink model over a more elaborate synthetic smooth curve.

## 3. Required invariants

Every accepted variant must satisfy all of the following.

### 3.1 Electrical topology

- The conductor connected-component count is unchanged.
- The conductor graph is unchanged up to subdivision or removal of degree-two
  nodes introduced solely to represent curvature or wander.
- Every feed, port, load, transmission line, transformer, and network
  attachment remains attached to the same logical conductor node or edge.
- Coincident endpoints that form one authored junction are moved as a unit.
- A moved junction retains its baseline degree and incident-edge identities.
- No new conductor contact or intersection is introduced.
- No existing conductor contact is lost.

The baseline graph is extracted once from the frozen generated wire scene.
Variants are checked against that graph before the selected solver is run.
Graph identity should use stable wire and attachment identities where
available; geometric proximity is only the fallback used to discover a
baseline junction.

Each baseline edge retains provenance through any subdivision so loads, feeds,
ports, and per-wire settings can be mapped to the correct variant edge or
sub-edge. Attachments located in the interior of a wire become protected
topology nodes before perturbation.

### 3.2 Geometric validity

- No wire has zero or negative usable length.
- Wire radius and NEC2C thin-wire validity checks still pass.
- No element crosses below the configured ground plane.
- Baseline ground-contact points are fixed in the initial implementation. A
  point above ground may not be perturbed onto or through the ground plane.
- Programmer-declared fixed points, axes, planes, and dimensional bounds are
  respected.
- The complete variant stays inside any requested model envelope.

Invalid candidates are recorded as rejected variants with a reason. They are
not silently clipped, because clipping biases a perturbation distribution and
can collapse distinct candidates onto the same geometry.

Moving ground contacts—especially their relative spacing in models with more
than one contact—may be a useful future physical-tolerance experiment. It is
explicitly deferred until its ground and attachment semantics are understood.

### 3.3 Reproducibility

- Physical variants are generated by a seeded pseudo-random process.
- Every audit records its seed. Supplying the same seed, baseline model, engine,
  and options reproduces the same candidate geometries.
- If the programmer omits a seed, the shaker generates one and makes it
  prominent in the result and report.
- Every variant records its complete perturbation description and generated
  NEC artifact metadata.

Physical offsets are sampled uniformly inside their permitted bounds. Each
physical variant perturbs all eligible geometry simultaneously, approximating
one imperfect realization of the complete antenna rather than isolating one
geometric cause at a time.

Each requested variant also receives one stochastic, engine-specific
segmentation choice. Segmentation is sampled within documented conservative
bounds rather than expanded as a Cartesian product. The same shaken geometry
and segmentation choice are then used at every requested frequency. Increasing
`#:variants` or performing another seeded run increases sampling confidence
without changing the meaning of one variant.

## 4. Measurements and comparisons

The common result model records measurements supported by the selected engine.
At minimum, each successful NEC2C run records:

- complex impedance, including resistance, reactance, and magnitude;
- complex admittance, including conductance, susceptance, and magnitude;
- the change in conductance and susceptance separately;
- equivalent shunt-capacitance shift when that interpretation is meaningful,
  using `delta-C = delta-B / (2 pi f)`;
- VSWR at the configured reference impedance;
- maximum gain and, when requested, selected pattern samples;
- average-gain-test result where applicable; and
- available input/radiated/lost-power quantities and closure error.

Maximum gain and AGT use a 5-degree theta/phi grid by default. Engine-specific
resolution options may request a finer grid for narrow-beam antennas.
Because AGT is derived from the same radiation grid needed for maximum gain,
it is included by default where the engine and model support it. Available
power-balance quantities are likewise retained by default when they do not
require a separate expensive solver pass.

The summary should emphasize spread and worst excursion rather than collapse
the audit into a single opaque score. The shaker does not assign a fitness
score or label the model `stable` or `sensitive`; those judgments depend on the
model's purpose and acceptable engineering tolerances. Suggested headline
results are:

- median, minimum, maximum, and maximum deviation from baseline;
- sensitivity grouped by perturbation family;
- requested and completed valid-variant counts;
- total attempt count; and
- geometry-rejection, export-failure, and solver-failure counts with reasons.

The raw runs remain inspectable so the programmer can apply a different
judgment without rerunning the solver.

## 5. Proposed programmer interface

The API should match Antenna Turtle's explicit, composable style. A compact
first form could be:

```racket
(define audit
  (model-shake
   'nec2c
   #:frequency 14.1
   #:segment-count-range '(1.0 2.0)
   #:degree 0.01
   #:maximum-excursion 0.02
   #:variants 24
   #:seed 314159))

(show-model-shake-report audit)
```

The default input is the current constructed wire scene, consistent with other
Antenna Turtle measurement operations. The programmer does not have to provide
a builder function, parameter database, or named geometry. An explicit scene
argument may be added later for batch work, but it is not required for the
initial interface.

`#:variants` means successful solver results. When generated geometry is
invalid or a solver/export attempt fails, the shaker records the failed attempt
and continues sampling until it obtains the requested number of valid results
or reaches a bounded attempt limit. By default, the dead-man limit is ten times
the requested variant count. Failure frequency is itself reported evidence;
repeated rejection may reveal a model with little geometric margin or an
unsuitable perturbation degree.

The unshaken baseline is an additional result and does not consume one of the
requested variants. Thus `#:variants 24` requests one baseline plus 24 valid
shaken constructions, each evaluated at every requested frequency.

Backend-specific keywords are passed directly after the engine symbol and are
validated by that backend. Documentation for each engine lists its accepted
options. An option unsupported by the selected engine is an error rather than
being ignored or approximated.

For NEC2C, revision 1 treats segmentation as a stochastic variable. The
default range is the baseline through twice the baseline segment count. The
shaker refines but does not coarsen the programmer's selected discretization:
divergence under refinement is the actionable evidence. One global stochastic
factor is applied to every authored edge's baseline count, preserving relative
edge-local segmentation policies, then adjusted for feed-placement
requirements, parity rules, and other legality constraints. No variant may
exceed twice the baseline count by default. The factor and exact realized
segment counts are retained in every run result. The authored feedpoint and
source formulation are unchanged.

The current model frequency is used by default. `#:frequencies` accepts an
explicit list for a multifrequency or multiband audit:

```racket
(model-shake 'nec2c
  #:frequencies '(3.6 7.1 14.1 21.1 28.1)
  #:degree 0.01)
```

One randomized physical variant is reused across every requested frequency so
the rows describe the same imperfect construction. The final summary contains
one row per frequency, with the baseline and distribution of impedance,
admittance, conductance, susceptance, and maximum gain across valid variants.
A multifrequency variant counts as valid only when every requested frequency
produces all required measurements. Partial results remain attached to the
failed attempt for diagnosis but do not count toward `#:variants`.

### 5.1 Optional protection of sensitive structures

Automatic shaking will sometimes expose real sensitivity in closely spaced
structures such as parallel feed lines. That is normally useful evidence, not
an error. However, a programmer may know that a particular assembly is rigid,
commercially manufactured, or outside the intended tolerance experiment.

The smallest opt-out follows the existing `with-max-length` precedent by
recording out-of-band metadata on authored edges created in a lexical scope:

```racket
(without-shaking
  (from-here
    (with-wire (move down feed-line-length)))
  (from-here
    (move right spacing)
    (with-wire (move down feed-line-length))))
```

`without-shaking` prevents physical geometry perturbations of those authored
edges. The protection annotation is stored out of band by authored edge
identity, parallel to the existing edge-local segmentation database used by
`with-max-length`; it does not alter the historical public wire-edge shape.
The same principle applies to authored point-trace lines when they participate
in a shaker-supported wire model.

The annotation protects geometry only. It does not prevent engine-specific
numerical perturbations such as segmentation changes. An endpoint shared by a
protected and movable edge is fixed, so the movable edge remains connected to
the protected structure.

A possible future rigid-group form could preserve all internal distances
inside a scope while allowing the assembly to translate or rotate as a unit.
This would model uncertain placement without disturbing accurately controlled
parallel-line spacing. It is deliberately deferred so the first implementation
has only ordinary and protected geometry paths.

Physical perturbations should be bounded globally and may later accept local
exceptions for protected or unusually tolerant regions. One possible future
shape is:

```racket
(with-shake-constraints
  ([ground-contacts #:fixed? #t]
   [junctions #:within 0.01]
   [straight-edges #:wander 0.01]
   [all-points #:above-ground? #t])
  (model-shake 'nec2c ...))
```

This syntax is illustrative. The constraint and parameter-binding vocabulary
requires review before implementation. Fractional values in this example mean
a fraction of authored edge length; `0.01` is one percent.

## 6. Presentation

The first presentation can be a textual report plus transparent Racket result
structures. The report should:

1. identify the baseline;
2. show the perturbation matrix actually run;
3. separate numerical sensitivity from physical tolerance sensitivity;
4. compare `G` and `B` as prominently as `R` and `X`;
5. call out resonance shifts rather than merely reporting large reactance
   changes at one fixed frequency; and
6. identify invalid, export-failed, and solver-failed attempts without treating
   them as poor electrical results;
7. report failure counts and rates separately from successful measurement
   statistics; and
8. avoid a composite score or qualitative robustness label.

Revision 1 also provides ordinary Racket Plot views built from the same typed
result data. They should reuse existing plot styling and machinery rather than
introduce a new GUI framework. A useful multifrequency view shows the baseline,
median, and observed range versus frequency for impedance/admittance components
and maximum gain. Text output remains complete enough for headless use. HTML
and richer interactive presentation remain later work.

Computation and presentation remain separate:

```racket
(define audit (model-shake 'nec2c ...))
(model-shake-report audit) ; textual tables
(show-model-shake audit)   ; plots
```

Single-frequency plots show every valid variant point plus the baseline.
Multifrequency plots emphasize the baseline, median, and observed range at each
frequency.

## 7. First development spike

The first spike includes both numerical and physical perturbations:

1. capture an immutable baseline wire scene and its topology graph;
2. generate a bounded stochastic segmentation choice for each NEC2C variant
   while preserving the authored feedpoint and source formulation;
3. generate 24 seeded, uniformly bounded random physical variants by default,
   shaking all eligible geometry simultaneously and pairing each with one
   segmentation choice;
4. preserve edge provenance through any inserted bend points;
5. validate topology, attachments, ground clearance, and geometry before
   export;
6. run impedance, AGT, and power diagnostics;
7. retain typed per-run results; and
8. render a concise text report and ordinary Racket Plot views.

The spike succeeds if it can expose feed-model or segmentation sensitivity on
a dipole and at least one bent-wire model without changing their electrical
topology. It must demonstrate that a straight element can be given a small
bounded bow or wander while remaining connected.

## 8. Non-goals for the first spike

- automatic geometry repair;
- topology-changing experiments;
- unconstrained movement of model coordinates;
- full-factorial, genetic, or adaptive search;
- automatic selection of the "correct" variant;
- reconstructing or replacing the programmer's current geometry;
- a custom interactive GUI or polished HTML reporting; and
- claiming agreement between solvers proves physical correctness.

## 9. Acceptance criteria

- Repeating an audit with the same explicit or recorded seed produces the same
  variants and results, within solver numerical tolerance.
- Every excitation formulation remains attached to the feedpoint specified by
  the authored model.
- Segmentation changes preserve attachment identity and produce legal NEC2C
  decks.
- A deliberately disconnected or newly intersecting test variant is rejected
  before the solver runs.
- A straight-edge-wander variant inserts only provenance-linked degree-two
  nodes and remains homeomorphic to the baseline conductor graph.
- A ground-crossing physical test variant is rejected rather than clipped.
- The report makes a primarily capacitive feed-model discrepancy recognizable
  through the separate `G`/`B` comparison.
- A known low-spread reference model and a deliberately
  segmentation-sensitive model are visibly different in their reported
  measurement spreads without the shaker assigning either model a qualitative
  label.

## 10. Revision 1 defaults

- engine selected explicitly by the first argument to `model-shake`;
- current model frequency, or an explicit `#:frequencies` list;
- 24 valid shaken variants plus one unshaken baseline;
- at most ten times the requested variant count in total attempts;
- seeded uniform bounded random physical perturbations;
- `#:degree 0.01` and `#:maximum-excursion #f`;
- all eligible geometry shaken simultaneously;
- ground contacts and `without-shaking` scopes fixed;
- one displaced midpoint per eligible authored edge;
- unchanged wire diameter, feedpoint, and feed formulation;
- NEC2C segmentation refined by one global stochastic factor from 1× through
  2× baseline, never coarsened;
- complete success at every requested frequency required for a valid variant;
- impedance/admittance components, maximum gain, AGT, and available power data;
- 5-degree gain/AGT sampling by default;
- no composite score or qualitative robustness verdict; and
- separate text and Racket Plot presentation functions.
