# Polarization Workbench M7 Far-Field UX Approval

## Goal

Consolidate the approved far-field experiments into one coherent pedagogical
viewer. M7 introduces no new visualization metaphor. It removes experimental
language, makes control relevance obvious, and verifies that the surface,
optional glyphs, animation, exact selection, and numerical inspector behave as
one feature.

M6 is recorded as subsumed by M5 because the animated ring-and-bead treatment
was selected while iterating on the glyph design.

## Frozen defaults

- ARRL-scaled total-gain geometry is opaque.
- Signed circularity is the default surface metric; axial ratio remains
  selectable.
- The accepted pink / green / blue polarization ramp and gain-derived
  brightness are unchanged.
- Polarization glyphs default to off. When enabled, animation is already
  playing at 1.00x using the current global phase.
- Clicking the surface selects an exact direction. Clicking black background
  clears it.

## Consolidation changes

- Glyph spacing, phase, playback, and speed controls remain visible but are
  disabled while glyphs are hidden, making their scope unambiguous.
- Enabling, disabling, or changing glyph density preserves the selected
  direction, its white marker, the camera, and global RF phase.
- Deep-null glyphs are omitted when a fixed-size ring cannot remain attached
  to its local surface. The clearance bound scales with local lobe radius so
  broad lobes retain coverage while nulls do not grow detached orphans.
- Switching the surface metric recolors identical geometry without clearing
  the selected direction.
- Replacing the underlying simulation grid clears selection because the old
  direction and marker no longer necessarily describe the displayed data.
- The inspector uses operator-facing labels: total gain, relative gain,
  polarization, axial ratio, and tilt angle.
- Milestone numbers and experimental implementation terminology are absent
  from the user interface.

## Automated acceptance

1. Existing polarization mathematics, palette, brightness, glyph geometry,
   sampling, animation, and exact-angle tests remain green.
2. The isolated native PoC opens with signed circularity selected and glyphs
   disabled.
3. Recolor and overlay scene-update paths preserve selection, while a new-grid
   update clears it.
4. The complete Antenna Turtle test suite remains green.

## Manual acceptance

1. Linear dipole: the default surface communicates linear polarization; when
   enabled, glyphs are blade-like and beads oscillate rather than circulate.
2. Crossed dipoles: circular regions show round rings and coherent rotation;
   transition regions show elliptical and linear trajectories.
3. Helix: the forward lobe shows the expected circular sense, while rear and
   side lobes expose mixed polarization without obscuring gain geometry.
4. Toggle glyphs, change density, change surface metric, pause, scrub, and
   change speed. Camera, phase, and selected direction remain stable where
   specified.
5. Background clicks clear the marker and inspector. Surface clicks restore
   exact gain, relative gain, sense, axial ratio, and tilt information.
6. Orbit and zoom remain responsive at the densest useful glyph setting on
   the primary workstation.
7. The complete view can be explained in operator language without introducing
   Jones vectors, complex components, or Stokes parameters.
