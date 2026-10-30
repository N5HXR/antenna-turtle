# NEC2C Coaxial Feedline Design

Status: experimental revision 1 implemented on `exploratory/coax-feedline`.

## Purpose

Add a NEC2C coaxial-feedline abstraction that can predict measurements at a
remote coax input while retaining the radiating common-mode behavior of the
coax shield exterior.

The abstraction combines two different models:

1. a non-radiating, lossless NEC `TL` network for the differential TEM mode
   inside the coax; and
2. an explicit NEC wire for current on the outside of the shield.

The explicit wire participates in the electromagnetic solution and can carry
inline common-mode choke loads. The internal `TL` does not appear as geometry,
radiate, or couple directly to nearby objects.

## Initial scope

Revision 1 supports:

- ordinary wire-only NEC2C models;
- one or more named differential wire ports;
- one ideal coaxial `TL` per `coax` declaration;
- a turtle path representing the shield exterior;
- an excitation at the coax input measurement plane;
- lossless characteristic impedance and velocity factor;
- existing inline wire lumped elements on the exterior shield path;
- impedance, S11, VSWR, and radiation results at the coax input feed; and
- geometry and current visualization of the exterior shield and port markers.

Revision 1 does not support:

- `DF` dielectric-active NEC2C jobs, because NEC2C-N5HXR currently rejects
  `TL` and `NT` networks with dielectric volumes;
- distributed coax attenuation or frequency-dependent cable data;
- an explicit inner conductor or shield-interior geometry;
- automatic transformer, balun, unun, or matching-network synthesis;
- a claim that the source-end common-mode termination models a real radio,
  chassis, station ground, or operator; or
- OpenEMS export of the composite `coax` abstraction.

NEC2C-N5HXR 1.3.1 has one machine-result compatibility defect relevant here:
for an excitation on a `TL`/`NT` terminal, schema-v1 `feeds` contains the
network-contributed current rather than the total source current printed in
`ANTENNA INPUT PARAMETERS`. Antenna Turtle therefore substitutes that classic
source row only for its generated transmission-line models. Wire currents,
fields, power budgets, and other schema-covered data continue to come from
JSON. The compatibility path should be removed after the producer is fixed.

## Physical topology

At each end, NEC associates a network port with one wire segment. The segment
acts as a two-terminal differential port; its direction establishes polarity.

```text
input port segment                     antenna port segment
       + -------- ideal TL -------------------- + -- radiator
       -                                        - -- counterpoise
       |                                        |
       +--- explicit shield exterior wire ------+
                         |
                    optional choke
```

The `TL` represents the center conductor and shield-inner-surface differential
mode. The explicit wire represents the shield outer surface. Those paths join
at the two port fixtures but remain separate along the cable length.

For a direct coax feed, the shield-exterior wire is electrically joined to the
negative terminal of the antenna-side port. The positive terminal connects to
the radiator fed by the coax center conductor. A separate counterpoise may also
join the negative terminal, producing an ordinary three-way conductor junction
between the port fixture, counterpoise, and shield exterior.

This direct connection is not inferred through an isolated transformer or
balun. If a model places a transformer between the coax and antenna, the coax
output port terminates on the transformer's primary terminals and a separate
antenna port represents its secondary. Modeling that case requires an explicit
network between the two ports rather than connecting the shield exterior
directly to the secondary cold terminal.

## Low-level wire port

The proposed primitive is:

```racket
(wire-port direction
  [name value]
  gap length
  [diameter length]
  [anchor (start | center | end)])
```

It registers and returns a `wire-port` value. The port is not an excitation by
itself. It generates one dedicated NEC wire segment between its negative and
positive terminals.

- `direction` points from the negative terminal toward the positive terminal.
- `gap` is the terminal separation and must be positive.
- `diameter` defaults to the current wire diameter.
- `anchor center` centers the segment on the turtle.
- `anchor start` places the negative terminal at the turtle.
- `anchor end` places the positive terminal at the turtle.
- The exporter requires each terminal to resolve either to the intended wire
  endpoint or, when deliberately left free, to a coax input fixture.
- A port segment is always emitted with exactly one NEC segment regardless of
  ordinary wavelength segmentation.

For the motivating dipole:

```racket
;; Hot side: begins at the positive terminal.
(from-here
  (move forward inch)
  (with-wire
    (move forward quarter-wave)))

;; Cold side: begins at the negative terminal.
(from-here
  (move back inch)
  (with-wire
    (move back quarter-wave)))

(define antenna-feed
  (wire-port forward
    name antenna-feed
    gap {2 * inch}))
```

The resulting polarity is:

```text
cold arm ---- (-) [antenna-feed] (+) ---- hot arm
```

## Proposed high-level coax form

The antenna-centric form begins at an existing output port, traces the shield
away from the antenna, and creates the fed input port at the path's end:

```racket
(coax
  name feedline
  output antenna-feed
  impedance 50
  velocity-factor 0.66
  diameter 0.0103
  color "dark orange"
  input-gap inch
  input-direction forward
  feed input

  (move down {2 * meters})
  (lumped-element down
    name common-mode-choke
    resistance 2500
    topology series
    gap 0.02)
  (move down {8 * meters}))
```

Proposed semantics:

1. Resolve `output` to a named `wire-port`.
2. Temporarily place the turtle at that port's negative terminal.
3. Execute the body with wire generation enabled and
   `diameter` as the current wire diameter.
4. Treat the path as the physical route of the shield exterior.
5. At the final turtle position, generate an input `wire-port` with its
   negative terminal anchored to the shield path.
6. Mark the input port segment with the requested named excitation.
7. Emit a non-crossed NEC `TL` between segment 1 of the input and output port
   tags.
8. Use the shield path length divided by `velocity-factor` as the NEC `TL`
   length.
9. Restore the caller's turtle position, orientation, wire state, diameter,
   and scaling state on normal or exceptional exit.

`feed input` is deliberately semantic rather than geometric. The coax body is
traced from the antenna toward the measurement plane, so `feed start` and
`feed end` would be misleading.

## General transmission-line layer

`coax` should compile to a backend-neutral declaration rather than write a
`TL` card directly. The lower-level public form is tentatively:

```racket
(transmission-line
  name feedline
  input coax-input
  output antenna-feed
  impedance 50
  length {10 * meters}
  velocity-factor 0.66)
```

This layer will later support balanced lines, phasing harnesses, and
log-periodic feeds. `coax` adds the explicit exterior conductor and input
fixture around it.

Only one of these line-length conventions should become canonical:

- `physical-length` plus `velocity-factor`, converted to the equivalent NEC
  free-space electrical length; or
- an explicitly supplied `electrical-length` that bypasses route-length
  derivation.

Revision 1 derives physical length from the coax turtle path and does not
provide a length override. A later revision may add an explicit electrical
length for unusual fixtures, with conflicting length settings rejected rather
than guessed.

## Data model

Two model registries are proposed.

```racket
(struct wire-port-declaration
  (name edge direction gap diameter anchor generated?)
  #:transparent)

(struct wire-transmission-line
  (name input-port output-port impedance physical-length velocity-factor)
  #:transparent)
```

The final field names may change during implementation. The essential
invariant is that networks refer to stable port identities rather than edge
numbers. A port fixture is an ordinary model edge for connectivity,
visualization, feed discovery, and result naming, but the NEC exporter always
segments it exactly once.

The registries participate in `clear-model`, `clear-wires`, reflection, and
model validation. Reflection must reverse spatial coordinates without silently
reversing declared electrical polarity.

## NEC2C export

The exporter will:

1. resolve and validate all port terminal connections;
2. emit each port edge as `GW tag 1 ...`;
4. emit ordinary exterior-shield geometry and its existing `LD` cards;
5. emit `GE` and ground configuration;
6. emit `TL input-tag 1 output-tag 1 Z0 effective-length ...`;
7. emit `EX` on the input port tag, segment 1; and
8. emit analysis cards normally.

The `TL` characteristic impedance remains positive so the line is not crossed.
Port direction controls polarity. Export errors must identify port and coax
names rather than generated NEC tags.

The effective length given to NEC is:

```text
route physical length / velocity factor
```

Revision 1 has no electrical-length override.

## Validation rules

Revision 1 rejects:

- duplicate port, line, or feed names;
- nonpositive gap, diameter, impedance, length, or velocity factor;
- velocity factor greater than 1 unless an explicit future opt-out exists;
- a port whose two terminals collapse under snapping;
- an output port whose terminals do not connect to distinct intended
  conductor sides;
- a coax shield path that does not begin at the output port's negative
  terminal;
- a generated input port whose negative terminal does not connect to the
  shield path;
- reuse of one port by incompatible network declarations;
- a feed already occupying the output port;
- active dielectric volumes;
- surface-body geometry until its interaction with network fixtures is
  validated; and
- a choke gap or port fixture that violates ordinary NEC wire-length and
  radius constraints.

Warnings, rather than errors, should cover:

- electrically long port fixtures;
- a shield path without a common-mode termination beyond its input end; and
- an input fixture that is very close to radiating geometry and may itself
  perturb the result.

## Visualization and reporting

`show-model` draws:

- the exterior shield as an ordinary wire;
- each wire port as a distinct two-terminal marker with polarity;
- no connector for the non-radiating internal `TL`;
- the existing orange marker for choke/lumped-element positions; and
- a legend that explicitly labels the TL connector as non-radiating.

Conductor-current views include the shield exterior and port fixtures, but not
the ideal internal `TL`. Network reports identify the coax input feed by name.
The declaration registry retains line impedance, physical route length,
velocity factor, and effective electrical length for tooling.

## Validation strategy

Implementation should proceed through increasingly physical tests:

1. **Deck test:** exact `GW`, `TL`, `EX`, and `LD` placement for a small
   synthetic fixture.
2. **Matched termination:** a 50-ohm line with a 50-ohm load presents 50 ohms
   at several lengths and frequencies.
3. **Open and short transforms:** quarter-wave and half-wave transformations
   agree with transmission-line equations.
4. **Velocity factor:** resonance/phase shifts by the expected ratio.
5. **Local-feed equivalence:** a very short, matched coax model approaches the
   corresponding local-feed antenna result.
6. **Common-mode choke trend:** increasing exterior series impedance reduces
   shield current without changing the internal line's intended impedance.
7. **Energy accounting:** accepted, radiated, structure-loss, and network-loss
   terms remain plausible and no source power is counted twice.
8. **Reference comparison:** compare a simple coax-fed dipole against an
   independently constructed NEC deck and, where practical, OpenEMS.

## Implementation order

1. Add the wire-port registry, DSL, visualization, and one-segment export.
2. Add the transmission-line registry and `TL` export without coax sugar.
3. Validate source and network placement on the same input port segment.
4. Add the scoped `coax` path form and automatic input fixture.
5. Add reporting metadata and current/geometry visualization.
6. Add analytical, independent-deck, and acceptance tests.
7. Document limitations and examples before considering cable loss or
   frequency-dependent network extensions.

Settled decisions:

- The output is an explicit `wire-port` value.
- `diameter`, `input-gap`, and `velocity-factor` are required; impedance
  defaults to 50 ohms.
- Optional `color` changes the rendered shield-exterior route only.
- Route length divided by velocity factor is canonical, with no revision-1
  override.
- Source-end common-mode termination is entirely user geometry. The shield
  is open when the route simply ends.
- Port fixtures and polarity markers are visible; the ideal internal line is
  hidden.
- The `coax` body traces from the antenna output port's negative terminal
  toward the input measurement plane. `feed input` names the excitation
  semantically rather than using route-relative `start` or `end`.
