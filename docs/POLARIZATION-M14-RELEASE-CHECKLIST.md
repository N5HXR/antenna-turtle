# Polarization Workbench M14 Release Checklist

## Release scope

M14 closes the polarization feature with:

- backend-neutral polarization analysis and directional query primitives;
- native far-field signed-circularity, axial-ratio, and axial-tilt surfaces;
- optional far-field electric-trajectory glyphs;
- native near-field point, ellipse-grid, spin, and power-vector views;
- production `show-radiation-pattern-opengl` and `show-near-field` entry points;
- portable NEC2C far- and near-field polarization maps; and
- public convention, API, tutorial, and reference-model documentation.

OpenEMS report polarization is not part of this release. The bounded M13 audit
found that the browser calculations are reusable, but the tested wire antenna
did not establish trustworthy geometry/feed/accepted-power parity with NEC2C.
The ordinary OpenEMS E, H, and power report views remain in scope and unchanged.

## Public entry points

```racket
(polarization-at pattern #:azimuth az #:elevation el)
(axial-ratio-at pattern #:azimuth az #:elevation el)
(polarization-tilt-at pattern #:azimuth az #:elevation el)
(polarization-sense-at pattern #:azimuth az #:elevation el)

(show-radiation-pattern-opengl pattern #:view 'polarization)
(show-near-field fields #:view 'polarization)
```

The former PoC names remain compatibility aliases but are not used by the
reference examples or user documentation.

## Documentation inventory

- `POLARIZATION.md`: user workflow, controls, physical interpretation, report
  coverage, reference models, and OpenEMS deferral.
- `POLARIZATION-CONVENTION.md`: exact phasor, Stokes, circular-basis, and
  handedness definitions.
- `API.md`: complete query and viewer signatures.
- `USER-MANUAL.md` and `README.md`: discoverable production examples.
- `examples/dipole.rkt`: linear baseline.
- `examples/circular-dipoles.rkt`: crossed-dipole quadrature reference.
- `examples/helix.rkt`: end-fire far- and near-field reference.

## Performance record

Primary workstation used during iterative visual acceptance:

- Intel Core i9-13900K, 32 logical processors;
- Intel integrated display adapter and NVIDIA GeForce RTX 3060 Ti;
- 62.6 GiB RAM.

Human-in-the-loop acceptance established that orbit and zoom remain directly
responsive after input-event coalescing; far-field glyph density remains
usable on the helix and dipole cases; scrollable control panels fit the tested
desktop window; and static near-field spin/power modes suspend phase animation
and redraw work. The optional Yoga 11e envelope was not a release criterion and
was not rerun for M14.

On 2026-11-14 the JavaScript unit suite plus production bundle rebuild completed
in under one second on the primary workstation. The complete Racket test
directory, including the native GUI compatibility modules under a virtual
display, completed in about one minute with all 298 tests passing.

## Automated release checks

- [x] JavaScript polarization, field math, surface math, pattern data, and
  NEC2C report tests pass.
- [x] Portable report bundle rebuilds successfully.
- [x] Racket production modules and all three reference examples compile.
- [x] All non-GUI Racket tests pass, including NEC2C HTML and OpenEMS capture
  regressions.
- [x] GUI-only polarization PoC compatibility tests pass under a working X
  display.
- [x] Scoped whitespace/diff audit is clean after the final test rerun.

## Final human approval

- [x] Linear dipole, crossed dipole, and helix tell the expected polarization
  story in the approved native views.
- [x] Far-field surface, inspector, clearing behavior, optional glyphs, and
  gain-derived brightness are accepted.
- [x] Near-field point/grid switching, heatmap, geometry, electric ellipse,
  average and instantaneous Poynting, spin, and power-vector views are accepted.
- [x] NEC2C portable far-field and near-field polarization maps are accepted.
- [x] OpenEMS polarization is explicitly deferred rather than presented from
  an unvalidated wire model.
- [x] User approves M14 documentation and final branch merge.
