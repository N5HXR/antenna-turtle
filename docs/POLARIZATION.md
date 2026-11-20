# Polarization

Antenna Turtle can inspect polarization numerically, in native OpenGL
workbenches, and in portable NEC2C HTML reports. The native views prioritize
teaching and physical intuition; the numerical inspector remains available for
engineering checks.

## Convention

The observer stands behind the antenna and looks outward along propagation.
Clockwise electric-field rotation is RHCP and counterclockwise rotation is
LHCP. Complex fields use `Re(E exp(j omega t))`. The exact Stokes definitions,
circular basis, and AMSAT-facing terminology are recorded in
[`POLARIZATION-CONVENTION.md`](POLARIZATION-CONVENTION.md).

Handedness is direction-dependent. Looking back toward an antenna reverses the
visual sense, so every viewer labels the observation direction or plane normal.
Near an antenna, the electric trajectory need not be transverse to either the
instantaneous or average Poynting vector. That non-plane-wave behavior is
physical and normally resolves toward the far field.

## Far-field workbench

```racket
(define pattern
  (nec2c-radiation-grid #:theta-step 5 #:phi-step 5))
(show-radiation-pattern-opengl pattern #:view 'polarization)
```

The surface radius follows total gain using the ARRL modified-log scale. Color
can represent:

- signed circularity, from LHCP through linear to RHCP;
- axial ratio, scaled from the best to worst value in the pattern; or
- axial tilt, with a cyclic orientation ramp.

Click a surface direction to inspect its complex fields, gain, axial ratio,
tilt, and sense. Click the black background to clear the white selection pip.
Optional constant-size white ellipse glyphs show the local electric trajectory;
a bead moves around each ellipse on the global RF phase clock. Glyphs are off
by default and their angular density is adjustable.

## Numerical queries

```racket
(polarization-at pattern #:azimuth 0 #:elevation 90)
(axial-ratio-at pattern #:azimuth 0 #:elevation 90)
(polarization-tilt-at pattern #:azimuth 0 #:elevation 90)
(polarization-sense-at pattern #:azimuth 0 #:elevation 90)
```

`polarization-at` interpolates the complex Jones components before deriving
nonlinear values. It never interpolates a category, wrapped angle, or axial
ratio directly. Use `#:interpolate? #f` when the requested direction must be an
exact solver sample.

## Near-field workbench

Capture complex electric and magnetic fields on one or more planes, then open
the production near-field dispatcher:

```racket
(define fields
  (nec2c-near-field-planes
   #:planes
   (list
    (near-field-section #:plane 'xy
                        #:position {1/2 * wavelength}
                        #:samples '(101 101)))))

(show-near-field fields #:view 'polarization)
```

The workbench has two mutually exclusive presentations:

- **POINT** shows one complete 3-D electric-field trajectory, a faint line from
  the RF origin, and both average and animated instantaneous Poynting vectors.
- **GRID** shows stable, plane-wide ellipse glyphs so spatial changes in
  polarization are readable without the selected-point overlay.

The background can show electric magnitude, average power magnitude, or signed
normal power. Additional static grid modes show normalized electric spin and
average power vectors. Static modes suspend the RF animation loop. The geometry
overlay uses actual wire endpoints and the plane uses a smooth, translucent
heatmap. Orbit, wheel zoom, phase, animation speed, glyph density, and geometry
visibility remain interactive.

An ellipse is the locus of the electric vector over one complete RF cycle. It
is not a time average. The average Poynting vector is the cycle average of
`E(t) x H(t)`; it can therefore be oblique to the electric ellipse in a reactive
near field. The animated instantaneous vector exposes that motion directly.

## Portable NEC2C reports

Pass a radiation grid and optional near-field sections to a NEC2C report:

```racket
(write-nec2c-html-report sweep "turnstile.html"
                         #:pattern pattern
                         #:near-fields fields)
```

The offline report adds signed-circularity, axial-ratio, and axial-tilt modes to
the existing 3-D radiation workspace. Its near-field workspace adds signed
circularity and axial tilt to the existing E, H, and power maps. The HTML views
reuse the same complex fields and conventions as the native viewers, but omit
animated ellipse, halo, spin, and power-vector glyphs.

## OpenEMS status

OpenEMS report polarization is intentionally deferred. The browser mathematics
can consume complex OpenEMS field captures, but wire geometry, feed behavior,
accepted power, and radiated-pattern parity with NEC2C must be established on a
reference antenna before those controls can present a trustworthy result.
Ordinary OpenEMS E, H, and power report views are unaffected.

## Reference models

- [`examples/dipole.rkt`](../examples/dipole.rkt) is the linear-polarization
  baseline.
- [`examples/circular-dipoles.rkt`](../examples/circular-dipoles.rkt) is the
  crossed-dipole quadrature reference.
- [`examples/helix.rkt`](../examples/helix.rkt) is the end-fire reference and
  includes both far- and near-field native workbenches.
