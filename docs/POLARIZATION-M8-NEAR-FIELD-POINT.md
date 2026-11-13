# Polarization Workbench M8 Near-Field Selected Point

## Goal

Animate the complete Cartesian electric-field trajectory at one exactly
selected point on a captured near-field plane. Unlike a far-field
polarization ellipse, this view must not assume that the electric field is
transverse to a propagation direction or to the displayed plane.

## Experimental API

`(show-near-field-polarization-point-poc result #:section 0)` opens the
isolated native PoC for one `nec2c-near-field-result` section. The plane is
selectable by exact click intersection. Complex Cartesian field components
are bilinearly interpolated at that physical `(u, v)` location before ellipse
analysis.

## Visual language

- A smooth, partially transparent magma surface shows electric-field magnitude
  from -30 dB to the plane p98 reference without hiding trajectory portions
  that pass behind the plane.
- The currently active antenna model is drawn as continuous cyan wire geometry,
  feeds are magenta, and a small translucent X/Y/Z triad supplies orientation.
  `#:antenna? #f` suppresses the model when a caller intentionally wants only
  field data.
- A subtle line connects the model origin to the selected point. A translucent
  orange arrow shows the normalized direction of the time-average Poynting
  vector `0.5 Re(E × H*)`. A bright yellow arrow animates the instantaneous
  `E(t) × H(t)` direction in phase with the field bead. The inspector reports
  the physical components and magnitude of both quantities.
- A white, fixed-display-size 3D trajectory is anchored at the selected
  point. Its plane and shape come directly from `(Ex, Ey, Ez)`. It is the fixed
  locus swept out by the single-frequency steady-state field over one cycle,
  not a time average; the bead selects the current point on that locus.
- A white bead follows the instantaneous field using the same global RF phase
  convention as the far-field workbench.
- The trajectory is diagrammatic; the inspector reports physical major and
  minor amplitudes in V/m and the resulting axial ratio.
- Orbit and zoom make out-of-plane and longitudinal motion visible.
- M8 intentionally has no plane-wide glyph grid, power background, spin mode,
  or field threshold; those belong to M9 and M10.

## Affected files

- `antenna-turtle/private/near-field-polarization.rkt`: Cartesian complex
  interpolation and 3D ellipse mathematics.
- `antenna-turtle/private/near-field-polarization-poc.rkt`: isolated native
  selected-point viewer.
- `antenna-turtle/private/nec2c-view.rkt`: experimental public wrapper.
- `tests/near-field-polarization-test.rkt`: exact mathematical fixtures and
  interpolation tests.

## Automated acceptance

1. Exact linear fields collapse to a line and oscillate through both ends.
2. Equal quadrature components produce a circle and reverse traversal when
   quadrature sign reverses.
3. Unequal quadrature components produce the expected axial ratio.
4. A rotated complex vector produces an ellipse in the correct arbitrary 3D
   plane, including a component normal to the capture plane.
5. Purely longitudinal fields remain visible rather than being projected
   away.
6. Zero fields report an undefined trajectory without NaNs or invented axes.
7. Bilinear interpolation is performed on complex Cartesian components before
   analysis.
8. The native PoC opens and closes, and the complete suite remains green.

## Manual acceptance

1. On the crossed-dipole reference, select several points on and away from the
   symmetry center and confirm linear, circular, and elliptical trajectories
   are legible while orbiting.
2. Confirm a trajectory tilted out of the capture plane retains its physical
   orientation rather than facing the camera.
3. Pause, scrub, resume, and change speed; the bead remains synchronized with
   the selected-point inspector phase.
4. Click a new point and confirm the trajectory moves to that exact physical
   location and the inspector updates continuously.
5. Click outside the plane to clear the selection.
