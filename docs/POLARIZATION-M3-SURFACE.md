# Polarization Workbench M3 Signed-Circularity Surface

M3 retains the M2 ARRL total-gain radius and colors that one opaque surface by
signed circularity.  It does not create separate RHCP and LHCP surfaces and it
does not introduce transparency.

Brightness independently encodes total gain across the finite minimum-to-maximum
range in the pattern. The accepted exposure curve spans 0.1x at minimum gain
to 1.25x at maximum gain with exponent 1.2, clipping boosted RGB channels
safely at full intensity. This reveals gain structure without camera-dependent
lighting and remains invariant under camera orbit.

## Frozen M3 palette

- LHCP (`-1`) is pink-red: `(255, 32, 128)`.
- Linear (`0`) is yellow-green: `(128, 255, 32)`.
- RHCP (`+1`) is blue: `(32, 128, 255)`.
- Intermediate ellipticities use direct RGB interpolation between the three
  anchors.
- Missing or zero-field polarization is near-black.

Each anchor contains the same three channel levels in a different order. This
keeps the ramp vivid and avoids gray transitions. M4 retains this ramp and
settles weak-field and undefined treatment.

The rail states the antenna-facing convention: the observer is behind the
antenna looking outward along propagation, and clockwise electric-field
rotation is RHCP.

## Manual acceptance checklist

1. Run `examples/helix.rkt`.  Its forward main lobe should be strongly blue
   (RHCP), while the reverse lobe should be red (LHCP).
2. Orbit around the helix rear hemisphere and inspect whether handedness
   changes in weak-lobe structure remain visible without transparency.
3. Run `examples/circular-dipoles.rkt`.  Opposite hemispheres should show
   opposite circular sense with an intelligible transition between them.
4. Confirm the surface remains opaque and back-side regions are naturally
   hidden by depth testing.
5. Click representative red, green, blue, and transitional regions and verify
   that the inspector sense and axial ratio agree with the displayed color.
6. Confirm orbit, zoom, selection, and phase controls retain the accepted M2
   responsiveness.
7. Confirm reduced-gain creases and secondary lobes are darker than the main
   lobe, remain visible above the brightness floor, and do not change brightness
   merely because the camera orbits.
8. Click the black background after selecting a direction. Confirm the white
   pip disappears and the inspector returns to its unselected prompt.
