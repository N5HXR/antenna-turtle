# Polarization Workbench M13 Portable HTML Integration Plan

## Goal

Reproduce the approved native far- and near-field polarization workbenches in
the self-contained NEC2C HTML report.  The NEC2C report is the required M13
deliverable.  OpenEMS report integration is optional and may be included only
where the existing report payload and viewer architecture make it a small,
isolated adaptation.

M13 does not change a solver, request additional NEC2C samples, or introduce a
server dependency.  All required polarization quantities are derived in the
browser from data that NEC2C reports already embed.

## Existing-data audit

The NEC2C report already contains everything required by the approved views:

- each far-field sample includes total gain, complex `E(theta)`, complex
  `E(phi)`, axial ratio, tilt, and polarization sense;
- each near-field sample includes complex Cartesian E and H vectors;
- pattern and plane coordinates, frequency, and antenna geometry are present;
- the browser already interpolates complex far-field components and computes
  average and instantaneous Poynting vectors.

M13 may add schema metadata or derived browser-side caches, but it must not
duplicate derived polarization arrays in the report payload unless profiling
demonstrates a concrete need and the user approves that change.

## Required NEC2C work

### 1. Shared browser polarization mathematics

Extract small, independently tested JavaScript helpers for Stokes parameters,
signed circularity, axial ratio, tilt, Cartesian polarization ellipses, spin,
and phase-coherent ellipse positions.  Use the same handedness convention and
numeric definitions as the Racket implementation.

Synthetic fixtures cover exact linear, RHCP, LHCP, and known elliptical
states.  Cross-language fixtures compare JavaScript results with the accepted
Racket values closely enough to detect sign, basis, or phase-convention drift.

### 2. Far-field report view

Extend the existing 3-D radiation-pattern workspace with a gain/polarization
view selector.  The ordinary gain view remains the default and retains its
current controls and appearance.

The polarization view reproduces the approved native behavior:

- opaque ARRL-radius total-gain surface;
- signed-circularity surface by default, using the frozen vivid ramp and
  gain-derived brightness;
- selectable axial-ratio surface;
- exact click inspector with gain, axial ratio, tilt, and sense;
- clicking the background clears the selection;
- optional, default-off ellipse glyphs with stable gain-aware placement;
- globally coherent animated beads, phase scrub, play/pause, speed, and
  sample-quantized density;
- natural depth occlusion with no transparent or X-ray mode.

Switching between gain and polarization preserves camera orientation.  The
existing 2-D pattern workspace and its engineering hover data remain available
and numerically unchanged; redesigning the 2-D cut as a new polarization view
is not required by M13.

### 3. Near-field report view

Add `POLARIZATION` to the existing planar near-field workspace without
removing its current E, H, or power views.  Keep the HTML view deliberately
lighter than the native GUI: it colorizes the existing smoothed plane and does
not import ellipse, halo, point-trajectory, spin, or Poynting overlays.

The polarization field provides:

- signed circularity using the frozen LHCP / linear / RHCP ramp;
- cyclic axial-tilt color, with the equal -90 and +90 degree orientations
  meeting at the same color;
- exact hover values for projected U/V components, the normal E component,
  axial ratio, tilt, sense, and signed circularity;
- an explicit convention that sense is measured in the displayed U/V plane
  while viewed along its positive normal, rather than assuming local power
  flow is normal to that plane;
- static behavior with irrelevant phase, scale, floor, and playback controls
  disabled.

The existing exclusion mask, plane selection, smoothing, and field samples
remain authoritative.  Rich animated near-field polarization glyphs remain a
native Racket GUI feature.

### 4. Responsive offline presentation

Keep all assets bundled in the report.  Controls must remain usable on the
primary display and narrower laptop-sized windows, using scrolling or
collapsible groups where needed.  Static views must not continuously rebuild
geometry or consume an animation loop.

## Optional OpenEMS checkpoint

After the NEC2C view passes its unit and manual checks, perform one bounded
feasibility pass:

1. Confirm which approved near-field controls can consume the already-packed
   complex OpenEMS E/H captures through the shared JavaScript helpers.
2. Implement only adaptations that do not require solver changes, new field
   dumps, a new large payload, or a parallel viewer architecture.
3. Add OpenEMS far-field polarization only if complex angular NF2FF components
   are already available in the report payload or can be exposed by a small
   serialization change from existing result data.
4. Record unsupported OpenEMS views as explicit follow-up work.  Their absence
   does not block M13 approval.

### Checkpoint result

The bounded audit confirmed that OpenEMS reports already embed complex
Cartesian E-field captures in user coordinates and that the shared browser
mathematics can consume them. During validation, however, the reference helix
exposed unresolved differences between the NEC2C and OpenEMS wire models,
including feed behavior and accepted power. A polarization map derived from
that result would look authoritative without representing the intended
radiating state.

OpenEMS report polarization is therefore deferred in full. Its reports retain
their existing E, H, and power views; they do not expose signed-circularity or
axial-tilt controls in this milestone. A future stage will first establish
wire-geometry and feed parity on a reference antenna, then revisit near-field
polarization and the missing complex angular NF2FF payload. This does not
affect the accepted NEC2C deliverable or the native polarization viewers.

## Expected files

- `tools/report-viewer/nec2c-report.js`: NEC2C controls, scenes, selection,
  animation, and view dispatch.
- `tools/report-viewer/pattern-data.js`: complex pattern interpolation shared
  by gain and polarization modes.
- New focused JavaScript polarization/ellipse helpers and unit tests where
  separation improves testability.
- `tools/report-viewer/viewer.js` or a small shared module only if the optional
  OpenEMS checkpoint qualifies.
- `antenna-turtle/private/nec2c-html-report.rkt`: control markup, styles, or
  schema metadata; no required large data additions.
- `antenna-turtle/private/report-assets/viewer.bundle.js`: rebuilt checked-in
  offline runtime.
- NEC2C HTML-report and report-viewer tests.

## Development checkpoints

Each checkpoint is reviewed before proceeding so failures remain local:

1. **M13.1 — Browser math parity:** exact synthetic states and Racket/JS
   convention parity.
2. **M13.2 — NEC2C far field:** approved surface, inspector, and optional
   glyph behavior in an offline report.
3. **M13.3 — NEC2C near field:** signed-circularity and axial-tilt color maps
   in the existing planar workspace.
4. **M13.4 — Responsive/performance pass:** laptop-sized layout, static-loop
   suspension, bundle rebuild, and report regression tests.
5. **M13.5 — Optional OpenEMS audit/adaptation:** audit completed; report
   polarization deferred behind NEC2C/OpenEMS wire-model validation.

These checkpoints are one milestone and one approval/commit cycle unless the
user asks to split one into a separately approved milestone.

## Automated acceptance

1. JavaScript synthetic fixtures reproduce the accepted linear, circular, and
   elliptical polarization values and handedness.
2. Ordinary NEC2C gain, 2-D pattern, plot, geometry, current, charge, and
   existing near-field modes retain their current defaults and tests.
3. The polarization surface uses total-gain geometry and reproduces the frozen
   signed-circularity and axial-ratio mappings.
4. Exact selection derives values from interpolated complex fields rather than
   the nearest displayed glyph.
5. Near-field average and instantaneous Poynting calculations match existing
   field-math fixtures; static modes do not advance or redraw phase content.
6. A generated report remains self-contained and opens from `file:` without a
   server or network access.
7. The report-viewer test suite, relevant Racket HTML-report tests, and full
   project suite pass.

## Human approval checklist

1. The familiar NEC2C report opens in its ordinary gain view without a visual
   or interaction regression.
2. Dipole, crossed-dipole, and helix reports reproduce the approved far-field
   polarization story and convention.
3. The helix report makes the near-field sense and axial-tilt structure
   legible without confusing plane-relative handedness with local propagation.
4. Gain/polarization and near-field mode changes preserve camera context and
   do not leave stale glyphs, selections, or animation work.
5. Controls remain usable at the primary workstation size and a representative
   smaller laptop window.
6. Any included OpenEMS support is useful and consistent; any deferred support
   is explicitly documented and does not weaken the NEC2C result.

## Out of scope

- New NEC2C or OpenEMS solver outputs.
- Making OpenEMS parity a release gate.
- A new 2-D polarization-cut design.
- Transparent or X-ray radiation patterns.
- A Poincare-sphere view.
- External web assets or a required local server.
