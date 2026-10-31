# NEC2C Frequency-Dependent Lumped-Network Specification

Status: **Deferred design; not approved for implementation**

Primary target: Antenna Turtle with NEC2C-N5HXR

Future target: reuse of the circuit model in OpenEMS postprocessing, with
physical OpenEMS layout explicitly outside the first revision

## 1. Purpose

Add a compact, solver-neutral DSL for ideal lumped matching networks, filters,
and diplexers. Antenna Turtle will preserve the circuit topology and component
values rather than asking users to calculate Y parameters by hand. For a NEC2C
simulation, NEC2C-N5HXR will evaluate the circuit's two-port Y matrix at every
frequency in an `FR` sweep.

Revision 1 is deliberately analytic. Resistors, inductors, and capacitors are
evaluated from their equations at the requested frequency. It does not require
a sampled multi-row Y table, interpolation, or extrapolation. Measured
Touchstone data and tabulated S/Y/Z parameters remain compatible future input
forms, but they are not prerequisites for the first implementation.

The motivating example is a three-port VHF/UHF diplexer constructed from two
two-port ladder filters that share one radio-side port. This topology does not
require a general N-port network card: NEC2C can stamp two frequency-dependent
two-port networks whose first endpoints refer to the same structure segment.

## 2. Goals

1. Express ordinary series/shunt RLC ladders concisely and readably.
2. Compose two-port ladders into branch networks such as a diplexer.
3. Evaluate an exact analytic Y matrix at each positive simulation frequency.
4. Preserve named components and networks in diagnostics and result metadata.
5. Keep classic `NT` and `TL` behavior unchanged.
6. Permit a single native NEC2C `FR` sweep without launching one solver
   process per frequency.
7. Reuse the pure circuit evaluator independently of NEC2C.
8. Leave a clean path to lossy equivalent circuits, transformers, transmission
   lines, measured data, and general N-port networks.

## 3. Revision 1 non-goals

- Touchstone import or sampled-table interpolation.
- Arbitrary user procedures executed inside NEC2C.
- A general N-port NEC card or arbitrary cross-coupled circuit graph.
- Automatic filter synthesis from cutoff frequency, ripple, or filter order.
- Component tolerance, temperature, voltage, saturation, or nonlinear models.
- Package geometry, lead radiation, mutual coupling between physical
  components, or enclosure effects.
- Frequency-dependent ferrite/core material synthesis.
- OpenEMS geometry placement or meshing of the network.
- Changing an antenna's geometry or treating the network as a radiating body.

## 4. Electrical conventions

Every external network port is an oriented `wire-port`. Voltage follows the
port's negative-to-positive direction. Current is positive into the network.
For a two-port network:

```text
[ I1 ]   [ Y11  Y12 ] [ V1 ]
[ I2 ] = [ Y21  Y22 ] [ V2 ]
```

Revision 1 networks are reciprocal, so `Y12 = Y21`. All component values use
SI units and all public frequencies use MHz consistently with the existing
Antenna Turtle measurement API. Internal angular frequency is
`omega = 2*pi*f_hz`.

The analytic component models are:

```text
resistor:   Z = R                  Y = 1/R
inductor:   Z = j*omega*L          Y = 1/(j*omega*L)
capacitor:  Z = 1/(j*omega*C)      Y = j*omega*C
```

All revision 1 component values must be positive finite reals. Frequencies
must be positive. The evaluator must reject, rather than silently clamp, a
non-finite or numerically singular result.

## 5. Proposed Antenna Turtle DSL

### 5.1 Two-port ladder

The compact ladder form is:

```racket
(define two-meter-low-pass
  (net-ladder
    (series inductor L1 {68 * nanohenries})
    (shunt capacitor C1 {18 * picofarads})
    (series inductor L2 {100 * nanohenries})
    (shunt capacitor C2 {18 * picofarads})
    (series inductor L3 {68 * nanohenries})))

(define seventy-cm-high-pass
  (net-ladder
    (series capacitor C3 {4.7 * picofarads})
    (shunt inductor L4 {15 * nanohenries})
    (series capacitor C4 {2.7 * picofarads})
    (shunt inductor L5 {15 * nanohenries})
    (series capacitor C5 {4.7 * picofarads})))
```

Proposed grammar:

```text
net-ladder :=
  (net-ladder stage ...)

stage :=
  (series component-kind component-name value)
  (shunt  component-kind component-name value)

component-kind := resistor | inductor | capacitor
```

Stages are ordered from ladder input to ladder output. `series` and `shunt`
are contextual forms valid only inside `net-ladder`. Component names are
symbols, must be unique within the resulting composed network, and are retained
for errors, reports, and later tolerance analysis. Values are ordinary Racket
expressions evaluated when the model is built.

The initial grammar intentionally has one value per ideal component. A later
equivalent-circuit form may add explicit ESR, Q, self-capacitance, or named
component-model objects without changing this basic ladder notation.

### 5.2 Branch composition

The diplexer is expressed as two ladders sharing the radio-side port:

```racket
(define diplexer
  (net-multiport
    name vhf-uhf-diplexer
    reference common
    ports (radio vhf uhf)

    (branch radio vhf two-meter-low-pass)
    (branch radio uhf seventy-cm-high-pass)))
```

Proposed grammar:

```text
net-multiport :=
  (net-multiport
    [name symbol]
    reference common
    ports (port-name port-name ...)
    branch ...)

branch :=
  (branch input-port output-port two-port-network)
```

`branch` establishes the orientation of the ladder. Revision 1 permits a
branch network to be a `net-ladder` and permits several branches to share an
external port. Every branch remains an independent reciprocal two-port; there
is no implicit transfer term between its unshared outputs.

`reference common` records that the schematic uses one common return. It does
not create a radiating ground wire or connect the model to NEC ground. The
attached `wire-port` orientations remain authoritative for terminal polarity.

Although the resulting diplexer is mathematically a three-port, its matrix can
be assembled from two branch matrices. If the low-pass branch is `YL` and the
high-pass branch is `YH`, ordered as `(radio vhf uhf)`, then:

```text
Y = [ YL11 + YH11   YL12   YH12 ]
    [ YL21           YL22   0    ]
    [ YH21           0      YH22 ]
```

### 5.3 Attachment to NEC ports

```racket
(net-attach
  diplexer
  radio radio-coax-port
  vhf two-meter-feed
  uhf seventy-cm-feed)
```

The first expression evaluates to a network object. Each following pair maps
one declared external port name to an existing `wire-port-declaration`.

Validation requirements:

- every declared external port is attached exactly once;
- no undeclared external name is accepted;
- all attached values are registered wire ports;
- component, branch, network, and attachment names are unambiguous;
- the same physical port may be shared by multiple branch bindings only when
  it represents the same declared external port; and
- the excitation and existing `TL`/`NT` ownership rules remain explicit.

For the diplexer, export lowers the attachment to two analytic two-port
bindings: `(radio, vhf)` and `(radio, uhf)`. Both bindings refer to the same
radio-side NEC segment.

### 5.4 Pure inspection API

Network evaluation must be usable without running a field solver:

```racket
(network-y diplexer 146)
(network-z diplexer 146)
(network-s diplexer 146
           #:reference-impedances '(50 50 50))
```

`network-y` is the authoritative calculation. Z and S are derived views and
must diagnose singular or ill-conditioned conversions. This API supports unit
tests, plotting filter response, checking passivity, and comparing the DSL
against an external circuit program.

## 6. Ladder evaluation

The implementation may use ABCD matrices internally for a simple ladder:

```text
series impedance Z:   [ 1  Z ]
                      [ 0  1 ]

shunt admittance Y:   [ 1  0 ]
                      [ Y  1 ]
```

Matrices are multiplied in source order and converted to a reciprocal
two-port Y matrix. Production code must not rely on a conversion formula that
divides by a value known to become zero for an otherwise valid topology. A
small nodal-admittance implementation with internal-node elimination is an
acceptable and more general alternative.

If nodal reduction is used, partition the complete matrix into external and
internal nodes and calculate the port matrix with the Schur complement:

```text
Yports = Ypp - Ypi * inverse(Yii) * Yip
```

Production code should solve the linear system rather than form an explicit
inverse. It must report the network name, frequency, and implicated component
or internal node when the system is ill-conditioned.

The compiler must check reciprocity and passivity within documented numerical
tolerances. It must not silently repair a non-passive matrix.

## 7. Required NEC2C-N5HXR extension

### 7.1 Per-frequency network providers

Classic NEC `NT` cards store six constant scalar values. NEC2C-N5HXR needs a
new provider type whose Y matrix is evaluated inside the existing `FR` loop,
after the current frequency is known and before the small network system is
assembled.

Conceptually:

```c
typedef struct {
    double complex y11;
    double complex y12;
    double complex y22;
} nec2c_y_matrix;

bool network_provider_evaluate(const network_provider *provider,
                               double frequency_mhz,
                               nec2c_y_matrix *result,
                               network_diagnostic *diagnostic);
```

The existing static `NT` and transmission-line `TL` implementations should be
adapted behind the same internal interface without changing their deck
semantics. The new analytic ladder provider evaluates RLC equations and
returns the same three complex terms to the existing network solver.

### 7.2 Deck representation

The exact card mnemonics are provisional, but the deck must express two
separate concepts:

1. a reusable analytic provider containing an ordered component list; and
2. a binding between that provider and two NEC structure segments.

One possible textual shape is:

```text
NC 101 SERIES L 6.8e-8
NC 101 SHUNT  C 1.8e-11
NC 101 SERIES L 1.0e-7
NC 101 SHUNT  C 1.8e-11
NC 101 SERIES L 6.8e-8

NB <radio-tag> <radio-seg> <vhf-tag> <vhf-seg> 101
```

The high-pass branch receives another provider ID and another `NB` binding
whose radio endpoint is identical. The actual fixed-column or token grammar
may differ, but the following semantics are required:

- component topology (`SERIES` or `SHUNT`);
- component kind (`R`, `L`, or `C`);
- positive finite SI value;
- stable provider identity;
- ordered stages;
- two unambiguous structure endpoints; and
- no reinterpretation of a classic card.

This is a component table, not a frequency-sample table. NEC2C evaluates it
analytically at every `FR` point, so there is no interpolation policy,
extrapolation policy, or dense deck expansion proportional to sweep length.

Named sidecar resources are acceptable later for measured data, but revision
1 analytic ladders should remain self-contained in the generated NEC deck.

### 7.3 Shared network endpoints

NEC2C must explicitly support and test more than one analytic two-port binding
that refers to the same segment. Contributions at the shared endpoint must be
summed in the small network equation system. This is required for the radio
node of a diplexer.

The implementation must not duplicate the shared unknown, overwrite the
first binding, or count a shared source more than once. Static `NT` fixtures
using the same legal topology should remain equivalent.

### 7.4 Sweep lifecycle

For every `FR` frequency, NEC2C must:

1. establish the current frequency and wavelength;
2. evaluate every analytic network provider;
3. reject non-finite or ill-conditioned results with the provider ID and
   frequency in the diagnostic;
4. stamp the evaluated matrices into the network solve;
5. solve the coupled structure/network system;
6. report the evaluated matrices actually used; and
7. reset all per-frequency provider state before the next point.

No provider may reuse a cached matrix at a different frequency merely because
the geometry matrix was reusable.

### 7.5 Loss and power accounting

Ideal L and C stages are lossless. Resistors dissipate real power and must be
included in network loss. NEC2C should retain aggregate network loss and, if
practical, report loss by provider and named resistor. Power conservation must
be tested for a source feeding a resistive load through both lossless and
lossy ladders.

### 7.6 Reporting and machine results

At each frequency, machine-readable results should retain:

- provider and binding IDs;
- endpoint tags and segments;
- evaluated `Y11`, `Y12`, and `Y22`;
- component model type and source values;
- passivity/conditioning warnings;
- provider loss when available; and
- enough provenance to reproduce the evaluation.

Human-readable output should print evaluated matrices rather than only the
unevaluated component declarations. Antenna Turtle artifact retention should
therefore make a failed frequency independently diagnosable.

## 8. Antenna Turtle export strategy

Antenna Turtle should preserve a backend-neutral circuit object until export.
For NEC2C-N5HXR with analytic-provider support, it emits provider definitions
and bindings once, followed by the ordinary `FR` sweep.

For compatibility testing only, Antenna Turtle may offer a slow reference
path that evaluates the DSL itself and launches one classic static-`NT` NEC2C
run per frequency. That path is useful for comparing the N5HXR evaluator with
the pure Racket evaluator, but it should not become the normal broadband API.

Raw `two-port-y` remains useful for a fixed-frequency matrix. The existing
`ideal-transformer` remains a frequency-independent convenience. Neither form
is silently promoted into an RLC network.

## 9. OpenEMS future considerations

The circuit data model and pure `network-y` evaluator should not depend on
NEC2C. A future OpenEMS integration can reuse the same DSL in two ways.

The preferred first OpenEMS approach is external frequency-domain circuit
combination. OpenEMS characterizes the bare antenna as a broadband multiport;
Antenna Turtle then combines its S/Y matrix with the DSL network. For multiple
radiators, independently recorded complex field bases can be superposed using
the port amplitudes calculated by the circuit. This approach needs no physical
network layout and permits component retuning without rerunning FDTD.

Physical OpenEMS placement is a separate future feature. A topological circuit
does not specify component positions, axes, lead geometry, or mesh constraints.
Embedding the network in the FDTD domain therefore requires an additional
layout DSL and must not be inferred from `net-ladder` order.

Neither OpenEMS path is part of NEC2C network revision 1.

## 10. Validation plan

### 10.1 Pure circuit tests

- Verify R, L, and C impedance/admittance at representative frequencies.
- Compare one-stage series and shunt networks with closed-form results.
- Compare multi-stage ABCD/nodal evaluation with an independent calculation.
- Verify reciprocity and passivity for ideal ladders.
- Verify Y/Z/S conversions and mixed reference impedances where supported.
- Verify useful diagnostics at singular frequencies and invalid component
  values.

### 10.2 NEC2C provider tests

- Compare one analytic provider at one frequency with an equivalent classic
  static `NT` card.
- Compare every point of an analytic `FR` sweep with separate static-`NT`
  reference runs generated by the Racket evaluator.
- Bind two providers to one shared segment and verify summed input current.
- Exercise a lossless ladder and a resistor-containing ladder with power
  conservation checks.
- Confirm existing `NT` and `TL` regression decks are byte-for-byte or
  numerically unchanged.
- Confirm malformed providers fail before the solve with provider and source
  location information.

### 10.3 Diplexer acceptance example

Build the VHF/UHF diplexer from section 5, attach its radio input and two
antenna outputs, and sweep across both passbands. Acceptance evidence should
include:

- radio-port impedance or S11;
- power/current delivered to each branch;
- isolation trend between the two outputs;
- agreement between native analytic-provider and repeated static-`NT` runs;
- radiation patterns showing the appropriate antenna branch dominating in
  each passband; and
- evaluated network matrices retained in the portable report or artifacts.

Absolute filter-performance limits should be established from an independent
circuit calculation rather than inferred from the schematic image alone.

## 11. Deferred extensions

- Component ESR, Q, self-resonance, and frequency-dependent loss.
- Coupled inductors and finite transformer equivalent circuits.
- Transmission-line stages and stubs.
- Touchstone S-parameter import and S-to-Y conversion.
- Tabulated Y/Z/S data with explicit interpolation and extrapolation policy.
- Arbitrary nodal circuit graphs and cross-coupled filters.
- Native general N-port providers.
- Tolerance sweeps and Monte Carlo analysis.
- Network optimization and automatic matching synthesis.
- OpenEMS external circuit reduction and coherent field-basis synthesis.
- OpenEMS physical component layout and mesh generation.

## 12. Completion criteria

This enhancement is complete only when:

1. the DSL and pure evaluator are documented and unit-tested;
2. NEC2C-N5HXR evaluates analytic RLC providers during a native `FR` sweep;
3. shared-endpoint branch networks work without a general N-port card;
4. native results match repeated static-`NT` reference runs within documented
   tolerances;
5. power accounting distinguishes lossless reactance from resistor loss;
6. the diplexer acceptance example demonstrates frequency-selective routing
   into both modeled antenna ports; and
7. classic NEC `NT`, `TL`, and non-network models remain compatible.
