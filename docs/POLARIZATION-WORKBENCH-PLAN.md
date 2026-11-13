# Polarization Workbench Feature Plan

## Purpose

Build pedagogical native OpenGL views that make linear, circular, and
elliptical polarization visually intuitive while retaining a small numerical
inspector for engineering use.  Experimental viewers settle the interaction
model before the feature is integrated with Antenna Turtle's existing native
and portable HTML viewers.

Development takes place on `feature/polarization-workbench`.  Each milestone
has a separate plan, development, test, user-approval, commit, and push cycle.
An approved milestone is committed before the next milestone begins.  The
branch may be squashed when the completed feature is merged.

## Shared visual language

- Pattern geometry uses the existing ARRL radial scale by default.
- One opaque total-gain surface carries polarization information; there is no
  transparent or X-ray mode.
- Signed circularity uses a fixed vivid pink-red / yellow-green / blue ramp:
  LHCP is `(255, 32, 128)`, linear is `(128, 255, 32)`, and RHCP is
  `(32, 128, 255)`.
- Polarization glyphs use stable, surface-area-aware placement and similar
  apparent size. Shape shows axial ratio, orientation shows tilt, and a
  globally coherent animated bead shows instantaneous field position.
- Glyphs are unfilled white extruded rings with minimum edge-on thickness;
  they remain fixed in their physical tangent planes rather than turning
  toward the camera.
- Back-side glyphs are naturally occluded by the opaque pattern surface.
- Animation plays by default and provides pause, phase, and speed controls.
- Click selection interpolates the exact selected direction rather than
  choosing the nearest displayed glyph.
- The compact inspector initially reports axial ratio, tilt, and sense.
- Handedness follows operator-facing AMSAT usage: the observer is behind the
  antenna looking outward along propagation.  A propagation arrow and animated
  rotation cue accompany RHCP/LHCP labels.
- Near-field ellipses show the complete Cartesian electric-field trajectory.
  Glyph brightness remains independent of the power background.  Power
  magnitude and signed normal power are selectable background quantities.
- Current, charge, field-vector, and polarization animation should eventually
  share one RF-cycle phase clock.

## Reference cases

- `examples/dipole.rkt`: existing linear-polarization baseline.
- `examples/circular-dipoles.rkt`: crossed dipoles driven in quadrature.
- `examples/helix.rkt`: end-fire helix, expected to be RHCP in its forward
  direction but treated as an observational check until Milestone 1 verifies
  the convention.
- Exact synthetic linear, RHCP, LHCP, and elliptical phasors provide the
  authoritative mathematical tests.

## Milestone protocol

Before development, every milestone receives a short implementation plan
covering affected files, experimental API, automated tests, and manual user
checks.  After implementation, automated results and a manual acceptance
checklist are delivered to the user.  Revisions remain within that milestone.
Only an explicitly approved milestone is committed and pushed.

## Milestones

### M0 — Branch, plan, and reference models

Create the feature branch, record this plan, add the crossed-dipole and helix
reference examples, identify the linear fixture, and establish compilation and
full-suite baselines.  Existing production viewers must remain unchanged.

### M1 — Polarization mathematics and convention

Add backend-neutral Stokes parameters, signed circularity, axial ratio, tilt,
handedness, and circular-component decomposition.  Synthetic tests must cover
exact linear, opposite circular, and known elliptical states; component powers
must close to total transverse power.  Verify the AMSAT-facing convention
against the real crossed-dipole and helix models without forcing the helix's
expected answer.

### M2 — Isolated native OpenGL PoC shell

Build a standalone experimental viewer with a persistent right-side control
rail, existing camera behavior, ARRL gain geometry, exact selection, and phase
controls.  Candidate entry points are
`show-polarization-surface-poc` and
`show-near-field-polarization-poc`.  Record performance on the primary
workstation; Yoga 11e results are informative but not a release gate.

### M3 — Signed-circularity surface

Color one opaque total-gain surface by signed circularity.  Linear,
elliptical, LHCP, and RHCP regions must remain visible and distinct.  Depth
testing occludes back-side content, and the legend must state the propagation
viewpoint convention.

### M4 — Surface metric experiment

Retain the frozen M3 circularity ramp and add an experimental selectable axial
ratio surface mode for locating near-circular regions. Compare an optional
low-gain threshold against mapping the complete finite minimum-to-maximum gain
range. Settle axial-ratio coloration and the persistent inspector by human
review. Signed circularity remains the default surface mode.

### M5 — Static far-field ellipse glyphs

Place fixed-scale tangent ellipses on stable angular samples.  Density choices
must be multiples of the underlying pattern steps and must include available
axial and cardinal directions.  Lines, circles, axis ratios, and tilt must
match exact fixtures.  Screen-space outlines and minimum edge-on thickness
must preserve readability over all surface colors. During iterative review,
M5 expanded to settle the final unfilled ring, animated bead, globally
coherent phase, playback controls, surface-area-aware density, and
curvature-aware clearance.

### M6 — Animated knob glyph and inspector

Subsumed by M5. Iteration on the static glyphs naturally required the animated
motion cue to judge their value. Human review selected an unfilled white ring
with a spherical endpoint bead, one global RF phase, automatic playback,
pause, scrub, and speed controls. Circular states rotate, elliptical states
follow an oval path, and linear states oscillate. No separate M6 development
cycle or commit is required.

### M7 — Far-field PoC UX approval

Consolidate the signed surface, glyphs, animation, exact selection, and compact
inspector.  The view must communicate polarization to a learner without first
requiring complex-component terminology. Glyph-only controls are visibly
inactive while the optional overlay is off; toggling or changing the overlay
must preserve camera, phase, and exact selection. Milestone labels and
experimental terminology are removed from the interface. Automated tests and
manual review cover the linear dipole, quadrature crossed dipoles, and helix.
User approval freezes the native far-field UX before production integration.

### M8 — Near-field selected-point ellipse

Animate the full Cartesian complex electric-field ellipse at an exactly
selected near-field point without assuming a transverse plane wave.  Exact
synthetic phasors validate linear, circular, elliptical, arbitrarily tilted,
and longitudinal behavior. Complex Cartesian components are interpolated
before analysis. The glyph is diagrammatic while its inspector reports
physical field amplitudes.

### M9 — Near-field ellipse plane

Switch exclusively between the M8 selected-point/vector view and a stable
sparse glyph grid on a near-field plane. Density lands on
actual samples and defaults to roughly 10–15 glyphs across the shorter plane
dimension. M4 review rejected adjustable threshold controls as confusing, so
M9 keeps glyph visibility independent of background power and exposes only an
on/off control plus sample-quantized density. The selected-point ellipse and
the plane glyphs share one globally coherent RF phase.

### M10 — Power backgrounds and spin mode

Provide selectable average Poynting magnitude and signed normal-power
backgrounds, plus `ELLIPSES`, `SPIN`, and `VECTOR` overlays.  Average-power
vectors communicate direction independently of magnitude.  Synthetic linear
fields have zero spin and opposite circular states reverse it.  Human review
determines whether spin remains prominent or becomes advanced.

### M11 — Near-field PoC UX approval

Consolidate the near-field modes and approve defaults, control organization,
density, animation, and terminology.  The view must distinguish field motion,
stored/reactive fields, and transported power without conflating them.

### M12 — Existing native GUI integration

Integrate the approved PoCs with existing OpenGL viewers while preserving
public compatibility and all ordinary visualization modes.  Share the RF
phase clock with current/charge/power animation where applicable.

### M13 — Portable HTML integration

Reproduce the approved native UX in offline NEC2C/OpenEMS reports.  Native and
HTML numerical results must agree, and report interaction must remain
responsive without a server.

### M14 — Documentation, performance, and merge

Document the APIs and all three reference models, run the full suite and manual
acceptance checklist, record primary-workstation performance and optional Yoga
11e observations, obtain final approval, and merge the feature branch.  The
accepted milestone commits may be squashed for the final merge.

## Explicitly out of scope

- Transparent or X-ray radiation patterns.
- Separate default RHCP and LHCP pattern surfaces.
- A global horizontal/vertical basis over the radiation sphere.
- A Poincaré-sphere view in the initial feature.
- Pixel-perfect OpenGL screenshot tests.
- HTML-first PoC development.
- Yoga 11e performance as a release criterion.
