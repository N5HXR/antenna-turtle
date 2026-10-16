# OpenEMS verification sketches

These examples are small electromagnetic fixtures with textbook predictions,
physical invariants, or deliberately simple regression observations. They are
intended to be run and tuned one at a time while the OpenEMS solid backend is
being validated.

Each numbered file constructs its model when loaded. Its interactive viewer,
simulation, measurement extraction, and provisional checks live in
`module+ main`, so compiling the directory does not launch long solver runs.
Run one directly with, for example:

```sh
racket examples/verification/00-matched-microstrip.rkt
```

`PASS` means the observation lies within the current provisional tolerance.
`CHECK` is deliberately nonfatal: inspect the model and mesh, establish
convergence, and decide whether the model, analytic estimate, or tolerance
needs adjustment. Do not turn an unconverged result into a golden value.

| File | Primary observation |
|---|---|
| `00-matched-microstrip.rkt` | Approximately 50-ohm characteristic impedance, match, reciprocity |
| `01-line-length-phase.rkt` | Differential phase delay and length-independent impedance |
| `02-quarter-wave-transformer.rkt` | 70.7-ohm quarter-wave section transforms 100 ohms toward 50 ohms |
| `03-half-wave-repeater.rkt` | Guided half-wave line repeats a 75-ohm load |
| `04-lumped-resistor.rkt` | 50-ohm dummy load and lumped-resistor power absorption |
| `05-series-rlc.rkt` | Analytic 1 GHz series resonance and reciprocity |
| `06-parallel-plate-capacitor.rkt` | `C = epsilon*A/d`, with expected fringing error |
| `07-open-stub-notch.rkt` | Quarter-wave open shunt stub produces a notch |
| `08-half-wave-resonator.rkt` | Capacitively coupled open-open resonator pass peak |
| `09-ring-resonator.rkt` | One-guided-wavelength ring produces a coupled notch |
| `10-free-space-dipole.rkt` | Resonance and approximately 2.15 dBi peak directivity |
| `11-small-loop.rkt` | Approximately 1.76 dBi normalized peak directivity |
| `12-lossy-line.rkt` | FR4/copper has more loss than ideal materials; inspect power budget |
| `13-pec-cavity.rkt` | Rectangular-cavity TE101 resonance |
| `14-pi-attenuator.rkt` | Matched, reciprocal 6 dB resistor pi attenuator |

The line and distributed-resonator dimensions use first-pass effective-
permittivity estimates. Their initial tolerances are intentionally wider than
the lumped and closed-form fixtures. A useful workflow for each example is:

1. inspect the solid model and generated CSXCAD mesh;
2. run `draft`, `standard`, and then a deliberately finer profile;
3. verify that the result converges rather than merely crossing a tolerance;
4. compare complex values and phase, not only plotted magnitude;
5. record the OpenEMS version and the converged observation before tightening
   the check.

`common.rkt` contains only reporting and frequency-selection helpers. It does
not hide model construction or throw test failures, keeping every numbered
file useful as an editable teaching example.
