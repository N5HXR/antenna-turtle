# Polarization Workbench M2 PoC

M2 establishes an isolated native OpenGL shell before polarization color and
glyph experiments begin.  It intentionally leaves the production radiation
viewer unchanged.

## Experimental entry point

```racket
(show-polarization-surface-poc pattern)
```

Optional keywords are `#:width`, `#:height`, and `#:mesh-step`.  The two M0
fixtures, `examples/circular-dipoles.rkt` and `examples/helix.rkt`, launch this
viewer directly during the feature-branch experiments.

## Implemented shell behavior

- Opaque total-gain surface using the existing magma palette and ARRL radial
  scale.
- Existing drag-to-orbit and wheel-to-zoom interaction.
- Persistent right-side control rail.
- Automatic RF-cycle playback, pause/play, exact phase scrub, and 0.10x--4x
  speed control.
- Click selection traced against the displayed triangle surface.  The exact
  hit direction is converted to continuous azimuth/elevation and passed to
  the ordinary interpolating measurement API rather than snapped to a mesh
  vertex.
- White selection marker and a compact numerical preview of gain, sense,
  axial ratio, and tilt.  These numbers exercise the M1 backend; their final
  M4 inspector presentation is not frozen by M2.

## Automated coverage

- Cardinal, axial, and arbitrary surface-point conversion to the public
  azimuth/elevation convention.
- Phase rate, speed multiplier, and wraparound.
- A camera ray intersecting a synthetic radial triangle surface at a known
  exact direction.
- Public entry-point availability and keyword surface.

## Development-machine observations

Headless Xvfb with Mesa software OpenGL was used so the window and selection
path could be exercised inside the development sandbox.  Time from process
start through NEC2C simulation to discovery of the ready PoC window was about
2.67 seconds for the helix and 2.17 seconds for the crossed dipoles.  Resident
process sizes were approximately 556 MB and 641 MB respectively.  These are
software-rendering measurements, not representative GPU performance targets.

## Manual acceptance checklist

1. Run both reference examples and confirm the PoC opens beside the ordinary
   geometry window.
2. Drag and zoom; confirm the surface follows the established viewer feel.
3. Click the front, shoulder, and a small rear lobe; confirm the white marker
   lands under the pointer and the rail updates without overlap.
4. Confirm the helix front reports RHCP and its reverse direction reports
   LHCP.
5. Pause, scrub phase, resume, and change speed.  Confirm playback resumes
   smoothly from the displayed phase.
6. Resize the window and confirm the rail remains persistent while the OpenGL
   viewport takes the remaining space.
