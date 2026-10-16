# Interactive HTML reports: Milestone 0

This document records the implementation boundary and technical decisions for
the first self-contained Antenna Turtle simulation report. It is deliberately
more specific than the eventual user documentation: later milestones may
change the internal schema while retaining the public capture vocabulary.

## Implemented vertical slice

An openEMS simulation can retain one frequency-domain capture with
`record-fields` and a solver-neutral `field-capture` value. The exporter writes
one portable HTML file containing:

- authored model geometry and material styling;
- normalized complex field/current phasors and their Yee-grid coordinates;
- capture frequency, excitation, units, normalization, transforms, and solver
  metadata;
- an embedded Three.js WebGL viewer with orbit, pan, and zoom controls; and
- play/pause, playback speed, phase, model visibility, and field visibility
  controls.

No HTTP server, CDN, loose asset, or extraction step is required. The initial
browser target is current Chrome on Linux.

## Module boundaries

The implementation has four intentionally separate boundaries:

1. `field-capture.rkt` describes solver-neutral requests: conductor current and
   axis-aligned electric or magnetic slices at a selected frequency.
2. `openems.rkt` maps those requests to openEMS dumps, normalizes openEMS HDF5
   through its supported `ReadHDF5Dump` routine, and records stable binary
   sidecars plus manifest metadata.
3. `html-report.rkt` maps a completed result and artifact manifest into the
   report schema. It owns compression and HTML embedding, but no WebGL logic.
4. `tools/report-viewer/viewer.js` consumes only the report schema. The checked
   in browser bundle is built with esbuild and includes Three.js and
   `OrbitControls`; it does not know about Racket or openEMS result structures.

This separation permits a future backend to produce the same schema without
emulating openEMS files.

## Coordinates, phasors, and normalization

The openEMS adapter retains solver-coordinate sample axes and records the full
solver-to-user transform. The viewer transforms both sample positions and
vectors, preserving orientation and handedness. The normalized sidecar array
order is `x` fastest, followed by `y`, `z`, and vector component.

OpenEMS frequency-domain accumulation uses the convention represented in the
manifest as:

```
instantaneous = real(phasor * exp(+j*phase))
```

All captured phasors are divided by the square root of incident port power at
the exact capture frequency. Values therefore correspond to one watt incident
at the selected excitation while retaining relative complex phase. E and H
slice units are V/m and A/m. Direct total-current dumps are retained with the
openEMS current-density units reported by the adapter.

## Current presentation

Milestone 0 supports direct current capture on planar conductor sheets. Every
four neighboring Yee samples define a contiguous display cell; its color is
computed from the reconstructed instantaneous current. Display cells are a
visual interpolation surface, not a claim that openEMS produced cell-centered
values.

The conductor layer has three color modes. `|current|` is the default and
shows the phase-independent magnitude of the complex longitudinal-current
phasor on a zero-to-maximum MMANA-style scale. `dir(current)` reconstructs the
instantaneous signed longitudinal current and uses a bipolar version of that
palette:

- the low and high ends represent opposite current polarities;
- the palette midpoint represents zero current; and
- distance from the midpoint represents instantaneous magnitude.

Polarity is referenced to the capture's dominant Cartesian current component.
That is unambiguous for the straight planar fixtures in this milestone. Curved
and branching conductors require a later local-tangent convention. Non-current
field slices continue to use diagnostic vectors in this first slice.

Signed current and charge use a symmetric, MMANA-derived diverging palette with
a dark zero and equal perceptual range for both polarities. A 1.5 power-law
display curve separates moderate and strong values that would otherwise occupy
a narrow band of colors. This is explicitly a color-transfer function; stored
phasors and reported units remain linear and unchanged.

`charge` uses a companion openEMS frequency-domain electric-flux (`D`) dump on
each PEC sheet. Surface charge is the normal electric-flux density immediately
outside the conductor. Cell interpolation is requested to avoid the documented
node-interpolation error at metal boundaries. The viewer averages the normal
component across the strip width, normalizes it independently from current,
and displays its instantaneous complex-phasor reconstruction in C/m^2. This
avoids differentiating the total-current dump at an impressed feed, which would
turn the port discontinuity into a misleading charge spike. Arbitrary curved
and volumetric conductor surfaces require a later two-sided normal-flux
implementation.

All planar conductor dumps at one capture frequency are presented together as
one current layer, with one normalization and polarity reference. The shared
color scale is normalized against the strongest displayed width-integrated
station phasor, rather than an individual edge Yee sample. Every polygon across
one transverse station receives the same color. This intentionally presents
current flowing along the conductor as the primary view and prevents the
physical current-density concentration at ideal sharp PEC edges from consuming
the useful palette range. The original complex per-cell vectors remain embedded
and unchanged for later diagnostic views.

For presentation, adjacent width-integrated station values are averaged onto
their shared longitudinal boundaries and assigned as vertex colors. WebGL then
interpolates those colors across the triangles (Gouraud-style shading). This
hides artificial polygon banding without adding electromagnetic samples or
changing the values used for normalization.

The display surface is offset a small, scale-relative distance from the model
only in WebGL. Stored coordinates remain exact. This avoids depth-buffer
fighting without inventing samples on both faces of a zero-thickness sheet.

## Milestone 3 triangulated surface reconstruction

An openEMS `rot(H)` dump over a three-dimensional PEC/STL volume does not
directly provide a reliable per-triangle surface-current map. Milestone 0
therefore rejected volumetric conductor requests rather than silently
presenting near-zero or volume-grid data as surface current. Milestone 3
implements the general path:

1. sample complex H on a thin Yee-aligned shell around each conductor;
2. interpolate those samples to rendered surface points or triangles;
3. use surface normals and fields immediately outside/inside the conductor;
4. reconstruct surface current with `K = n × (H_out - H_in)`; and
5. retain the shell, mesh association, sample offset, and side policy in the
   backend-neutral report schema; and
6. reconstruct smoothly interpolated per-vertex current in the browser.

Free surface charge is reconstructed independently from the normal electric
flux jump, `rho_s = n · (D_out - D_in)`. This avoids numerically differentiating
surface current at an impressed feed. Closed PEC bodies use zero interior
fields; zero-thickness and finite-conductivity boundary bodies sample both
sides. Planar sheets retain the earlier direct capture, giving a regression
reference for the shell method.

All conductive geometry shares one model-global normalization. Current
magnitude uses a logarithmic floor by default; signed free charge uses the
corresponding symmetric-log transfer. Curved conductors intentionally use
instantaneous current magnitude rather than vector arrows or a fabricated
global tangent direction. The stored complex vectors and physical units remain
linear and unchanged by these presentation choices.

## HDF5 dependency decision

The available Racket HDF5 package was evaluated against the installed HDF5
library. Its low-level FFI loads, but it does not currently offer a compact,
stable high-level reader for the openEMS field layout. Milestone 0 instead uses
openEMS's installed Octave `ReadHDF5Dump` implementation during normal solver
postprocessing and writes simple float32/CSV sidecars.

This avoids a new mandatory native dependency and isolates the openEMS HDF5
dialect. A future direct Racket reader remains possible behind the same
normalization boundary.

## Packaging and browser security

Binary arrays and geometry are gzip-compressed and base64-encoded into JSON in
the HTML document. Chrome's built-in `DecompressionStream` expands them in
memory. JSON `<` characters are Unicode-escaped before embedding so
user-authored metadata cannot terminate the data script element.

A single-file HTML/ZIP polyglot was considered but is not the default:

- `file:` documents cannot portably fetch their own appended byte range;
- browser origin and opaque-file restrictions differ across vendors;
- ZIP central-directory tricks are fragile under rewriting and security
  scanning; and
- a polyglot provides little value until report payloads exceed practical
  inline sizes.

Inline gzip incurs base64 overhead but has the most predictable direct-open
behavior. Later reports may optionally support a compressed archive plus a
served viewer for very large captures, without changing the portable default.

## Size controls

`#:max-samples` causes the backend to choose a uniform openEMS dump
subsampling stride. The viewer additionally limits diagnostic vector counts and
coalesces planar heatmap cells to roughly ten thousand display cells when a
capture is unusually dense. Geometry and float arrays are gzip-compressed.

Future levels of detail should be selected during export, not by discarding
the only retained scientific data after simulation. Reports should expose both
the requested and effective sampling in metadata.

## Milestone 1 field slices

Electric and magnetic captures requested on the same plane use cell
interpolation so their displayed Yee samples remain spatially co-registered.
This avoids the electric node-interpolation error at abrupt permittivity and
PEC boundaries. Cell-interpolated normal H can be inaccurate at abrupt
permeability boundaries; magnetic material modeling is outside revision 1 and
must revisit that choice.

The viewer groups E and H by physical slice and shows one slice at a time.
Instantaneous plane-tangential intensity is the default, combining the two
components visible in the selected plane while excluding its normal component.
Tangential vectors and projected instantaneous streamlines animate their joint
direction. Static total and tangential phasor envelopes, full 3D vectors,
signed normal, and user x/y/z components remain available for diagnostics.
Static envelopes mute phase and playback controls. Streamlines are integrated
from the instantaneous field after projection into the display plane; they are
a visual guide to direction, not charge trajectories.
The normal component follows the plane axis and is therefore identical to X
on an X-normal plane, Y on a Y-normal plane, and Z on a Z-normal plane. Signed
components reconstruct `real(phasor * exp(+j phase))`. E uses a warm
violet/magenta/orange/yellow family and H a cool blue/cyan/green family.

An explicit volume capture retains the cell-centered complex E/H phasors over
the full simulation domain. It is one steady-state frequency-domain dataset,
not a sequence of time frames: every animation phase is reconstructed from
the complex value at each retained voxel. The report can therefore select an
X-, Y-, or Z-normal plane and move it continuously through the volume,
interpolating complex components between adjacent retained planes before
calculating displayed values. Fixed slice capture remains available for
smaller reports.

Every scalar coloration may be linear or logarithmic with an adjustable dB
floor. Signed component views use a symmetric-log transfer, retaining their
positive and negative color families. Vectors and streamlines use the same
transfer for visibility, length, or color emphasis. These controls change only
the display transfer. Coordinates, complex phasors, normalization, and units
remain unchanged. The full captured plane is
shown, and a dashed outline marks the inner edge of the eight-cell PML so
attenuation in the absorber is not mistaken for ordinary free-space behavior.
By default, color exposure uses the 98th percentile of complex amplitude on
the displayed plane, preventing isolated feed- or PEC-adjacent peaks from
hiding the rest of the field. The exposure is derived from phasor amplitude
and therefore remains constant over the animated phase cycle. A volume-range
option retains one absolute scale while moving among planes when relative
field strength is the quantity being compared.

## Milestone 2 power-flow extension

Milestone 2 reuses the co-registered complex E/H volumes introduced in
Milestone 1. The report schema remains backend-neutral: Poynting power is a
viewer-derived quantity, not an openEMS-specific stored array. The viewer
offers time-average and instantaneous magnitude, signed through-plane flow,
vectors, and plane-projected flow lines. Time-average power is
`0.5 Re(E × conjugate(H))`; instantaneous power is `E(t) × H(t)` using the
recorded phasor convention.

The average normal component is integrated with physical nonuniform cell areas
over the selected plane. PML cells are excluded from that sampled estimate,
and its sign is referenced to the selected positive model-coordinate plane
normal. Because report subsampling and interpolation do not reproduce a
dedicated Yee-stagger-aware power monitor, authoritative power accounting still
comes from solver port/power results. Legends
display physical units and maxima even when logarithmic or symmetric-log color
transfers are active. Field and power slices may optionally overlay the
conductor-current heatmap.

The Milestone 2 schema embeds the complete port-sample or S-parameter table,
solver convergence/timing, mesh summary, and exact-frequency port, dielectric,
and lumped power rows. Both absolute solver watts and values normalized to the
selected excitation's incident power are retained.

Viewer work does not require recompressing captured fields. After rebuilding
the checked-in browser bundle, `npm run refresh -- REPORT.html` in
`tools/report-viewer` atomically replaces only the final embedded script of a
development report. It preserves the embedded report JSON byte-for-byte.

## Regenerable fixtures and acceptance

Fixture source is retained under `examples/reporting/`; generated simulations
and HTML belong under ignored `scratch/` or temporary directories.

Milestone 0 fixture acceptance is:

- **Dipole:** geometry and current cells overlap in user coordinates;
  `|current|` peaks at the feed and falls toward the tips; `dir(current)` has
  one continuous global direction across both arms and reverses after 180°;
  derived charge has opposite signs on the two arms, is approximately a
  quarter-cycle out of phase with current, and reverses after 180°; 0° and
  360° render identically; the report opens directly
  in Chrome with networking disabled.
- **Two-conductor line:** the two conductors remain spatially aligned; current
  polarity is physically opposite where expected; phase progression along the
  line is continuous; co-registered transverse E/H volume slices show dominant
  E across the conductor gap and circulating H, while the real part of
  `E cross conjugate(H)` points in the forward transmission-line direction;
  X/Y/Z plane selection and position interpolation preserve geometry alignment
  and do not introduce phase discontinuities.
- **Portability:** the final HTML contains no external URL or fetch request and
  remains functional after moving it away from the artifact directory.
- **Failure behavior:** capture outside the sweep, unknown excitation, invalid
  slice plane, missing retained artifacts, and unsupported volumetric current
  capture fail with targeted errors before a misleading report is produced.

Milestone 3 adds two solid-surface acceptance fixtures:

- **Solid dipole:** paired H/D shell captures map to both closed cylindrical
  PEC arms; reconstructed current and charge are finite and nonzero; current
  is stronger near the feed than at the tips; shared vertices interpolate
  without visible triangle bands; and the scalar surface follows the exact STL
  without depth fighting or an inflated silhouette.
- **Moxon array:** the calibrated two-element geometry is converted from
  ordinary Turtle wires to triangulated capsule solids; current and charge are
  visible over the complete driven and parasitic structure; movable E/H and
  Poynting slices remain aligned with the surface overlay; and the broadside
  instantaneous and average power-flow views expose the expected directional
  interaction inside a 1.5-wavelength padded domain.
- **Surface failure behavior:** missing geometry associations, unmatched H/D
  shell captures, non-finite reconstructed values, and empty surface datasets
  fail validation instead of silently falling back to volume-grid coloration.

The reporting fixtures use a relaxed -30 dB convergence threshold because they
validate data flow and presentation rather than precision RF results. Analytic
simulation-validation examples should continue to use convergence profiles
appropriate to their claimed accuracy.
