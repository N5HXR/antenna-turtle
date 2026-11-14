# Polarization Workbench M12 Native Integration Plan

## Goal

Promote the approved far-field and near-field workbenches into Antenna
Turtle's native visualization API without changing the behavior of existing
programs.  M12 integrates the native viewers only; portable HTML reports
remain M13 work.

## Public API contract

### Far field

Extend the existing accelerated viewer with an explicit view selector:

```racket
(show-radiation-pattern-opengl pattern #:view 'gain)
(show-radiation-pattern-opengl pattern #:view 'polarization)
```

- `#:view` accepts `'gain` and `'polarization`.
- `'gain` is the default and preserves the current viewer, keyword defaults,
  palette behavior, legend, camera, update handle, and restaging behavior.
- `'polarization` opens the approved M3--M7 workbench and retains its signed
  circularity default, axial-ratio surface option, exact inspector, optional
  glyphs, and phase controls.
- Gain-only styling keywords remain accepted for source compatibility.  The
  polarization view uses its frozen ARRL geometry and polarization colors;
  documentation will state which styling keywords are not visually relevant
  in that view.

### Near field

Establish one extensible native entry point and promote the approved M8--M11
workbench as its first view:

```racket
(show-near-field fields #:view 'polarization #:section 0)
```

- `#:view` is required so a sketch states which interpretation of the captured
  near-field dataset it wants.
- M12 initially promotes `'polarization`, retaining the approved `|E|`,
  `|Pavg|`, signed-normal-power, point, ellipses, spin, and power-vector modes.
- The dispatcher and its validation are deliberately open to additive view
  symbols.  Native electric-field, magnetic-field, power, vector-field,
  field-line, Poynting-vector, and volume views can therefore join this API as
  they are ported from the HTML report rather than becoming unrelated top-level
  functions.
- The existing `show-near-field-polarization-point-poc` binding remains as a
  compatibility alias during this feature branch.
- The existing experimental Poynting-particle entry point remains compatible;
  folding it and the broader HTML near-field repertoire into the general
  dispatcher is follow-on near-field work rather than silently expanding this
  integration milestone.

### Compatibility

- Existing calls to `show-radiation-pattern-opengl` are byte-for-byte source
  compatible and continue to select the ordinary gain viewer.
- Existing PoC calls continue to compile and run.
- Both production entry points return ordinary visualization handles and
  support show, close, open-state inspection, and data update where the
  underlying approved workbench supports it.

## RF phase clock

Extract the common RF-cycle phase arithmetic used by the far- and near-field
workbenches into one internal helper.  Both viewers keep one globally coherent
phase within their own window, advance at the same default rate, and reset
elapsed wall-clock time when playback resumes so a pause or static mode cannot
cause a phase jump.  Independent windows are not synchronized to one another
in M12.

## Expected files

- `antenna-turtle/private/nec2c-view.rkt`: public dispatch and promoted API.
- `antenna-turtle/private/nec2c-opengl-view.rkt`: deliberately unchanged; the
  ordinary native gain implementation remains the default dispatch target.
- `antenna-turtle/private/polarization-poc.rkt`: production far-field entry
  alias and shared phase helper adoption; the filename remains internal.
- `antenna-turtle/private/near-field-polarization-poc.rkt`: promoted
  polarization renderer and shared phase helper adoption; the filename remains
  internal until its implementation is moved beneath a general near-field
  view module.
- `antenna-turtle/private/nec2c-view.rkt`: general `show-near-field` dispatcher
  and public compatibility bindings.
- `antenna-turtle/private/rf-phase-clock.rkt`: backend-neutral phase math.
- Native-view tests and minimal-language API tests.

## Automated acceptance

1. The keyword contract for the ordinary OpenGL viewer is unchanged except
   for the additive `#:view` keyword, whose default is `'gain`.
2. Invalid view values fail with a precise argument error.
3. The ordinary gain path still opens, updates, restages, closes, and passes
   its existing tests.
4. The polarization dispatch opens and closes safely and accepts compatible
   pattern updates.
5. `show-near-field` requires `#:view`, accepts `'polarization`, rejects an
   unknown view precisely, and opens and closes safely; the legacy PoC name
   remains callable.
6. Shared phase-clock tests cover advance, wrap, pause/resume elapsed-time
   reset semantics, and invalid arguments.
7. The complete suite remains green.

## Human approval checklist

1. Existing `(show-radiation-pattern-opengl pattern)` still looks and behaves
   exactly like the familiar gain viewer.
2. `#:view 'polarization` opens the approved far-field workbench without PoC
   terminology.
3. `(show-near-field fields #:view 'polarization)` opens the approved M11
   workbench.
4. The dipole, crossed-dipole, and helix reference cases remain physically and
   visually consistent with their approved PoCs.
5. Pause/resume and static near-field modes do not jump phase or consume
   continuous render work.
6. Approve the native production API for M13 portable HTML integration.
