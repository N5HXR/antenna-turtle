# Polarization Workbench M10 Power Backgrounds and Spin

## Goal

Separate three related but distinct near-field questions: how the electric
field moves, where average energy is transported, and how much average power
crosses the capture plane.  Preserve the M8/M9 full Cartesian field treatment
and avoid implying that a reactive near field is a transverse plane wave.

## Experimental UX

- `BACKGROUND` selects `|E|`, `|PAVG|`, or signed plane-normal `PAVG`.
- `|E|` and `|PAVG|` use logarithmic magnitude color.  Signed normal power
  uses a zero-centered diverging map so inward and outward transport remain
  distinguishable.
- `VIEW` is exclusive: `POINT + VECTORS`, `ELLIPSES`, `SPIN`, or
  `POWER VECTORS`.  This carries forward the M9 decision not to stack dense
  overlays.
- `ELLIPSES` retains the M9 white rings and globally coherent phase beads.
- `SPIN` draws the normalized electric spin vector
  `Im(conjugate(E) × E) / (conjugate(E) · E)`.  Arrow direction reverses with
  handedness; length ranges from zero for linear motion to one for ideal
  circular motion. Luminous cyan keeps it distinct from the magma background.
- `POWER VECTORS` draws equal-length average-Poynting arrows.  Direction is
  deliberately independent of power magnitude, which remains a background
  concern.
- Grid density remains sample-quantized and shared by all three plane-wide
  views. Point selection is retained while another view is active.

## Automated acceptance

1. A linear complex electric field has zero normalized spin.
2. Ideal opposite circular fields have unit, opposite spin vectors.
3. Elliptical spin magnitude lies strictly between zero and one.
4. Average-power magnitude and signed-normal quantities are computed from the
   interpolated complex E and H fields.
5. Plane-normal sign follows the capture section's positive normal axis.
6. Existing M8/M9 behavior and the complete test suite remain green.

## Manual acceptance

1. Compare all backgrounds on the crossed dipoles and helix without changing
   camera, phase, playback, selection, or density.
2. Confirm signed normal power clearly distinguishes outward, inward, and
   near-zero regions.
3. Confirm power vectors communicate direction without becoming brighter or
   longer in high-power regions.
4. Confirm linear dipole spin is absent or negligible, while opposite circular
   states reverse spin direction.
5. Decide whether spin is useful enough for the ordinary control set or should
   become an advanced mode during M11 consolidation.
