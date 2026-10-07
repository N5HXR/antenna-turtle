# NEC2C Automation Specification

Status: **Implemented in Antenna Turtle 0.5.0 (revision 1)**
Target: Antenna Turtle 0.5+
Reference engine inspected: `nec2c 1.3`

Revision 1 implements the runner, typed data objects, multi-feed impedance and
VSWR measurements, azimuth/elevation cuts, spherical sampling, headless Plot
renderers, and explicit Plot/Plot3D viewers described below. The speculative
batch/coalescing API and Phase 4 optimization conveniences remain future work.

## 1. Goals

Provide an end-to-end NEC2C workflow from an in-memory Antenna Turtle model:

1. Generate an NEC model deck at an explicitly exported path, or use temporary
   artifacts when the program did not request an export.
2. Run NEC2C non-interactively and report process or solver failures clearly.
3. Measure:
   - feedpoint voltage, current, impedance, and input power;
   - azimuth and elevation radiation-pattern cuts;
   - impedance, reflection coefficient, return loss, and VSWR over a frequency
     sweep;
   - a full spherical radiation grid suitable for 3-D rendering.
4. Parse every requested measurement into transparent Racket data objects.
5. Render measurements with Racket Plot: 2-D Plot for cuts and sweeps, and
   Plot3D for the spherical pattern.
6. Keep the noninteractive path clean enough for parameter searches, Monte
   Carlo studies, and genetic algorithms.

## 2. Non-goals for the first implementation

- Linking against or modifying the nec2c C code. NEC2C remains a subprocess.
- Treating the human-readable `.out` report as a public Antenna Turtle format.
- General support for arbitrary hand-authored NEC cards.
- Network synthesis, matching-network optimization, or Smith-chart editing.
- Near-field sampling.
- A simulator-independent result abstraction. The initial parser and runner
  are explicitly versioned around NEC2C; common abstractions can be extracted
  after a second solver exists.

## 3. Design principles

### 3.1 Separate computation from presentation

Measurement functions return data and do not open windows. Rendering functions
accept those values and display them. This keeps automated runs deterministic
and headless:

```racket
(define sweep
  (nec2c-vswr-sweep 13.5 14.5 #:steps 101))

(show-vswr-sweep sweep)
```

The `raco antenna-turtle` command may offer combined “run and show” switches.

### 3.2 Keep NEC cards private

Users specify physical requests—frequency, angular cut, resolution, and feed
reference impedance—not `FR`, `RP`, or `XQ` fields. A private deck writer
translates requests into cards. The generated deck and raw output remain
available as diagnostic artifacts.

### 3.3 Preserve raw measurements

Parsed objects retain absolute gain and complex electrical quantities. Plot
normalization, dB floors, and VSWR reference impedance are derived views, not
destructive transformations of the source data.

### 3.4 Fail loudly on incomplete output

A zero subprocess exit status is necessary but not sufficient. Each parser
checks the expected frequencies, feeds, angles, and sample count. Missing or
malformed sections produce an exception containing artifact paths and the
relevant output excerpt.

## 4. Model-deck lifecycle

### 4.1 Base deck

Refactor `export-nec2c` into a reusable private writer with two layers:

- geometry and excitation cards through `GE` and `EX`;
- an ordered sequence of analysis cards followed by `EN`.

The existing public `(export-nec2c path)` continues to write the current
geometry-only deck ending in `EN`, preserving compatibility.

### 4.2 Explicit path

Calling `export-nec2c` records the most recently exported NEC path for the
current model generation. A later measurement may use that file as its base.
The runner does **not** insert cards into or otherwise mutate the user’s file;
it creates a decorated temporary copy with the requested analysis cards.

An explicit `#:model-path` keyword overrides the recorded path.

### 4.3 Implicit path

If no explicit or recorded path exists, the runner writes a base deck into a
fresh temporary directory. Input and output filenames are unique per run so
parallel design evaluations cannot collide.

### 4.4 Artifact retention

On success, temporary files are removed by default. On failure they are kept
and their paths are reported. `#:keep-artifacts? #t` retains successful decks
and reports for debugging or reproducibility.

Every result contains artifact metadata. For deleted temporary files the
paths are historical and an `available?` field is false.

## 5. Executable discovery and process control

Resolve the NEC2C executable in this order:

1. explicit `#:executable` argument;
2. the `(nec2c-executable)` parameter;
3. the `NEC2C` environment variable;
4. `find-executable-path` for `nec2c`.

The development checkout at `~/src/nec2c/nec2c` should be configured through
the parameter or environment rather than embedded in the published package.

Invoke NEC2C without a shell:

```text
nec2c -i<input.nec> -o<output.out>
```

Set a C locale for stable decimal formatting. Capture stdout and stderr.
Support an optional configurable timeout; by default, wait until NEC2C exits or
the user interrupts the program. When an explicit timeout expires, terminate
the subprocess and retain artifacts. Record the executable path, version
(`nec2c 1.3` here), exit status, elapsed time, and captured diagnostics.

## 6. Public measurement API

Each function operates on the current Antenna Turtle model.

```racket
(nec2c-measure-impedance
 [frequency (model-frequency)]
 [#:model-path path]
 [#:executable executable]
 [#:keep-artifacts? keep?])
  -> nec2c-impedance-result

(nec2c-vswr-sweep
 start-frequency
 stop-frequency
 [#:steps count | #:step increment]
 [common runner keywords ...])
  -> nec2c-sweep-result

(nec2c-azimuth-pattern
 [#:frequency (model-frequency)]
 [#:elevation 0]
 [#:start 0] [#:stop 360] [#:step 1]
 [common runner keywords ...])
  -> nec2c-pattern

(nec2c-elevation-pattern
 [#:frequency (model-frequency)]
 [#:azimuth 0]
 [#:start (if grounded? 0 -90)]
 [#:stop (if grounded? 180 270)] [#:step 1]
 [common runner keywords ...])
  -> nec2c-pattern

(nec2c-radiation-grid
 [#:frequency (model-frequency)]
 [#:theta-step 5] [#:phi-step 5]
 [common runner keywords ...])
  -> nec2c-pattern-grid
```

All frequencies are MHz, matching `model-frequency` and NEC2C’s `FR` card.
Sweep endpoints are inclusive. `#:steps` means the total number of samples,
including endpoints; `#:step` means an additive MHz increment. Specifying both
is an error. VSWR and reflection-coefficient calculations use the model's
single reference impedance, configured declaratively and defaulting to 50
ohms:

```racket
(model
  title "My Antenna"
  frequency 446
  impedance 200)
```

The new `(model-impedance)` parameter has the same direct getter/setter style
as `(model-frequency)`. It must be a positive real number and is reset to 50
by `reset-model!`. Raw complex active impedance is always retained, so callers
remain free to derive other matching metrics without rerunning NEC2C.

### 6.1 Possible batch API

The independent functions above are the smallest useful interface. A later
batch API may accept request objects and coalesce compatible requests into the
fewest NEC2C runs:

```racket
(run-nec2c
 (list (impedance-request)
       (azimuth-request #:elevation 0 #:step 1)
       (elevation-request #:azimuth 0 #:step 1)
       (vswr-request 13.5 14.5 #:steps 101)))
```

The implementation may internally batch from day one, but the public batch
form is not required for the first release.

## 7. Typed result objects

Use transparent immutable structures so ordinary Racket code can inspect,
match, serialize, filter, and optimize against results.

```racket
(struct nec2c-run-info
  (executable version elapsed-ms exit-code stdout stderr artifacts)
  #:transparent)

(struct nec2c-artifacts
  (model-path input-path output-path temporary? available?)
  #:transparent)

(struct nec2c-feedpoint-sample
  (feed-name frequency-mhz wire-id segment
   voltage current impedance admittance input-power)
  #:transparent)

(struct nec2c-impedance-result
  (run samples)
  #:transparent)

(struct nec2c-sweep-sample
  (feedpoint reflection-coefficient return-loss-db vswr)
  #:transparent)

(struct nec2c-sweep-frequency
  (frequency-mhz feed-samples)
  #:transparent)

(struct nec2c-sweep-result
  (run reference-impedance frequencies)
  #:transparent)

(struct nec2c-pattern-sample
  (frequency-mhz theta-deg phi-deg elevation-deg azimuth-deg
   vertical-gain-db horizontal-gain-db total-gain-db
   axial-ratio tilt-deg polarization-sense
   e-theta e-phi)
  #:transparent)

(struct nec2c-pattern
  (run kind fixed-angle samples)
  #:transparent)

(struct nec2c-pattern-grid
  (run theta-values phi-values samples)
  #:transparent)
```

Complex voltage, current, impedance, reflection coefficient, `e-theta`, and
`e-phi` use Racket complex numbers. NEC2C’s `-999.99` unavailable-gain sentinel
is parsed as `#f`, not mistaken for a physical gain.

Convenience accessors may include:

- peak gain and its direction;
- front-to-back ratio for a requested forward bearing;
- nearest sample by angle or frequency;
- minimum VSWR and its frequency;
- impedance at the minimum-VSWR point.

## 8. NEC2C deck strategy

### 8.1 Single-frequency impedance

Generate one `FR` frequency and an execute request. Parse the `ANTENNA INPUT
PARAMETERS` table, which reports tag, segment, complex voltage/current,
complex impedance/admittance, and power.

### 8.2 VSWR sweep

Generate an additive `FR` sweep followed by `XQ`. (`FR` followed immediately
by `EN` does not execute the requested sweep.) Parse one antenna-input row per
source and frequency. Compute, for real positive reference impedance `Z0`:

```text
Γ = (Z - Z0) / (Z + Z0)
VSWR = (1 + |Γ|) / (1 - |Γ|)
return loss = -20 log10(|Γ|)
```

Represent an unstable or exact `|Γ| >= 1` result as infinite VSWR rather than
clamping it silently.

### 8.3 Pattern cuts

NEC coordinates use theta measured down from global +Z and phi measured in
the XY plane from global +X toward +Y. Antenna Turtle exposes friendlier
azimuth/elevation metadata:

```text
azimuth = phi
elevation = 90 - theta
```

An azimuth cut fixes theta at `90 - elevation` and sweeps phi.

A complete elevation-plane cut requires both sides of the selected plane. It
is assembled from samples at `phi = azimuth` and `phi = azimuth + 180`, rather
than relying on theta values outside NEC’s conventional 0–180 degree range.

### 8.4 Spherical grid

Sample theta from 0 through 180 degrees and phi from 0 up to but excluding 360
degrees. Avoid duplicating the phi seam. The result retains the rectangular
theta/phi grid for deterministic interpolation and rendering.

## 9. Parsing contract

Parse by section headings and column structure, not absolute line numbers.
The NEC2C 1.3 report sections observed locally are:

- `--------- FREQUENCY --------`
- `--------- ANTENNA INPUT PARAMETERS ---------`
- `---------- RADIATION PATTERNS -----------`

Accept signed decimal and exponent notation. Keep parser fixtures containing:

- a single-frequency dipole;
- a multi-frequency sweep;
- azimuth and elevation cuts;
- a small spherical grid;
- malformed and truncated reports;
- multiple source rows, pending the multi-feed decision.

The parser should be usable independently:

```racket
(parse-nec2c-output input-port) -> parsed-nec2c-report
```

This permits regression testing without invoking the executable.

## 10. Rendering API

Ordinary Racket `plot` windows handle inherently 2-D measurements. The
spherical surface has both a portable, single-color Plot3D baseline and a
colorized Pict3D/OpenGL presentation viewer.

```racket
(show-vswr-sweep sweep [#:max-vswr #f] ...)
(show-impedance-sweep sweep ...)
(show-radiation-cut pattern [#:floor-db -40] [#:normalize? #t] ...)
(show-radiation-pattern-3d grid [#:floor-db -40] [#:normalize? #t] ...)
(show-radiation-pattern-opengl grid [#:floor-db -40] [#:normalize? #t]
                                  [#:scale 'arrl] [#:palette 'mmana] ...)
```

### 10.1 VSWR and impedance

- VSWR: frequency on X, VSWR on Y, with optional 2:1 and 3:1 reference lines.
- Impedance: frequency on X with resistance and reactance traces.
- A Smith chart is a sensible later addition but is not required initially.

### 10.2 Polar cuts

Use `polar` and `polar-axes`. Preserve raw dBi in the data object. For radial
display, clamp to a configurable dB floor and translate the displayed radius
so it remains nonnegative. Labels must state whether the plot is absolute dBi
or normalized to its peak.

### 10.3 Three-dimensional pattern

The Plot3D baseline uses a precomputed, single-color sampled surface. The
OpenGL viewer uses a frozen triangle mesh with per-vertex gain colors. Radius
derives from the selected gain component. The default view normalizes the peak
to 0 dB and clips at -40 dB. Provide vertical, horizontal, and total-gain
selectors when those fields are available.

The OpenGL color ramp is selected independently with `#:palette`. Revision 1
provides `'mmana`, `'magma`/`'sdr`, `'inferno`, `'viridis`, and `'grayscale`.
Its legend presents relative dB on the right and peak-referenced absolute dBi
on the left. Grounded upper-hemisphere surfaces receive a display-only bottom
cap so ordinary back-face culling still presents a closed solid.

## 11. Multiple feeds and excitation

The model permits multiple feeds and exports each feed's declared amplitude
and phase as a complex `EX` source. Under simultaneous excitation, NEC reports
*active* impedance at each source; this is not the same as independently
measuring a multiport network.

Local experiments with NEC2C 1.3 established that:

- two- and four-source models execute normally;
- every source has a separate voltage, current, active impedance, admittance,
  and power row;
- frequency sweeps repeat all source rows at every requested frequency;
- radiation-pattern rows describe the combined field from all active sources;
- crossed dipoles driven at `1 + 0i` and `0 + 1i` produce the expected circular
  polarization fields and opposite handedness above and below the antenna.

Therefore revision 1 should support simultaneous multi-feed analysis rather
than reject it. The API must call the reported quantity **active impedance**
in documentation and plot labels. It must not imply that the result is an
S-parameter matrix, isolated port impedance, or the impedance obtained with
the other sources terminated.

Each feed needs a stable identifier, amplitude, and phase. The existing forms
remain shorthand for an automatically named, one-volt, zero-degree source.
Feed locations are contextual DSL keywords and do not require Scheme quoting:

```racket
(feed center)
(move up quarter-wave feed start)
```

The legacy quoted forms `(feed 'center)` and
`(move up quarter-wave feed 'start)` remain valid, as does an expression that
evaluates to a location symbol. In a feed-location position, an identifier
whose text is `start`, `center`, or `end` is always interpreted as the DSL
keyword even if the surrounding Racket program has a binding with that name.

The extended feed descriptor is `(LOCATION NAME AMPLITUDE PHASE)`, where phase
is expressed in degrees:

```racket
(move up quarter-wave feed (start "A" 1.0 90))
(feed (center "B" 1.0 270))
```

This parenthesized form is contextual Antenna Turtle syntax, not an evaluated
Racket procedure call and not a quoted list. The `feed`, `move`, `point`, and
`spread` macros recognize both it and the bare location keywords and construct
the internal feed value. This avoids exporting artificial `start`, `center`,
and `end` procedures merely to support the notation.

As with the existing API, `(feed ...)` marks the next nonzero wire edge; the
inline form marks the edge created by that movement. Internally the exporter
converts amplitude and phase to NEC's rectangular complex voltage fields.
Amplitude must be a nonnegative real number; phase may be any real degree
value and is normalized only for presentation.

Explicit feed names must be nonempty strings and unique. Shorthand feeds
receive deterministic unused names such as `"feed-1"`, `"feed-2"` in model
order (skipping any collision with an explicit name).
Result objects carry both that name and the NEC wire/segment coordinates so
callers can correlate samples without parsing labels. A sweep nests feed
samples beneath each frequency, avoiding an API that silently selects the
first source.

The initial runner always evaluates all declared sources simultaneously at
their declared complex voltages. Independently exciting one port at a time is
not included merely by suppressing the other `EX` cards: absent an explicit
termination model, that would leave those ports open and would not constitute
a general multiport or S-parameter measurement.

## 12. Environment and ground

The model supports `ground none`, `ground perfect`, `ground real`, and
`ground (real relative-permittivity conductivity)`. Bare real ground is the
average-ground preset (13, 0.005 S/m); explicit real ground uses the same
Sommerfeld/Norton solution with caller-supplied material values. `height`
translates the antenna origin along global Z during NEC export.

Free space emits `GE 0`. Both grounded modes emit `GE 1`, making wire endpoints
at Z=0 connect to their ground-plane image, plus `GN 1` for perfect ground or
`GN 2` for real ground. Geometry below the plane and wires lying along it are
rejected. Grounded pattern requests use only the upper hemisphere. Optional
radial ground screens remain future work.

## 13. Error model

Define a dedicated exception subtype carrying run metadata and artifacts.
Distinguish:

- executable not found or wrong version;
- subprocess timeout or nonzero exit;
- NEC input/geometry failure;
- missing feed, duplicate feed name, or invalid excitation voltage;
- malformed/truncated output;
- missing requested frequencies or angles;
- invalid sweep or angular ranges.

Never return partial measurements as if they were complete. A diagnostic mode
may expose partial parsed data explicitly.

## 14. Testing strategy

1. Unit-test card generation without running NEC2C.
2. Unit-test parsing from checked-in, compact output fixtures.
3. Unit-test VSWR and angle conversions independently.
4. Render plots to bitmaps with `plot/no-gui` and verify dimensions/nonempty
   output, following the existing model-view tests.
5. Add opt-in integration tests when `NEC2C` or `nec2c` is available.
6. Compare a reference dipole’s impedance and peak gain within tolerances,
   never by exact floating-point report text.

## 15. Implementation sequence

### Phase 1: runner, deck writer, and impedance — complete

- executable discovery and subprocess lifecycle;
- base/decorated temporary deck handling;
- impedance parser and transparent structures;
- single-frequency measurement;
- additive frequency sweep and VSWR derivation;
- headless tests and fixtures.

### Phase 2: 2-D patterns and plots — complete

- azimuth and elevation request generation;
- radiation-pattern parser;
- polar-cut, impedance, and VSWR plotting;
- CLI integration.

### Phase 3: spherical grid and Plot3D — complete

- spherical request/grid validation;
- 3-D pattern renderer, gain floor, normalization, and coloring;
- performance limits and progress reporting.

### Phase 4: automation ergonomics

- batch/coalesced request API;
- CSV/JSON or s-expression serialization;
- summary metrics such as peak gain, beamwidth, front-to-back ratio, bandwidth,
  and fitness helpers;
- controlled parallel evaluation.

## 16. Interview decisions

The following public API decisions were settled during design:

Resolved:

1. **Interaction model:** source-level measurements return data silently.
   Programmers decide whether to process, print, serialize, or visualize it.
2. **Feed scope:** simultaneous multi-feed analysis belongs in revision 1 if
   NEC2C can support it without a false multiport abstraction. Experiments
   confirm that it can.
3. **Ground scope:** free space, perfect ground, and configurable real ground
   are model-level settings; radial screens remain deferred.
4. **Feed syntax:** every feed position accepts a bare contextual location
   keyword, the legacy quoted location symbol, a computed location expression,
   or `(LOCATION NAME AMPLITUDE PHASE)`. Phase is in degrees.
5. **Reference impedance:** one positive model-level impedance applies to all
   feeds and defaults to 50 ohms.
6. **Plot terminology:** use the norms of Racket's Plot family: 2-D Plot for
   sweeps and cuts, Plot3D for a spherical radiation pattern.
7. **Export reuse:** a preceding `(export-nec2c "file.nec")` selects the visible
   base artifact automatically, while the runner decorates only a temporary
   copy. If there was no explicit export, generate the base deck in the
   temporary run directory.

Temporary directory naming, parser module boundaries, and subprocess plumbing
remain private implementation details and can be revised without changing
antenna programs.
