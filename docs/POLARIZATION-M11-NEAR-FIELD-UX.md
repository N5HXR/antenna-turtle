# Polarization Workbench M11 Near-Field UX Approval

## Goal

Consolidate the approved M8–M10 experiments into one coherent near-field
workbench before production integration.  M11 adds no new field quantity; it
removes experimental language, makes controls accurately describe the active
mode, and freezes the interaction contract for M12 and M13.

## Proposed frozen defaults

- Background: electric-field magnitude `|E|`.
- View: selected point trajectory and Poynting vectors.
- Playback: running at `1.00×`, phase globally coherent.
- Plane-grid density: approximately eleven samples across the shorter side.
- Point selection, camera, phase, playback, density, and background survive
  view changes.
- Dense views remain exclusive rather than stacking overlays.

## Consolidation work

- Replace the PoC window title with `Near-field polarization workbench`.
- Keep `BACKGROUND` before `VIEW`, because the background answers “how much?”
  while the view answers “what local motion or direction?”.
- Keep density enabled for all plane-wide views and disabled for point view.
- Enable RF phase, playback, and speed only for the animated point and ellipse
  views. Static spin and average-power vectors preserve animation state, make
  those controls visibly inactive, and stop the render timer until an animated
  view is selected again.
- Replace the point-only footer explanation with mode-specific pedagogy for
  point trajectory, ellipse field, normalized spin, and average power flow.
- Retain the compact numerical selected-point inspector in every view as the
  engineering-oriented layer.

## Automated acceptance

1. M8–M10 mathematical and GUI tests remain green.
2. Opening and closing the consolidated workbench remains safe.
3. No public production-viewer behavior changes before M12.
4. The complete suite remains green.

## Human approval checklist

1. Approve the default background, view, density, and automatic playback.
2. Approve the order and labels of `BACKGROUND`, `VIEW`, density, selection,
   and animation controls.
3. Confirm static modes clearly disable irrelevant animation controls, stop
   background animation work, and resume without losing their settings.
4. Confirm each mode's explanation distinguishes E-field motion, normalized
   polarization spin, and transported average power.
5. Decide whether `SPIN` remains in the ordinary view list or moves to an
   advanced control during production integration.
6. Approve the consolidated near-field UX for M12 native integration.
