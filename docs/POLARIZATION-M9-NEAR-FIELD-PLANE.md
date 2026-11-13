# Polarization Workbench M9 Near-Field Ellipse Plane

## Goal

Extend the approved M8 selected-point view with an alternate plane-wide set of
small polarization ellipses. The grid should make spatial changes in field
motion visible without competing visually with the exact selected-point
trajectory and vectors or obscuring the magnitude heatmap.

## Experimental UX

- `VIEW` switches exclusively between `SINGLE POINT + VECTORS` and
  `ELLIPSE GRID`; the single-point view remains the default.
- Grid view hides the selected trajectory, marker, origin guide, and both
  Poynting arrows. Switching back restores the retained selection.
- Grid glyph centers land only on captured near-field samples.
- The default sample stride produces roughly 10–15 glyphs across the shorter
  plane dimension. A sample-quantized density slider explores sparser and
  denser layouts without allowing glyphs to drift between samples.
- There is no magnitude-threshold control. M4 review found thresholds
  confusing; zero fields are omitted naturally, while all defined ellipses
  remain independent of heatmap brightness and transported power.
- Each glyph is an unfilled white ellipse in its physical 3D E-field plane.
  A white bead shares the selected-point RF phase and follows the local field
  trajectory.
- The approved M8 selected-point trajectory and Poynting arrows remain
  available in point view. The heatmap, model, orbit, zoom, phase, playback,
  and inspector remain shared context in both views.

## Automated acceptance

1. Sample-stride selection is deterministic and returns only source samples.
2. The default stride yields approximately 10–15 positions across the shorter
   dimension for the 101 × 101 reference captures.
3. Boundary and center samples remain represented where the stride permits.
4. Zero fields produce no invented glyph.
5. Plane glyph beads use the same global phase convention as the selected
   point bead.
6. The focused GUI test and complete suite remain green.

## Manual acceptance

1. Switch views on the crossed dipoles and helix without changing the
   current camera, selection, phase, or playback state.
2. Confirm point graphics and grid glyphs are never displayed together, and
   the retained point selection reappears when switching back.
3. Confirm the grid remains anchored while orbiting and while changing density.
4. Confirm grid beads retain the same phase when switching between views.
5. Verify the grid reveals spatial polarization changes without making the
   heatmap or antenna unreadable.
6. Decide whether the default point view, glyph size, density range, and white
   ring/bead language should be frozen for M11 consolidation.
