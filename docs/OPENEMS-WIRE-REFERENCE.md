# OpenEMS wire-reference profile

`wire-reference` is an opt-in OpenEMS simulation profile for small wire-model
validation articles. It is deliberately not the normal backend for large or
complicated wire antennas; NEC2C remains the routine solver for electrically
thin wire structures.

The profile exists for cases where an independently resolved FDTD article is
worth a long run: solver cross-checks, NEC2C algorithm development, and small
wire structures interacting with geometry that NEC2C cannot represent.

## Numerical policy

The ordinary OpenEMS conversion turns Turtle wire edges into a finite capsule
union. `wire-reference` additionally:

- requests six mesh cells across each wire diameter;
- keeps that pitch through a six-radius air halo around each centerline;
- adds longitudinal fine neighborhoods around feeds, endpoints, junctions,
  and bends;
- retains wavelength-scale cells along an otherwise straight wire run; and
- resolves the full Cartesian projection of oblique edges for stair-stepping.

The last rule is intrinsically expensive. A Cartesian mesh plane extends
through the complete simulation domain, so refinements introduced by unrelated
segments multiply rather than remaining spatially local.

The profile does not automatically run a convergence sequence. A future
solver-neutral convergence facility is recorded in `TODO.org`.

## Always dry-run first

Use the same simulation form with `dry-run #t`:

```racket
(define estimate
  (simulate engine openems
            sweep '(400 470)
            profile wire-reference
            dry-run #t
            progress #f
            keep-artifacts #f))
```

The dry run invokes Octave and the exact `SmoothMeshLines` construction used by
the generated driver, writes the mesh coordinates, and exits before creating
an FDTD operator. The returned `openems-dry-run` value reports:

- line counts on X, Y, and Z;
- total OpenEMS cell count;
- minimum cell spacing;
- a broad 96--256 byte/cell memory range; and
- warnings for large meshes or an inapplicable wire profile.

The memory range is a planning heuristic, not an allocation promise. PML,
materials, probes, field dumps, and operator compression all affect actual
memory. Cell count is also not a runtime estimate: the finest cell controls
the Courant timestep, while the RF frequency and requested bandwidth control
the excitation duration. A low-frequency thin-wire article can therefore run
far longer than a microwave model with the same cell count.

Remove `dry-run #t` to perform the simulation after reviewing the estimate.

## Initial evidence

A 0.47-wavelength, 3 mm diameter free-space dipole at 432 MHz produced:

| Representation | Impedance at 432 MHz |
| --- | ---: |
| NEC2C thin wire | 73.09 + j2.89 ohms |
| Previous OpenEMS capsule mesh | 104.01 + j75.50 ohms |
| Hand-built 1.0 mm resolved cylinder | 76.96 + j38.98 ohms |
| Hand-built 0.5 mm resolved cylinder | 73.96 + j15.84 ohms |
| Initial production `wire-reference` capsule | 76.88 + j16.36 ohms |

The initial production reference mesh contained about 1.35 million cells. Its
sampled resonance was 422.74 MHz at 71.00 ohms. The finalized feed-neighborhood
policy raises the estimate to 1.64 million cells and anchors refinement at the
physical feed faces so it does not create sub-pitch sliver cells. This is not
a claim that one FDTD mesh must duplicate NEC2C; it demonstrates that the
large original discrepancy was primarily an under-resolved Cartesian wire
representation.

Representative dry-run estimates on the development machine were:

| Article | Cells | Heuristic memory |
| --- | ---: | ---: |
| Dipole | 1.64 million | 150--401 MiB |
| Three-element Yagi | 5.48 million | 502--1339 MiB |
| Cebik-dimensioned Moxon | 5.37 million | 492--1311 MiB |

The Yagi and Moxon estimates also trigger the fine-timestep warning: their
shortest free-space wavelength spans about 1,930 and 8,403 minimum cells,
respectively. They validate straight multi-element and bent geometry handling,
but their completed FDTD solves are intentionally not routine test-suite work.

## Intended validation articles

- A free-space center-fed dipole establishes resonance and terminal impedance.
- The three-element 146 MHz design from `examples/yagi-compare.rkt` adds
  multiple nearby straight conductors and a directional pattern.
- The 29 MHz Cebik-dimensioned Moxon adds right-angle bends and closely spaced
  open ends.

These are opt-in validation runs, not routine unit tests. A helix is excluded:
its many oblique segments exercise the worst-case Cartesian mesh product and
does not add a necessary acceptance dimension for this feature.

## Physical calibration protocol

Cross-solver agreement cannot establish which model represents a physical
antenna. Use the free-space dipole as the first bench article before spending
time on the Yagi or Moxon:

1. Record the finished tip-to-tip length, conductor diameter, feed-gap width,
   connector geometry, and any support material.
2. Measure a VNA sweep wide enough to contain resonance. Move the calibration
   reference plane to the feed, or record the feed-line fixture well enough to
   de-embed it.
3. Reproduce the measured dimensions and feed gap in both solver fixtures;
   do not tune either model independently to the measurement.
4. Compare resonant frequency and complex feed impedance at the same sampled
   frequencies. Retain the Touchstone data and the exact model revision.
5. Run one finer OpenEMS mesh only if the first `wire-reference` result and the
   measurement disagree materially. A change toward the measured result is
   evidence of mesh error; a stable offset points instead toward the feed,
   capsule geometry, material assumptions, or the measurement fixture.

The initial acceptance target is diagnostic rather than a promised tolerance:
the comparison must identify whether the remaining OpenEMS reactance is
converging, feed-model dependent, or physically present. Pattern or gain
measurements can follow only if the terminal comparison justifies the larger
Yagi and Moxon runs.

## Interpretation and limits

- A dry run predicts cost, not accuracy.
- Its cell count and memory range do not predict FDTD wall time.
- One completed mesh does not establish convergence.
- Capsule end geometry and feed-gap conventions can shift resonance.
- Oblique, curved, dense, or very large wire models may be impractical even
  when the dry run succeeds.
- Use NEC2C for routine wire design unless the OpenEMS reference answers a
  specific validation question.
