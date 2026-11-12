# Polarization Workbench M4 Surface Metrics

## Goal

Extend the isolated far-field PoC with selectable surface measurements while
retaining the M3 camera performance and frozen signed-circularity presentation.

## Experimental UI

- `SURFACE` selects `SIGNED CIRCULARITY` (the M3 default) or `AXIAL RATIO`.
- Axial-ratio mode emphasizes the most nearly circular regions and retains the
  exact ratio in the selected-direction inspector.
- The inspector persists independently of surface mode and reports direction,
  relative and absolute gain, sense, axial ratio, and tilt.

## Implementation boundary

The PoC continues to build one opaque ARRL-scaled total-gain surface. Surface
mode changes rebuild that cached surface; orbit and zoom only replace the
camera. No production viewer or public API is changed in M4.

## Experimental conclusion

The relative-gain threshold was implemented and evaluated, then removed. It
made the display harder to interpret without adding a useful working mode.
Both surface metrics therefore cover every finite sample. Gain-derived
brightness scales across the pattern's complete minimum-to-maximum range.

## Automated acceptance

1. Axial-ratio color mapping is bounded and assigns its strongest highlight to
   1:1 circular polarization.
2. Linear and unavailable polarization map to the weak/undefined end.
3. Both surface modes preserve M3 gain-derived brightness over the complete
   finite minimum-to-maximum gain range.
4. Existing M0-M3 tests and the full suite remain green.

## Manual acceptance

1. Switch between signed circularity and axial ratio without changing pattern
   geometry or camera orientation.
2. On the helix, locate the lowest axial-ratio region visually and verify its
   exact inspector value.
3. Confirm the default is signed circularity and the complete pattern remains
   colored in both modes.
4. Confirm orbit, zoom, selection, and background-click deselection remain
   responsive after repeated surface-mode changes.
