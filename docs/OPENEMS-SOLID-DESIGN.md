# OpenEMS and solid-geometry design

Status: accepted design for the `feature/openems-solid-modeling` branch.
Implementation is intentionally staged; sections marked *deferred* are design
commitments, not promises of support in the first proof of concept.

## Goals

The OpenEMS backend extends Antenna Turtle from wire centerlines to physical
electromagnetic geometry while retaining the existing turtle and live-coding
model. The first useful backend must:

- construct arbitrary solid geometry with the Racket `manifold` package;
- place geometry using the current turtle pose;
- represent PEC volumes, lossless dielectric volumes, and zero-thickness
  conducting sheets;
- run a one-port OpenEMS simulation through Octave;
- return S11, input impedance, and Smith-chart data;
- record near fields for three-dimensional radiation postprocessing; and
- provide a solid viewer before simulation so geometry, ports, and bounds can
  be inspected.

The backend depends on GNU Octave and the OpenEMS and CSXCAD Octave packages.
It will not reproduce their XML, solver, or postprocessing implementation in
Racket.

## Scene model

The existing wire graph remains authoritative for NEC2C and MMANA. A separate
physical scene contains three tagged geometry representations:

1. **Volume bodies** contain an owned, transformed Manifold solid, a material,
   and an optional CSXCAD priority.
2. **Planar sheets** contain a polygon, conducting material, and optional
   priority. A zero-volume sheet is not represented as a fictitious Manifold
   solid.
3. **Wire networks** remain centerlines. The OpenEMS exporter derives capsule
   unions from a snapshot of the wire graph.

The scene additionally contains lumped ports. Ports are subordinate to the
physical geometry: `clear-bodies` clears bodies, sheets, and explicit ports.
`clear-wires` clears centerlines and therefore removes their derived geometry
and derived ports. `reset-model!` clears both domains.

Explicit bodies and sheets are ignored by NEC2C and MMANA with a warning. A
model with no wire graph remains an error for those exporters. Derived capsules
do not cause a warning because they are another representation of geometry the
wire backend already consumes.

## Manifold namespace and ownership

Antenna Turtle and Manifold both export common names such as `cylinder` and
`scale`. Programs should import Manifold with a prefix:

```racket
(require (prefix-in m: manifold))
```

The complete Manifold API remains available without maintaining a conflicting
shadow vocabulary. Turtle-oriented wrappers may be added later when repeated
physical-construction idioms become clear.

All physical lengths in raw Manifold values are interpreted as metres. Scene
registration transforms a copy of the supplied solid and owns that copy. The
caller retains ownership of the source solid. Clearing the scene closes only
the scene-owned handles.

## Turtle placement

Bodies and sheets use the current turtle coordinate frame by default. A body
form is pair-wise so optional settings remain extensible:

```racket
(body radiator
  material pec
  geometry radiator-shape
  priority 20
  coordinates local)
```

`geometry` is required. Defaults are PEC, local turtle coordinates, and no
explicit priority. `coordinates world` is an escape hatch for already-placed
generated geometry.

Nonlinear `with-warp`/`with-surface` geometry and `radial-repeat` cannot be
represented by a single affine body placement. The initial implementation
rejects body placement inside those scopes rather than silently producing the
wrong shape.

## Ports

### Wire-derived feeds

An existing feed marker becomes a physical feed gap and lumped OpenEMS port
when a wire network is converted to capsules. The default gap is:

```text
max(model wavelength / 1000, wire radius)
```

The feed may override the gap explicitly in a future compatible extension.
If the default gap is longer than the marked logical edge, OpenEMS conversion
warns that the wire graph is more detailed than its physical feed geometry.
Conversion continues when the completed conductor can still be cut into two
unambiguous terminals; an invalid or ambiguous physical port is an error.

### Explicit lumped ports

An explicit port is centered on the current turtle and selects a local axis,
similarly to `spread`, without moving the turtle:

```racket
(port forward
  name "feed"
  impedance 50
  gap 1mm
  width 3mm
  depth 2mm)
```

The minimal `(port forward)` uses a generated name, model impedance, and
`wavelength/1000` for the gap, width, and depth. Width and depth may be
overridden explicitly to fit the conductor geometry. Direction controls
voltage polarity.

For a one-port model, the exporter rigidly rotates the complete scene so the
port direction aligns with a Cartesian Yee-grid axis. The forward and inverse
transforms are recorded and radiation directions are returned in the user's
original coordinates. Future multi-port export can accept a set of directions
only when one rigid transform makes every port grid-aligned.

## Materials and overlap

The proof of concept supports PEC and nondispersive lossless dielectrics.
Material data nevertheless reserve relative permeability and electric and
magnetic loss fields so isotropic magnetic and dispersive materials do not
require a replacement representation.

Ferrites are not merely lossy dielectrics. Future work may require complex,
frequency-dependent, anisotropic, or gyrotropic permeability and is bounded by
the material support available in OpenEMS.

Overlap rules are deliberately explicit:

- same-material overlapping volumes are allowed and may be unioned at export;
- different materials with nonzero volume overlap need distinct explicit
  priorities;
- missing or equal priorities on such an overlap are validation errors;
- ordinary boundary contact is not volume overlap;
- a conducting sheet may lie on a dielectric boundary; and
- ambiguous sheet penetration or coincident priorities require an explicit
  diagnostic rather than automatic Boolean resolution.

Ports use a backend-reserved priority higher than ordinary material geometry.

## OpenEMS execution and results

The backend writes one geometry artifact per body or sheet as appropriate,
generates an Octave driver, runs OpenEMS, invokes `calcPort`, and writes simple
machine-readable result tables. Failed runs retain their complete working
directory. Successful network-only runs may clean up automatically.

The first executable slice is `openems-sweep`. It currently accepts PEC
volume bodies and exactly one explicit lumped port, applies the port-alignment
transform, creates a conservative fixed mesh, runs Octave/OpenEMS, and returns
frequency-indexed complex S11 and input impedance samples. The generated
driver prints its timestep ceiling and energy stop criterion before starting;
the retained `openEMS_stats.txt` records which limit ended the run.

```racket
(define result
  (openems-sweep 800 1050
                 #:steps 101
                 #:keep-artifacts? #t))
```

The runnable reference is `examples/openems-dipole.rkt`. Dielectrics, sheets,
wire-to-capsule conversion, NF2FF recording, mesh refinement, and direct plot
adapters remain later milestones.

Although the proof of concept excites one port, result structures are designed
for a frequency-indexed complex S-matrix. A complete N-port matrix eventually
requires one simulation per independently excited port.

Solver-neutral network results feed the existing return-loss, impedance, and
Smith-chart renderers. For one port:

```text
Zin = Z0 (1 + S11) / (1 - S11)
```

## NF2FF recording and artifact lifetime

Near-field recording is configured during the original FDTD run. The default
time-domain recording permits later extraction at the model frequency, any
requested frequency within the excitation band, or the best-match frequency
without rerunning OpenEMS. It consumes more disk than fixed frequency-domain
recording.

An optional explicit frequency list selects frequency-domain recording and
smaller artifacts. Postprocessing at an unrecorded frequency is then an error,
not an implicit solver rerun. NF2FF surface resolution is limited according to
the shortest simulated wavelength to reduce disk use.

An NF2FF-capable result owns its retained field directory until explicitly
closed. Extracted Racket pattern values remain valid afterward. A keep-artifact
option suppresses automatic deletion for inspection and reproduction.

The pattern API defaults to `model-frequency` and accepts a numeric override or
`'best-match`. Results retain directivity, gain, realized gain, radiated power,
and radiation efficiency when available. The ordinary pattern viewer defaults
to gain/directivity; realized gain remains selectable.

## Initial mesh

The proof of concept uses a conservative critical-coordinate mesh:

- lock port faces, body extrema, material boundaries, and simulation bounds;
- refine locally around the feed;
- cap field cells by the shortest wavelength, including dielectric wavelength;
- smooth the transition with a bounded adjacent-cell growth ratio; and
- estimate and report the cell count before running.

Geometry-aware iterative plane removal is deferred until a reliable backend
exists. That strategy will operate on axis-line sets, preserve locked planes,
test material occupancy/topology and geometric error, and enforce wavelength,
aspect-ratio, grading, and total-cell constraints.

## Validation

The first end-to-end execution is intentionally early: one PEC body, one
lumped port, a fixed basic mesh, generated artifacts, an OpenEMS run, and S11
parsing precede extensive DSL and meshing automation.

A free-space center-fed dipole is the primary cross-solver reference. The same
wire centerline is simulated with NEC2C and capsule-derived OpenEMS geometry.
The comparison records resonant frequency, impedance, S11, approximately
2.15 dBi free-space directivity, selected cuts, and the 3D pattern. Expected
differences include finite radius, physical feed gap, NEC segmentation, and
FDTD staircasing.

An opt-in mesh-convergence integration test compares approximately lambda/10,
lambda/15, and lambda/20 meshes. Initial measurements include resonant
frequency, impedance, S11, maximum directivity, and selected pattern samples.
Numerical pass tolerances will be based on observed convergence rather than
invented before the backend produces data.

## Reproducibility manifest

Every run retains a machine-readable manifest with enough information to rerun
the generated simulation without reevaluating the source program. It includes:

- Antenna Turtle source/version/revision information;
- Manifold, Octave, OpenEMS, and CSXCAD versions;
- executable and generated command information;
- geometry names, types, material properties, priorities, bounds, hashes, and
  triangle counts;
- user-to-solver and inverse transforms;
- port dimensions, polarity, impedance, priority, and feed-gap derivation;
- exact mesh-line arrays and cell count;
- simulation bounds, boundary conditions, excitation, and termination values;
- NF2FF box, phase center, recording mode, frequencies, and resolution;
- generated Octave, XML, and geometry artifact names; and
- exit status, elapsed time, result frequencies, and artifact sizes.

## Deferred solid-turtle operations

The scene design must leave room for physical construction driven by turtle
traces, but these operations are not part of the proof of concept:

- trace a closed loop in a turtle axial plane and extrude it;
- revolve a closed trace;
- sweep a circular, rectangular, or arbitrary profile along a turtle path;
- loft between multiple traces; and
- decide whether any of those operations also emit useful NEC centerlines.

Other deferred extensions are multi-port S-matrices, planar/distributed,
microstrip, coplanar, coaxial, and waveguide ports, ferrite and dispersive
materials, solid-based MATLAB export, and topology-aware mesh simplification.
