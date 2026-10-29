# NEC2C wire lumped-element acceptance tests

These checks exercise both the Antenna Turtle geometry transformation and the
NEC2C load itself.  They require an installed `nec2c`; the integration test is
skipped automatically when it is unavailable.

## 1. Automated regression and solver smoke test

From the repository root, run:

```sh
TMPDIR=/tmp raco test tests/nec2c-lumped-test.rkt
```

Expected result: `7 tests passed`.  This verifies parallel and series LD-card
selection, gap construction, tolerance matching, invalid-corner rejection,
reflection, plot markers, model reset, and an actual NEC2C impedance run.

## 2. Inspect the generated NEC deck

Run the fixture in Emacs, DrRacket, or a REPL, then evaluate:

```racket
(export-nec2c "/tmp/lumped-wire.nec")
```

The deck should contain three `GW` cards.  The first two are the original wire
halves shortened by half of the requested gap.  The third is a one-segment
bridge spanning the gap.  There should be exactly one load card of this form:

```text
LD 1 <bridge-tag> 1 1 <R> <L> <C>
```

Change `topology parallel` to `topology series`; re-export and confirm the
first number after `LD` changes from `1` to `0`.

## 3. Confirm a strong electrical effect

Run:

```sh
TMPDIR=/tmp racket examples/nec2c-lumped-wire.rkt
```

The fixture compares an unloaded wire with the same wire containing a parallel
LC resonator near 30 MHz.  Both runs should finish, and the reported loaded
impedance should differ conspicuously from the unloaded impedance.  Exact
values may vary slightly with NEC2C version; equality or a tiny numerical-only
difference is a failure.

## 4. Confirm inline turtle placement

In the example, move the `lumped-element` form from between the two `move`
forms to either end of the wire and export or simulate again.  Antenna Turtle
should reject it with a message saying that a degree-two wire vertex is
required.  Put it back between the moves and the run should succeed.

Next, turn the turtle between the element and the second move:

```racket
(lumped-element forward resistance 50 gap 0.02)
(turn left 90)
(move forward 1)
```

Export should reject this with a message requiring collinear wires.  The
rejection prevents a component direction from being guessed at a corner.

## 5. Confirm independently placed tolerance matching

Build the two adjoining wire sections first, lift the pen, and place the
declaration close to their shared vertex:

```racket
(snap-length 0.001)
(goto (point3 1.0005 0 0))
(lumped-element forward resistance 50 gap 0.02)
```

The export should succeed.  Move the marker beyond the configured tolerance,
for example to `1.002`, and it should fail with `must resolve to exactly one
wire vertex`.  This confirms that independent placement repairs only small
coordinate drift and does not silently attach a load to a distant wire.

## 6. Optional trap-dipole acceptance

Use the same inline form twice, once in each arm of a center-fed dipole, with
parallel LC values chosen for the desired upper-band trap frequency.  Compare
a sweep with and without the two declarations.  Expected observations are:

- a pronounced impedance feature near the parallel-resonant frequency;
- an upper-band current distribution concentrated inside the traps;
- a lower-frequency response dominated by the complete wire length; and
- no topology or placement error when each trap occupies a straight,
  degree-two vertex.

This is the useful physical acceptance test, while the preceding checks make
failures easier to localize.
