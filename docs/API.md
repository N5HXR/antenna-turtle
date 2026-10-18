# Antenna Turtle API Guide

## 1. Importing the API

For an antenna source file:

```racket
#lang antenna-turtle
```

For a Racket program that manages models explicitly:

```racket
#lang racket
(require antenna-turtle)
```

`#lang antenna-turtle` resets the model before evaluating the module and calls
`validate-model!` afterward. When using `require` from ordinary Racket, call
`reset-model!` before constructing each new model.

The wire DSL and file exporters are always present. Solid-modeling, OpenEMS,
material, solid measurement, and combined NEC/OpenEMS plotting bindings are
exported only when the optional Manifold package and native library loaded
successfully when Antenna Turtle was compiled. A minimal installation prints
the capability warning and leaves those identifiers unbound. After installing
Manifold, run `raco setup antenna-turtle` to enable the full API.

The language includes normal `#lang racket` bindings and implicitly re-exports
version 1.25 of `jphelps/loop`, including `loop`, `return`, `return-from`, and
the package's generator sentinels.

## 2. Numeric and Unit Model

Coordinates are metres. Unit constants are exact Racket numbers:

```racket
meter meters
centimeter centimeters
millimeter millimeters
inch inches
foot feet

ohm ohms kiloohm kiloohms megaohm megaohms
henry henries millihenry millihenries microhenry microhenries
nanohenry nanohenries
farad farads millifarad millifarads microfarad microfarads
nanofarad nanofarads picofarad picofarads
```

Examples:

```racket
(* 3 meter)
(* 12 inch)
(/ (* 300 meter) 438)
```

Translations, rational scaling, and exact quarter turns preserve exact
numbers. General rotations use Racket's inexact trigonometric functions.
Floating-point conversion otherwise occurs during export.

### Antenna arithmetic

`(frequency->wavelength frequency-megahertz)` converts a positive frequency in
MHz to a wavelength in metres. `(wavelength->frequency wavelength-metres)`
performs the inverse conversion and returns MHz. Both use the exact SI speed of
light, 299,792,458 metres per second, so exact inputs produce exact results.

Three read-only identifiers are always available and resolve against the
current `model-frequency` whenever they are used:

```racket
(model-frequency 446)
wavelength
half-wave
quarter-wave
```

They therefore remain correct across `reset-model!` and iterative generators;
they are identifier macros rather than values captured when a module starts.
Normal evaluation order still applies if their value is saved in another
variable. `(model-wavelength)` remains the equivalent procedural API and is
useful to libraries and tooling.

`(span length unit)` expresses a physical length as a unitless count of the
chosen positive unit. The length may be signed, which also makes `span` useful
for offsets:

```racket
(span wavelength millimeter)         ; objective millimetres
(span {2 * foot} inch)               ; 24
```

`(frequency-retuning-scale observed-megahertz target-megahertz)` returns the
linear scale factor `observed / target`. It is intended for the common first
retuning step where resonant frequency varies inversely with antenna size:

```racket
(with-scale (frequency-retuning-scale 28.5 29.0)
  (construct-antenna))
```

`(half value)` is the small exact helper `(/ value 2)` used throughout model
source:

```racket
(move forward (half board-length))
```

### Curly infix expressions

The `#lang antenna-turtle` reader assigns infix meaning to curly braces:

```racket
{1 + 2 * 3}                    ; 7
{360 / 7}                      ; exact 360/7
{{a + b} * c}                  ; explicit grouping
{2 * millimeter}               ; exact 1/500 metre
```

The operators supplied by the underlying `k-infix` parser are:

```text
or and bior bxor band
= != >= <= > < <=>
<< >> + - * / % ^
not bnot
```

`^` denotes exponentiation and `%` denotes modulo. Standard precedence and
associativity apply. Identifiers refer hygienically to the surrounding lexical
scope. Prefix Racket expressions can be protected from infix parsing with `~`:

```racket
{radius * ~(sin angle)}
```

Operators must be separated by whitespace: `{a + b}` is valid, while `{a+b}`
is read as one Racket identifier. Curly braces no longer act as interchangeable
parentheses in this language. Ordinary parentheses and square brackets retain
their standard Racket meanings.

This reader behavior applies only to modules beginning with
`#lang antenna-turtle`. A `#lang racket` module that uses
`(require antenna-turtle)` retains the ordinary Racket reader, where `{...}`
is equivalent to `(...)`.

## 3. Model Settings

Every setting has a useful default, so a module may begin tracing wire without
any model declaration. The defaults are title `"Turtle Antenna"`, frequency
`14.1` MHz, maximum segment length of one-twentieth wavelength, snap length of
one-millionth wavelength, wire diameter of one millimetre, reference impedance
of 50 ohms, no ground, and zero height offset.

### `(model [setting value] ...)`

Sets any desired subset using contextual `title`, `frequency`, `max-length`,
`snaplen`, `wire-diameter`, `impedance`, `ground`, and `height` pairs. Each
setting may appear at most once:

```racket
(model title "Three-element Yagi"
       frequency 14.1
       max-length {wavelength / 40}
       snaplen {wavelength / 1000000}
       wire-diameter {2 * millimeter}
       impedance 50
       ground real
       height half-wave)
```

Pair order is not significant. Frequency is applied before derived lengths, so
`max-length`, `snaplen`, and `height` expressions may safely use wavelength
values in any source order.

The individual setting operations below remain available for calculated or
dynamically scoped programs.

### `(model-title [title])`

- Default: `"Turtle Antenna"`.
- Supplies the human-readable title written by exporters.

### `(model-frequency [megahertz])`

- Default: `14.1`.
- Units: MHz.
- Written into MMANA output and used to initialize MATLAB analysis and its
  wavelength-based mesh bound.
- `mmana-frequency` is a compatibility alias to the same parameter.

### `(model-impedance [ohms])`

- Default: `50` ohms.
- Requires a positive real number.
- Supplies the common reference impedance used to derive reflection
  coefficient, return loss, and VSWR from every NEC2C feed's active impedance.
- It does not alter geometry or the raw complex impedance returned by NEC2C.

### `(model-ground [ground])`

- Default: `'none` (free space).
- The direct setter accepts `'none`, `'perfect`, `'real`, or a value produced
  by `(real-ground relative-permittivity conductivity)`.
- The getter returns a transparent `ground-spec` value.
- `'real` is the average-ground preset: relative permittivity 13 and
  conductivity 0.005 S/m.

The contextual model syntax does not require quotes and additionally accepts
an explicit real-ground descriptor:

```racket
(model ground none)
(model ground perfect)
(model ground real)
(model ground (real 5 0.001))
```

Real ground uses NEC2C's Sommerfeld/Norton solution. Relative permittivity must
be positive; conductivity is expressed in siemens per metre and may be zero.

### `(model-height [metres])`

- Default: `0`.
- Requires a nonnegative real number.
- Adds a global Z offset to every NEC2C-exported coordinate. Intrinsic turtle
  geometry remains centered where the program generated it.
- In a grounded model, the resulting ground plane is Z=0.

`(model-grounded?)` returns `#t` for perfect or real ground and `#f` for free
space. This is useful when choosing an elevation range:

```racket
(define elevation-start (if (model-grounded?) 0 -90))
```

### `(maximum-segment-length [length])`

- Default behavior: one-twentieth of the wavelength at `model-frequency`.
- The zero-argument form resolves the current wavelength-derived default.
- Passing `#f` restores automatic behavior after an explicit override.
- Units: metres.
- An explicit value must be a positive real before export.
- The count for an edge is `ceiling(edge-length / maximum-segment-length)`.
- A center-fed edge's count is increased when necessary to make it odd.

### `(snap-length [length])`

- Default behavior: one-millionth of the wavelength at `model-frequency`.
- Units: metres in the global model coordinate system.
- Passing `#f` restores the automatic wavelength-derived default.
- Passing `0` disables proximity snapping; exactly equal coordinates still
  share a vertex.
- A positive setting snaps a newly drawn endpoint to the nearest eligible
  existing vertex within the distance. Exact coordinates are copied, and the
  turtle finishes at the canonical coordinate.
- Ties retain vertex creation order. The prospective edge's own source is
  excluded so that an intentionally short edge is not silently collapsed.
- Snapping applies only to explicit vertices, not crossings or the interior of
  an existing edge.

### `(wire-diameter length)`

- Initial value: `1 millimeter`.
- Requires a positive finite real.
- Sets the base diameter for subsequently created edges.
- Effective diameter also includes the current `scale-all` diameter factor.

## 4. Wire Operations

### `(wire-off)`

Subsequent movement changes turtle state without generating an edge. Calling
it also terminates any open `point` trace, even when the wire is already off.

### `(wire-on)`

Subsequent nonzero movement generates a wire edge and any open `point` trace is
terminated.

### `(with-wire body ...+)`

Requires the wire to be off, turns it on for `body`, and restores wire-off on
normal or exceptional exit. Returns the body's values. Entering while wire is
already on is an error.

```racket
(with-wire
  (forward 1)
  (turn left 90)
  (forward 1))
```

`pen-up`, `pen-down`, and `with-pen` remain as compatibility aliases for
existing models; their signatures are `(pen-up)`, `(pen-down)`, and
`(with-pen body ...+)`. New code should use the wire terminology.

## 5. Movement

All directions below are in the current local frame. Distance expressions are
evaluated exactly once and multiplied by the current movement scale.

### `(forward distance)` / `(forwards distance)`

Moves along local `+X`.

### `(back distance)` / `(backward distance)` / `(backwards distance)`

Moves along local `-X`.

### `(move direction distance ... [feed descriptor | steps count])`

`direction` is a contextual keyword and does not require quoting:

```racket
(move forward distance)   ; +X
(move forwards distance)  ; +X
(move back distance)      ; -X
(move backward distance)  ; -X
(move backwards distance) ; -X
(move left distance)    ; +Y
(move right distance)   ; -Y
(move up distance)      ; +Z
(move down distance)    ; -Z
```

A lexical variable with the same name as a direction does not affect parsing.

Multiple direction/distance pairs form one displacement in the current local
frame:

```racket
(move forward 10 up 1)
```

The optional contextual `feed` pair marks the resulting edge. Bare `start`,
`center`, and `end` are contextual DSL keywords and need no quotation:

```racket
(move forward length feed start)
(move forward length feed (center "driven" 1.0 90))
```

The legacy quoted symbols and expressions evaluating to one of those symbols
remain valid. The four-field descriptor is described under Feeds.

This creates one diagonal edge from the old position to the new position when
the wire is on. It does not create a forward edge followed by an upward edge.
Pairs may be supplied in any order, repeated directions are added, and opposing
directions subtract. Every distance expression is evaluated exactly once in
source order. The current movement scale applies uniformly to the completed
local displacement vector.

The optional contextual `steps` pair divides that one combined displacement
into `count` equal edges:

```racket
(move forward width up rise steps 8)
```

`count` must be an exact positive integer and is evaluated once. Every target
is calculated from the original position, avoiding accumulated stepping drift.
This is particularly useful when a warp needs explicit intermediate vertices;
exporter segmentation cannot bend a chord after mapping. `feed` and `steps`
cannot be combined, and a segmented move cannot consume an already pending
feed. Mark the desired constituent segment explicitly when it needs a feed.

### `(point direction distance ... [feed descriptor])`

Calculates a point relative to the current turtle position and local frame
without relocating the turtle. It accepts the same chained directions,
scaling, contextual keywords, and evaluate-once behavior as `move`.

`point` is legal only while the wire is off. The first call stores a trace
anchor but does not insert an isolated model vertex. Each subsequent call
creates an edge from the saved anchor to the newly calculated point, then saves
the canonical, possibly snapped endpoint as the next anchor:

```racket
(point right radius)
(turn left angle)
(move up rise)
(point right radius)
```

Wire-off movement, turning, and scaling leave an open point trace intact.
Calling either `wire-on` or `wire-off` terminates it; a lone anchor is silently
discarded. An open anchor at export or program termination is legal.

Inline `feed` applies to the edge ending at that call. It is an error on the
first point because no edge exists. Zero-length point edges follow ordinary
zero-movement feed rules. Completed point edges use current wire diameter,
exact endpoint merging, and proximity snapping. The point anchor is part of
the complete turtle state saved and restored by `push`, `pop`, and `from-here`.

### `(with-points body ...+)`

Runs `body` as an independent, exception-safe point trace. Wire must be off and
no point trace may already be active on entry. The final trace anchor is
discarded on normal or exceptional exit; generated geometry, position,
orientation, scales, settings, and body result values otherwise survive.

Use a direct `(wire-off)` call as the lower-level way to snip an open point
trace without first turning the wire on.

### `(spread direction distance [feed descriptor])`

Creates one full segment centered at the current position without moving the
turtle. Conceptually, the turtle stretches a conductor equally in both
directions and leaves it in place.

- Wire on: creates exactly one centered edge.
- Wire off: creates no edge and changes no turtle state.
- Pending feed: applies to the centered full edge.
- Final position and all other turtle state are unchanged.

All six `move` direction words are accepted. Opposite names create identical
geometry with reversed edge orientation, which matters for `'start` and `'end`
feed locations.

### `(move-nearest)`

Moves to the closest existing model vertex, copying its coordinates exactly.
The search excludes vertices equal to the current point and the source of the
immediately preceding movement. Ties retain vertex creation order. Wire state
controls whether the closing movement draws.

### `(here)` and `(goto coordinates)`

`here` returns the current global `point3`. `goto` moves directly to such a
global coordinate, ignoring local orientation and movement scale while still
honoring wire and pending-feed state:

```racket
(define origin (here))
(move forward 10)
(goto origin)
```

### Zero movement

Zero distance is legal and creates no edge. It is an error when a feed is
pending because no segment would receive the feed.

## 6. Rotation

Rotations occur in place around local axes and use degrees.

### `(turn direction degrees [direction degrees] ...)`

```racket
(turn left degrees)   ; positive local Z
(turn right degrees)  ; negative local Z
(turn up degrees)     ; negative local Y
(turn down degrees)   ; positive local Y
(turn roll-left degrees)  ; negative local X
(turn roll-right degrees) ; positive local X
```

The directions are contextual keywords. Chained rotations occur sequentially
in source order because 3D rotations do not commute. Roll names use the
turtle's point of view looking forward: roll-left lowers local `+Y`.

### Axis-specific forms

```racket
(turn-x degrees)
(turn-y degrees)
(turn-z degrees)
(turn-axis degrees x y z)
```

`turn-axis` accepts any finite, nonzero vector in local coordinates and
normalizes it internally. Vector magnitude has no effect.

## 7. Scale

### `(scale factor)`

Multiplies the current movement and solid-geometry scale by a positive factor.
Wire diameter is unchanged.

### `(scale-all factor)`

Multiplies movement, solid-geometry, and wire-diameter scale by a positive
factor.

### `(with-scale factor body ...+)`

Temporarily multiplies movement and newly registered solid-geometry scale for
the body, then restores the prior scale on every exit. This includes Manifold
bodies, solid primitives, sheet coordinates and thickness, and explicit port
dimensions. It does not change ordinary wire diameter; use `scale-all` for
that. Automatic wavelength-derived port dimensions are already SI values and
are not scaled a second time. The form does not rewind position, orientation,
wire state, other settings, or generated geometry.

Neither scaling form changes the global `maximum-segment-length` setting.

## 8. Turtle State Stack

### `(push)` and `(pop)`

`push` saves position, orientation, wire state, movement and diameter scales,
base diameter, and previous-movement information. `pop` restores that state.
Generated geometry is global and is not removed. Popping an empty stack is an
error; exiting a model with unmatched pushes is legal.

### `(from-here body ...+)`

Exception-safe `push`/`pop`. Returns the body's values, restores the complete
turtle state, and retains geometry generated inside the body.

`with-push` remains as a compatibility alias.
Its signature is `(with-push body ...+)`, identical to `from-here`.

### `(reflect direction body ...+)`

Executes `body` exactly once, then copies the wire edges it created across a
reflection plane through the turtle position captured on entry. The plane is
oriented in the local frame captured on entry:

- `up` or `down`: negate local Z across the local XY plane;
- `left` or `right`: negate local Y across the local XZ plane;
- `forward`, `forwards`, `back`, `backward`, or `backwards`: negate local X
  across the local YZ plane.

Opposite direction names intentionally select the same plane. Reflected edges
retain their diameters but never copy feeds. Vertices in the plane are shared,
and an edge wholly in the plane is not duplicated. Vertex snapping applies to
the copy. Arbitrary Racket effects in the body occur only once; the body's
result values and final turtle state are preserved. The body must not reset or
replace the current model.

### `(radial-repeat count body ...+)`

Executes `body` at `count` evenly spaced headings around the entry frame's
local up axis. The first copy uses the current heading. Later copies use
absolute `index * 360/count` rotations from the captured entry orientation, so
roundoff does not accumulate between copies. `count` must be an exact positive
integer and is evaluated once.

Every copy begins with the complete entry turtle state, and the form restores
that state on normal or exceptional exit. Geometry is retained. The body truly
executes `count` times, so ordinary side effects and feeds are repeated too.
The form returns `void`.

`radial-iterations` is available in the body as an outermost-to-innermost list
of zero-based `(index count)` pairs. For example, the third copy of six
containing the fifth copy of eight sees:

```racket
'((2 6) (4 8))
```

This supports nested radial repetition without losing the outer context.
Using `radial-iterations` outside `radial-repeat` is an error. Entering with a
pending feed, leaving an iteration with an unconsumed feed, or resetting the
model in the body is also an error.

## 9. Coordinate Warping and Surfaces

### `(with-warp mapper body ...+)`

Generates `body` in a transformed coordinate space. `mapper` receives local
`x`, `y`, and `z` and must return a list containing exactly three finite real
coordinates. It should be deterministic because a shared logical endpoint may
be mapped once for each incident edge:

```racket
(with-warp
 (lambda (x y z)
   (list x y (+ z (/ (+ (* x x) (* y y)) (* 4 focal-length)))))
 (construct-flat-dish-grid))
```

The mapper's coordinate system is the turtle frame captured on entry: `x` is
forward, `y` is left, and `z` is up. Returned coordinates are interpreted in
that same fixed frame. Only emitted model vertices are mapped; turtle movement,
`here`, and point tracing remain in ordinary logical space inside the body.
On every exit, the complete entry turtle state is restored like `from-here`,
while transformed geometry and the body's return values are retained.

Warps may not be nested. `move-nearest`, `reset-model!`, and a `reflect` call
inside a warp are rejected because they require an inverse or an ambiguous
physical frame. A warp may be wrapped by `reflect`, which copies the completed
physical geometry. Collapsing a nonzero logical edge to one mapped point is an
error.

### `(with-surface height-function body ...+)`

Height-field shorthand for the common case. `height-function` receives
entry-local `x` and `y` and returns one finite real height. The effective map
is `(list x y (+ z height))`, so logical `z` remains a straight-up offset in
the enclosing coordinate system rather than an offset along the surface
normal.

```racket
(define (paraboloid-height x y)
  (/ (+ (* x x) (* y y)) (* 4 focal-length)))

(with-surface paraboloid-height
  (construct-flat-dish-grid))
```

Warping maps vertices, not the continuous interior of an edge. Each edge is
the straight chord between mapped endpoints, so curved paths need enough
explicit points for the desired approximation. Exporter segmentation cannot
bend an existing chord. Snapping, feeds, `wire-used`, viewing, and exporters
use the resulting physical geometry. Movement scaling occurs before mapping;
wire diameter is unchanged.

### `(paraboloid focal-length)`

Returns the centered height function
`(x² + y²) / (4 * focal-length)` for use with `with-surface`:

```racket
(with-surface (paraboloid focal-length)
  (construct-flat-dish-grid))
```

`focal-length` must be a positive finite real number. The aperture plane is
local XY and the surface rises along local positive Z.

### `(cylinder radius)`

Returns a three-coordinate mapper for `with-warp`. Local X is arc length around
the cylinder, local Y is its axis, and local Z is an inward radial offset. At
X zero, logical and physical axes coincide; the unoffset surface curves toward
local positive Z:

```racket
(with-warp (cylinder radius)
  (with-wire
    (move forward (* 2 pi radius) steps 48)))
```

One circumference returns to the seam. `radius` must be positive.

### `(dome radius)` and `(bowl radius)`

Return hemispherical height fields for `with-surface`. Both place their vertex
at local origin and accept coordinates within the radius:

- `dome` falls away from its crown toward local negative Z;
- `bowl` rises away from its bottom toward local positive Z.

Their respective formulas are `sqrt(radius² - x² - y²) - radius` and its
negative. Coordinates outside the circular domain produce an error; tiny
floating-point overshoot at the rim is tolerated.

### `(catenary span sag)`

Returns a centered hanging-catenary height field for `with-surface`. The curve
runs along local X and is extruded unchanged along local Y. Its supports are at
`x = -span/2` and `x = span/2`, both at height zero; its lowest point is at
`x = 0`, at height `-sag`:

```racket
(with-surface (catenary support-spacing center-sag)
  (construct-segmented-hanging-wire))
```

Both arguments must be positive finite real numbers. `span` calibrates the
curve but does not restrict its domain, so coordinates beyond the nominal
supports continue along the same mathematical catenary. As with every warp,
the body must emit intermediate vertices: one straight edge between the two
supports would remain a straight chord and would not represent the sag.

## 10. Feeds

### `(feed descriptor)`

Marks the next nonzero edge. A descriptor may be a bare contextual location,
a legacy quoted location symbol, a computed expression returning a location
symbol, or a named excitation:

```racket
(feed center)
(feed 'start)                         ; compatibility form
(feed (center "A" 1.0 0))
(move forward half-wave feed (end "B" 1.0 90))
```

The named form is `(LOCATION NAME AMPLITUDE PHASE)`. `LOCATION` is `start`,
`center`, or `end`; `NAME` is a nonempty string unique within the model;
`AMPLITUDE` is a nonnegative voltage magnitude; and `PHASE` is a real angle in
degrees. Shorthand feeds receive deterministic unused names such as
`"feed-1"`. Multiple feeds are driven simultaneously.

These parenthesized descriptors are contextual macro syntax, not calls to
procedures named `start`, `center`, or `end`. A bare location in feed position
therefore remains a keyword even if a lexical binding has the same spelling.
`move`, `point`, and `spread` accept the same descriptors inline.

Before the marked edge, the program may rotate or change non-movement settings.
These are errors while a feed is pending:

- another `feed`;
- wire-off movement;
- zero movement;
- module termination without a consuming edge.

A completed `point` edge may consume a feed while ordinary turtle movement is
wire-off. Inline feed notation on the first point of a trace is an error
because that call establishes only an anchor.

Target behavior:

- NEC2C: complex excitation voltage on the first, middle, or last solver
  segment;
- MMANA: `b`, `c`, or `e` source designation plus amplitude and phase;
- MATLAB: center feeds only; start or end feeds produce an export error.

The procedural constructor is
`(make-feed-spec location [name #f] [amplitude 1.0] [phase 0.0])`. It accepts
`'start`, `'center`, or `'end`; a missing name is assigned when the feed is
attached. It is useful to calculated geometry that supplies a descriptor to a
lower-level operation:

```racket
(define driven (make-feed-spec 'center "driven" 1.0 90))
(move forward half-wave feed driven)
```

## 11. Model Lifecycle and Inspection

### `(clear-wires)`

Clears all vertices and edges and returns the turtle to the origin with its
initial orientation and wire drawing off. It also clears the turtle stack,
point-trace anchor, and any pending feed. Model settings—including frequency,
ground, height, segmentation, impedance, and wire diameter—are preserved.

Use this when regenerating geometry interactively under the current `(model
...)` declaration. It may not be called inside `with-warp`, `with-surface`, or
`radial-repeat`.

### `(clear-bodies)` and `(clear-mesh-constraints)`

`clear-bodies` closes owned Manifold handles and clears bodies, sheets, ports,
and lumped components. `clear-mesh-constraints` clears only explicit
`mesh-point`/`mesh-plane` annotations. `reset-model!` calls both through reset
hooks.

```racket
(clear-wires)             ; regenerate only centerline geometry
(clear-bodies)            ; regenerate only physical geometry
(clear-mesh-constraints)  ; discard manual Yee-grid constraints
```

### `(reset-model!)`

Clears geometry, turtle state (including any point-trace anchor), stack,
pending feed, and settings.

### `(validate-model!)`

Currently verifies that no feed marker remains unused.

`(validate-solid-scene! [scene (current-solid-scene)])` verifies unique names,
material overlap/precedence rules, and solid-scene consistency. The language
module-begin runs both validators automatically. Call them explicitly after
interactive construction with ordinary `(require antenna-turtle)`.

### `(current-position)`

Returns the current `point3`.

`here` is the preferred geometry-facing synonym.

### `(current-wire-diameter)`

Returns base diameter multiplied by the active diameter scale.

### `(current-antenna-model)`

A parameter containing the mutable `antenna-model` value.

The corresponding solid-scene parameter is `(current-solid-scene [scene])`.
`(model-bodies [scene])`, `(model-sheets [scene])`, `(model-ports [scene])`,
and `(model-components [scene])` return its lists, defaulting to the current
scene. `(model-mesh-constraints)` returns the current manual constraints.

```racket
(for ([port (in-list (model-ports))])
  (printf "port: ~a\n" (lumped-port-name port)))
```

### `(model-vertices [model])` and `(model-edges [model])`

Return model vertices and edges; the current model is the default.

### `(wire-used [model])`

Returns the sum of the model's physical wire-edge lengths in metres; the
current model is the default. This is an odometer over completed geometry, so
saved readings can measure one construction without special marker state:

```racket
(define mark (wire-used))
(curl)
(define curl-length (- (wire-used) mark))
```

The result reflects actual final endpoints after movement scaling, arbitrary
rotations, point tracing, snapping, and reflection. Wire-off movement, a lone
point anchor, and solver subdivision do not contribute. Deliberately generated
overlapping edges each count because each represents a laid wire edge.

### Public structures

```racket
(point3 x y z)
(vertex id point)
(feed-spec location name amplitude phase)
(ground-spec kind relative-permittivity conductivity)
(wire-edge id start end diameter feed-info)
(antenna-model vertices edges)
```

`wire-edge-feed-location` returns `#f`, `'start`, `'center`, or `'end`.
`wire-edge-feed-name`, `wire-edge-feed-amplitude`, and
`wire-edge-feed-phase` expose the remaining excitation metadata.
`wire-edge-feed?` remains available as a Boolean convenience predicate. All
structure predicates and accessors are exported. A `ground-spec` has kind
`'none`, `'perfect`, or `'real`; only real ground carries numeric material
fields. `antenna-model` also
exports mutators because it is declared mutable; tooling should prefer normal
turtle operations unless deliberate model transformation is required.

### `(edge-length edge)`

Returns Euclidean edge length.

### `(edge-segment-count edge maximum-length)`

Returns the solver subdivision count, including odd-count adjustment for a
center-fed edge. The exact signature is
`(edge-segment-count edge [maximum-length (maximum-segment-length)])`.

## 12. Geometry Viewer

### `(show-model [model] [#:vertices? vertices?] [#:wire-color color] [#:width width] [#:height height] [#:aspect-ratio ratio] [#:legend? #f])`

Opens the current model in a separate interactive Plot3D window. The optional
`model` defaults to `(current-antenna-model)`. Drag the plot to rotate it.

Conductors default to medium blue (`"steelblue"`) and feed locations are marked
in red. `#:wire-color` accepts a Plot3D color such as `"navy"` or `"orange"`.
With `#:vertices? #t`, every Antenna Turtle vertex is also marked. `width` and
`height` are positive integer window dimensions and default to `900` and `700`.
`#:aspect-ratio` is an additional width-to-height projection multiplier and
defaults to `1` for an undistorted view.

The viewer gives every coordinate axis the same metric range and dynamically
adjusts the Plot3D viewport during rotation so horizontal and vertical screen
units remain equal. This avoids both independent data-axis stretching and the
angle-dependent distortion of Plot3D's normal fit-to-window behavior. It
renders DSL edges before solver subdivision and uses a fixed visible line
width rather than physical conductor diameter. Plot3D windows use independent
GUI eventspaces, so they remain interactive while a synchronous solver call is
running. The legend occupies a separate side panel instead of covering the
model; its **Show legend** checkbox reveals the panel on demand. Pass
`#:legend? #t` to start with it visible. An empty model or an unused pending
feed is an error.

The command-line equivalent is:

```sh
raco antenna-turtle build model.rkt --view
```

### `(show-solid-model [#:width 900] [#:height 700] [#:aspect-ratio 1] [#:legend? #f] [#:wire-segments 24])`

Opens registered Manifold volume bodies, planar sheets, and any ordinary
Turtle wire network in a proportion-preserving Plot3D window. Wires are shown
as the same temporary capsule union used by OpenEMS, including its derived
physical feed gap. `#:wire-segments` controls circular tessellation. PEC,
dielectric, and sheet geometry receive distinct materials. Derived and
explicit lumped ports appear as red boxes with a polarity arrow. This is a
geometry preflight viewer; the OpenEMS-generated `model.xml` remains the
authoritative view of the final Yee mesh and CSXCAD properties.
Like `show-model`, this window remains interactive during a blocking
`openems-sweep` call. Its external legend starts collapsed; pass
`#:legend? #t` when it should be visible initially.

## 13. Physical Solid Scene and OpenEMS

The high-level solid constructors follow the turtle frame and use centered
placement by default:

```racket
(define fr4 (dielectric name fr4 er 4.4))

(with-scale millimeter
  (with-material fr4
    (cuboid name substrate size '(150 150 1.6) anchor bottom))

  (sheet rect name ground size '(150 150) mesh-edges exact)

  (from-here
    (move up 1.6)
    (sheet rect name patch size '(89 70) mesh-edges metal))

  (from-here
    (move left -13)
    (port up name feed gap 1.6 size 2 anchor start)))
```

`cuboid` dimensions are `(length width height)`, corresponding to turtle
forward/back, left/right, and up/down. `sphere` takes `radius` or `diameter`.
`cylinder` and `capsule` take `length` plus `radius` or `diameter`; their axes
follow turtle up. A capsule's length is the cylindrical center-to-center
length, and `anchor start` or `anchor end` selects the corresponding sphere
center so consecutive capsules enmesh exactly.

`anchor center` is the primitive default. A face name (`front`, `back`,
`left`, `right`, `top`, or `bottom`) slides that bounding-box face onto the
turtle. A list combines orthogonal faces, as in `anchor '(bottom left)`.
Curved and imported geometry deliberately uses its bounding box for these
anchors. The programmer remains responsible for whether that is meaningful.

`(stl [name object-name] path path-expression ...)` reads either binary or ASCII STL and
places it through the same turtle, material, precedence, anchor, and
`with-scale` pipeline. STL has no unit metadata; coordinates are interpreted
as metres outside a scaling scope. `read-stl-solid` is the lower-level reader
for callers that need to apply Manifold CSG before registering the result.

`with-material` supplies a scoped default. Constructors choose backend-neutral
default precedence values: dielectric 10 and PEC/conducting geometry 20.
`precedence` overrides the default. OpenEMS maps precedence to CSXCAD priority;
future backends may instead use it to resolve mesh-region ownership.

Names are optional on scene objects. Every explicit name uses the contextual
`name value` pair; no constructor has a positional name. Omitting it assigns a
fresh uninterned symbol with a descriptive prefix; supply an
explicit name when code, plots, or measurements need a stable human-facing
reference. This makes repeated geometry procedures safe without requiring
their callers to manufacture names. A bare identifier is a concise literal
label (`name feed`); strings and expressions such as
`name (gensym 'fixture)` are also accepted.

Ports are centered on the turtle by default. `anchor start` instead places the
port's negative-direction terminal at the turtle, while `anchor end` places
its positive-direction terminal there; the names are relative to the declared
port direction and continue to work after turtle rotation. `size n` is a
square transverse profile. Use `size '(width depth)` or separate `width` and
`depth` settings for a rectangular profile.

Given a registered `lumped-port`, `(lumped-port-start port)` and
`(lumped-port-stop port)` return its negative- and positive-direction terminal
centers as `point3` values. This is convenient for geometry diagnostics:

```racket
(define input-port (first (model-ports)))
(list (lumped-port-start input-port) (lumped-port-stop input-port))
```

### Solid constructor reference

The solid DSL uses contextual `setting value` pairs rather than Racket
keywords. Settings may appear in any order and at most once. The exact public
forms are:

```racket
(with-material material body ...+)

(body [name value] geometry manifold-solid
      [material material] [priority integer | precedence integer]
      [coordinates (local | world)] [anchor anchor]
      [metal-thickness length])

(cuboid [name value]
        [size (list length width height)
         | length length width width height height]
        [material material] [precedence integer]
        [anchor anchor] [metal-thickness length])

(sphere [name value] (radius radius | diameter diameter)
        [material material] [precedence integer]
        [anchor anchor] [segments integer]
        [metal-thickness length])

(cylinder name-and-settings ...)
(capsule name-and-settings ...)
;; cylinder and capsule settings:
;;   [name value] length length (radius radius | diameter diameter)
;;   [material material] [precedence integer] [anchor anchor]
;;   [segments integer] [metal-thickness length]

(stl [name value] path path
     [material material] [precedence integer] [anchor anchor])

(sheet rect [name value]
       [size (list length width) | length length width width]
       [material material] [precedence integer | priority integer]
       [mesh-edges (exact | metal)] [thickness length])

(sheet [name value] points point-list
       [material material] [precedence integer | priority integer]
       [coordinates (local | world)]
       [mesh-edges (exact | metal)] [thickness length])

(port direction [name value] [impedance ohms]
      [gap length] [size size | width width depth depth]
      [anchor (start | center | end)]
      [precedence integer | priority integer])
```

`with-material` is syntax over
`(call-with-solid-material material thunk)`. The parameter
`(current-solid-material [material])` holds the scoped value, while
`(current-geometry-scale)` reports the accumulated scale used for new solid
dimensions. The material parameter defaults to `pec`. Libraries can use the
procedural form without manufacturing DSL
syntax:

```racket
(call-with-solid-material copper
  (lambda () (sheet rect size '(20 10))))
```

`direction` accepts `forward`, `forwards`, `back`, `backward`, `backwards`,
`left`, `right`, `up`, or `down`. `anchor` is `center` by default and may be a
face symbol (`front`, `back`, `left`, `right`, `top`, or `bottom`) or a list of
orthogonal faces. `stl` and other arbitrary solids use their bounding box for
anchoring. `segments` controls radial tessellation of curved primitives.

`material` defaults to the current `with-material` value. `precedence`
defaults to 10 for dielectrics and 20 for PEC/conductors. A conductive sheet
inherits its material's absolute default foil thickness when present;
otherwise `thickness` is required. `mesh-edges` defaults to `metal` for metal
sheets. Ports default to `model-impedance`, use wavelength/1000 for omitted
dimensions, and receive automatic precedence between touching dielectric and
metal geometry.

An idiomatic two-port microstrip fixture therefore needs very few settings:

```racket
(with-scale millimeters
  (with-material fr4
    (cuboid size '(80 50 1.6) anchor bottom))
  (with-material copper
    (sheet rect size '(80 50))
    (move back 20 up 0.8)
    (port up name input gap 1.6 size 3)
    (move up 0.8)
    (with-traces 3 (move forward 40))
    (move down 0.8)
    (port up name output gap 1.6 size 3)))
```

The one-argument `(cylinder radius)` remains the wire-warp mapper documented
in section 9. Supplying solid settings selects the solid primitive instead.
`read-stl-solid` is the procedural `(read-stl-solid path)` reader; it returns
an unregistered Manifold solid for CSG use.

### Planar turtle traces: `(with-traces width settings ... body ...)`

`with-traces` sweeps a constant-width conducting sheet along ordinary turtle
movements. It is the planar-sheet counterpart to `with-wire`:

```racket
(with-traces width
  [name value] [material material] [thickness length]
  [priority integer | precedence integer]
  [join (miter | bevel)] [miter-limit factor]
  body ...+)
```

The width, explicit thickness, and all turtle movement are interpreted in the
active `with-scale`. `miter-limit` defaults to 4, `join` to `miter`, material
to the current solid material, and name to a fresh scene-local symbol.

```racket
(with-scale millimeters
  (with-traces 3
    name resonator
    material copper
    (move forward 20)
    (turn left 45)
    (move forward 12)
    (turn left 135)
    (move forward 8)))
```

The path may turn through arbitrary angles, but all movement must remain in
the globally aligned XY, XZ, or YZ plane in which the scope began. Leaving the
plane, branching with `from-here` or `push`/`pop`, nesting `with-traces`, or
mixing active wire construction into the scope is an error. Returning to the
starting point creates a closed trace with an open center rather than filling
the loop. Open paths have butt ends.

Corners default to `join miter` with `miter-limit 4`; an excessively long
miter falls back to a bevel. `join bevel` requests bevels directly. Other
settings are `name`, `material`, `thickness`, `precedence`, and `priority`.
The catalog `copper` material supplies its 35-micrometer foil thickness and
normal conductor precedence when those settings are omitted.
One scope creates one sheet and has one width. Adjacent scopes are independent
and are not joined automatically.

OpenEMS examines the completed outline. A wholly axis-aligned orthogonal trace
receives the normal 1/3-inside, 2/3-outside metal-edge treatment. An outline
with oblique edges receives enough extra rectilinear coordinates to resolve
the trace width; a mixed outline uses both strategies where applicable. The
profile minimum is three cells across a trace for `draft` and five for
`standard`. Oblique copper still has the unavoidable Yee-grid staircase, so
mesh convergence remains important for tight bends and electrically narrow
features.

### CSG bodies: `with-body`, `union`, `difference`, `intersect`, and `hull`

`with-body` collects unnamed solid primitives into one Manifold body and then
registers that result in the solid scene. Settings precede the solid forms and
use the same material, precedence, metal-thickness, and anchor vocabulary as
ordinary bodies:

```racket
(with-body [name value] [material material]
           [priority integer | precedence integer]
           [anchor anchor] [metal-thickness length]
           [form (solid | surface)]
  solid-form ...+)

(union solid-form ...+)
(difference base-solid cutter-solid ...+)
(intersect solid-form solid-form ...)
(hull solid-form ...+)
(scale factor solid-form ...+)
```

```racket
(with-scale millimeters
  (with-body name shield
    material aluminum
    metal-thickness 2
    precedence 100
    anchor bottom
    (difference
      (cuboid size (list board-length board-width 12) anchor bottom)
      (from-here
        (move up 2)
        (cuboid size (list (- board-length 4)
                           (- board-width 4)
                           10)
                anchor bottom)))))
```

The primitives inside `with-body` are unnamed because only the completed body
is added to the scene and shown in its legend. The available primitives are
`cuboid`, `sphere`, `cylinder`, `capsule`, and `stl`; each retains its ordinary
dimension, segment, and bounding-box anchor settings. Turtle movement and
rotation place each primitive. The scope restores the turtle afterward, just
like `from-here`.

Top-level forms within `with-body` are unioned implicitly. An explicit `union`
is useful when a group must occupy one operand position inside another Boolean
operation. `difference` treats its first solid as the base and the remaining
solids as cutters. `intersect` requires at least two solids. `hull` produces
one convex hull around its children. Intermediate solids are temporary and do
not become separate model objects.

The ordinary one-argument `(scale factor)` operation remains stateful: it
changes the scale of subsequent turtle movement and primitives. Within a body,
`(scale factor solid-form ...)` instead uniformly scales the collected forms
about the turtle's current point. Per-axis stretching is deliberately reserved
for a future `stretch` operation.

`with-body` also accepts `form solid` (the default) or `form surface`.
`form solid` retains the completed Manifold as an OpenEMS STL volume. The
OpenEMS mesher adds an interior coordinate when a PEC body's bounding extent
would otherwise have fewer than two cells. Build hollow PEC enclosures from
separate wall bodies when relying on this rule: a completed Boolean
`difference` exposes the enclosure's outer bounds, not each wall thickness.

`form surface` is an opt-in PEC-only representation. The exporter converts
all surviving triangles of the final Manifold boundary—including inner faces
created by `difference`—to native CSXCAD metal polygons and adds their planes
as critical mesh coordinates. Every facet must be axis-aligned after the
model-to-solver transform. Omitting `material` forces PEC and prints a notice;
explicit `material pec` is allowed, and an explicit non-PEC material is an
error. The manifest records `form`, `material_source`, and
`representation "pec-boundary-surfaces"`.

### `(mesh-point)` and `(mesh-plane xy|xz|yz)`

Registers hard rectilinear-mesh constraints at the turtle's current global
position. `mesh-point` requires X, Y, and Z mesh coordinates through that
point. `mesh-plane xy` requires its global Z coordinate, `mesh-plane xz`
requires its global Y coordinate, and `mesh-plane yz` requires its global X
coordinate. The constraint is captured immediately; `from-here` restores the
turtle state but does not remove it. An enclosing `with-scale` affects the
movement used to reach the point and does not scale the captured coordinate a
second time.

OpenEMS transforms constraints with the rest of the scene and supplies them to
`SmoothMeshLines` before automatic metal-edge refinement. A point remains
valid under any rigid transform. A plane whose global normal becomes oblique
to the solver's Yee grid after automatic one-port alignment is an error.
Manual coordinates take precedence when automatic metal-edge lines conflict,
and the generated driver verifies that smoothing retained every requested
coordinate before starting FDTD. Closely spaced manual constraints are honored
and can therefore reduce the global Courant timestep substantially.

Constraints do not expand the simulation domain and must fall within its
automatically padded bounds. They are recorded in the reproducibility manifest
and are cleared by `clear-bodies` and `reset-model!`.

The lower-level `(add-mesh-plane plane-symbol)` accepts `'xy`, `'xz`, or `'yz`.
`current-mesh-constraints` is a parameter containing the constraint list;
prefer `(model-mesh-constraints)` for read-only inspection and
`clear-mesh-constraints` for removal.

```racket
(add-mesh-plane 'xy)
(map mesh-constraint-kind (model-mesh-constraints)) ; '(plane)
```

The lower-level Manifold registration interface remains available for CSG and
generated geometry:

Import Manifold with a prefix, then register solids and an explicit port:

```racket
(require (prefix-in m: manifold))

(body name radiator
  material pec
  geometry shape
  priority 20
  anchor center)

(port up
  name "feed"
  impedance 50
  gap {0.5 * millimeter}
  width {0.5 * millimeter}
  depth {0.5 * millimeter}
  priority 15)
```

The complete procedural registration signatures, useful to geometry
libraries, are:

```racket
(add-body name-or-#f material manifold-solid
          #:priority [integer-or-#f #f]
          #:precedence [integer-or-#f #f]
          #:coordinates [(or 'local 'world) 'local]
          #:anchor [anchor 'origin]
          #:metal-thickness [length-or-#f #f]
          #:form [(or 'solid 'surface) 'solid]
          #:material-source [symbol 'explicit-or-context])

(add-sheet name-or-#f material point-list
           #:priority [integer-or-#f #f]
           #:precedence [integer-or-#f #f]
           #:coordinates [(or 'local 'world) 'local]
           #:mesh-edges [(or #f 'exact 'metal) #f]
           #:thickness [length-or-#f #f])

(add-lumped-port direction
                 #:name [name-or-#f #f]
                 #:impedance [ohms (model-impedance)]
                 #:gap [length automatic]
                 #:width [length automatic]
                 #:depth [length automatic]
                 #:anchor [(or 'start 'center 'end) 'center]
                 #:priority [integer-or-#f #f]
                 #:precedence [integer-or-#f #f])

(add-lumped-element direction
                    #:name [name-or-#f #f]
                    #:resistance [ohms-or-#f #f]
                    #:inductance [henries-or-#f #f]
                    #:capacitance [farads-or-#f #f]
                    #:topology [(or #f 'series 'parallel) #f]
                    #:caps [boolean #t]
                    #:gap length #:width length #:depth length
                    #:anchor [(or 'start 'center 'end) 'center]
                    #:priority [integer-or-#f #f]
                    #:precedence [integer-or-#f #f])
```

Use either `#:priority` or `#:precedence`; they are aliases and cannot both be
present. `add-sheet/world-polygons` is the trace engine's lower-level entry:

```racket
(add-sheet/world-polygons name-or-#f material polygons boundaries normal
                          #:priority [integer-or-#f #f]
                          #:precedence [integer-or-#f #f]
                          #:mesh-edges [(or 'exact 'metal) 'metal]
                          #:thickness [length-or-#f #f]
                          #:trace-width [length-or-#f #f])
```

Its polygons, boundaries, and normal are already-global `point3` values; most
programs should use `with-traces` instead.

Procedural primitive registration mirrors the contextual constructors:

```racket
(add-cuboid name-or-#f length width height
            #:material [material (current-solid-material)]
            #:precedence [integer-or-#f #f]
            #:metal-thickness [length-or-#f #f]
            #:anchor [anchor 'center])
(add-cuboid/size name-or-#f size same-keywords ...)
(add-solid-sphere name-or-#f radius same-keywords ...
                  #:segments [integer-or-#f #f])
(add-solid-cylinder name-or-#f length diameter same-keywords ...
                    #:segments [integer-or-#f #f])
(add-solid-capsule name-or-#f cylindrical-length diameter same-keywords ...
                   #:segments [integer-or-#f #f])
(add-rect-sheet name-or-#f length width
                #:material [material (current-solid-material)]
                #:precedence [integer-or-#f #f]
                #:thickness [length-or-#f #f]
                #:mesh-edges [(or #f 'exact 'metal) #f])
(add-rect-sheet/size name-or-#f size same-keywords ...)
```

`size` may be a list or vector containing three dimensions for a cuboid or two
for a rectangle. These calls register and return the completed scene object;
the DSL forms are normally clearer in model source.

Bodies use the current turtle frame unless `coordinates world` is supplied.
The scene owns a transformed copy; the caller remains responsible for closing
the original Manifold handle. `anchor origin` is the default; `anchor center`
first places the center of the solid's axis-aligned bounding box on the turtle,
which is convenient for Yagi elements and arbitrary CSG assemblies. Manifold
primitives such as `m:cylinder` and `m:cube` also accept `#:center? #t` when
constructor-level centering is preferable. `clear-bodies` closes and clears
registered bodies, sheets, and their subordinate ports.

Dielectric volumes use `(dielectric name substrate er 4.4)` or the equivalent
keyword constructor. Compact loss specifications are:

```racket
loss (narrow 0.015 1000)
loss (broad 0.015 200 2000)
loss (broad 0.015 200 2000 at 1000)
loss (relax (0.42 8e-11) (0.18 1.7e-10))
```

Frequencies are MHz. `narrow` converts the loss tangent to constant
conductivity at its reference frequency. `broad` constructs a causal
Djordjevic--Sarkar approximation represented by Debye relaxation terms; its
reference defaults to `model-frequency`, and the optional `at` value overrides
that default. In `relax`, `er` is epsilon at infinite frequency and each pair
is `(delta-epsilon relaxation-time-seconds)`. The older `loss-tangent` and
`loss-frequency` settings remain compatible aliases for `narrow`.

The concise and procedural material APIs expose the same complete set of
parameters:

```racket
(dielectric [name value]
            (er value | relative-permittivity value)
            [ur value | relative-permeability value]
            [loss loss-spec]
            [loss-tangent value] [loss-frequency ('model | MHz)]
            [conductivity siemens-per-metre])

(make-dielectric #:name [name 'dielectric]
                 #:relative-permittivity epsilon-r
                 #:relative-permeability [mu-r 1]
                 #:loss-tangent [tangent #f]
                 #:loss-frequency [reference 'model]
                 #:loss [loss-spec #f]
                 #:conductivity [siemens-per-metre #f])

(conductor [name value] conductivity siemens-per-metre
           [sheet-thickness metres])

(make-conductor #:name [name 'conductor]
                #:conductivity siemens-per-metre
                #:sheet-thickness [metres #f])

(make-narrow-loss tangent [reference-frequency 'model])
(make-broad-loss tangent lower-mhz upper-mhz
                 #:reference-frequency [reference 'model])
(make-relaxation-loss (list (list delta-epsilon seconds) ...))
(model-dielectric prototype [factor 2])
```

Use either `#:loss` or the compatibility `#:loss-tangent` pair. A narrow loss
tangent and direct conductivity are alternative models and cannot be combined;
broad/relax loss may coexist with conductivity when a separate baseline
conduction term is intentional. A loss frequency is in MHz. Relative
permeability defaults to 1. A catalog conductor thickness is always SI metres
and is not affected by `with-scale`.

```racket
(define low-loss-board
  (make-dielectric
   #:name 'low-loss-board
   #:relative-permittivity 3.55
   #:loss (make-broad-loss 0.0027 100 6000
                           #:reference-frequency 1000)))

(define half-ounce-copper
  (make-conductor #:name 'half-ounce-copper
                  #:conductivity 5.8e7
                  #:sheet-thickness 17.5e-6))
```

`conducting-sheet-material` is retained for compatibility:

```racket
(conducting-sheet-material #:name [name 'conducting-sheet]
                           #:conductivity [value 0]
                           #:thickness [value 0])
```

Unlike normal conductor catalog thickness, this older constructor's thickness
is scale-relative. New code should normally use `conductor`/`make-conductor`.
`material-default-precedence` accepts an `em-material` and returns 10 for a
dielectric or 20 for PEC/conductor material.
`(material-loss-tangent loss-or-#f)` returns the tangent stored by a narrow or
broad loss model and returns `#f` for no loss or explicit relaxation poles.

`(model-dielectric prototype [factor])` derives a broadband material from a
lossy prototype. Its reference is the model frequency and its fit range is
`model-frequency/factor` through `model-frequency*factor`; the factor defaults
to 2 and must exceed 1. Resolution is deferred until OpenEMS export so one
geometry can be reused under different simulation profiles. A warning is
printed when the requested sweep escapes the fit range.

`silver`, `copper`, `gold`, `aluminum`, `brass`, and nonmagnetic nominal
`steel` are reusable finite-conductivity materials. `copper` includes a
35-micrometer (one-ounce PCB foil) default for sheets and traces. That default
is an absolute material property in meters and is never multiplied by
`with-scale`. An explicit geometry `thickness` overrides it and does follow the
active scale. Custom defaults use, for example,
`(conductor name foil conductivity 2.4e7 sheet-thickness 18e-6)`.
`conducting-sheet-material` remains as a compatible constructor whose stored
thickness follows the older, scale-relative behavior. The sheet follows the
complete turtle frame, including arbitrary rotation.

Nominal dielectric constants are `air`, `fr4`, `fr4-vhf`, `fr4-uhf`,
`fr4-shf`, `ptfe`/`teflon`,
`rogers-4003c`, `rogers-4350b`, and `rogers-5880`. They provide convenient
room-temperature permittivity and loss-tangent values. The band-named FR4
materials use broadband ranges of 50--300, 300--3000, and 3000--10000 MHz;
define a custom dielectric for a specific vendor datasheet or frequency.

Finite-conductivity volume bodies use `material copper metal-thickness ...`.
Revision 1 accepts only solids whose triangulated boundary facets align with
the Yee grid after the model-to-solver transform; each boundary triangle is
exported as a conducting-sheet polygon, and every distinct surface plane is a
required mesh coordinate. When physical metal exceeds OpenEMS's recommended
500-micrometer sheet thickness, the backend uses ten skin depths as the
numerical thickness and records both values in the manifest; this keeps the
narrowband surface model inside the recommended range without changing model
geometry.
Non-axis-aligned finite-conductor or `form surface` facets raise an error
before the solver starts. PEC `form solid` bodies retain arbitrary STL
geometry.
Conductive sheets default to `mesh-edges metal`, which applies the openEMS
1/3--2/3 treatment to
an axis-aligned rectangular metal sheet: each in-plane edge is represented by
a line one-third of the local edge resolution inside and another two-thirds
outside. Use `mesh-edges exact` explicitly to put planes on the geometric
bounds instead. Other polygons and rotated sheets reject metal-edge treatment
explicitly. `with-traces` also inherits its material's standard precedence
when none is specified.

Port `priority`/`precedence` is optional. By default, the OpenEMS exporter chooses an
integer priority between touching dielectric and conductor geometry, following
the usual `dielectric < port < conductor` ordering. An explicit value overrides
that inference and is useful when a more complex overlap hierarchy requires
manual control. The effective value and whether it was automatic or explicit
are recorded in the simulation manifest.

### `(lumped-element direction setting value ...)`

Places an ideal two-terminal OpenEMS R, L, C, or compound RLC region centered
on the turtle. Its complete contextual signature is:

```racket
(lumped-element direction
  [name value]
  [resistance ohms] [inductance henries] [capacitance farads]
  [topology (series | parallel)] [caps boolean]
  gap length
  (size size | width width depth depth)
  [anchor (start | center | end)]
  [priority integer | precedence integer])
```

`direction` is its terminal axis. `gap` and either `size`, or both `width` and
`depth`, are required, as is at least one of `resistance`, `inductance`, and
`capacitance`. `name` is optional and otherwise generated. A scalar `size`
gives a square profile; a two-element list gives `(width depth)`. Like ports,
elements accept `anchor start`, `anchor center`, and `anchor end`:

```racket
(with-scale millimeters
  (lumped-element forward
    name coupling-network
    resistance {0.4 * ohms}
    inductance {1.2 * nanohenries}
    capacitance {2.2 * picofarads}
    topology series
    caps #t
    gap 1
    size 3
    anchor start))
```

When multiple electrical values are supplied, `topology series` or `topology
parallel` is required. A topology on a pure R, L, or C is harmless. `caps`
defaults to `#t`; specify `#f` explicitly to disable OpenEMS terminal caps.

Spatial dimensions follow `with-scale`; electrical quantities remain SI. All
six region faces become required mesh coordinates. The backend rejects a
component with a terminal face that provably does not touch conductive solid
or sheet geometry and requires its transformed frame to align with the Yee
grid. `precedence` overrides the normal automatic `dielectric < lumped feature
< conductor` choice. `clear-bodies` also clears lumped elements.

Export requires OpenEMS 0.37 / CSXCAD 0.7 or newer. Upstream installations
under `/usr/local` are found automatically; set `OPENEMS_ROOT` for another
installation prefix.

### `(simulate engine openems sweep '(start-mhz stop-mhz) profile profile-value ...)`

`simulate` is the compact, data-only frontend to `openems-sweep`. It does not
open plots. Its complete contextual signature is:

```racket
(simulate engine openems
          sweep (list start-mhz stop-mhz)
          [profile simulation-profile]
          [octave path-or-#f]
          [keep-artifacts boolean]
          [progress boolean]
          [record-radiation boolean]
          [record-fields field-capture-request]
          [timeout seconds-or-#f])
```

`sweep` is required and `profile` defaults to `standard`. `octave` defaults to
`#f` (use `octave-executable`, `OCTAVE`, or `PATH` discovery), artifact
retention and progress default to `#t`, radiation recording defaults to `#t`,
field recording defaults to disabled, and timeout defaults to `#f`
(unlimited). Numerical policy lives in the profile:

```racket
(define result
  (simulate engine openems
            sweep '(800 1050)
            profile draft
            keep-artifacts #t))

;; A network-only run can omit broadband NF2FF field recording.
(define network-result
  (simulate engine openems
            sweep '(650 1350)
            profile standard
            record-radiation #f))

(define convergence
  (derive-simulation-profile
   standard
   #:name 'convergence
   #:cells-per-wavelength 40
   #:minimum-dielectric-cells 8
   #:minimum-trace-cells 7))
```

`draft` uses lambda/20, four cells through thin dielectrics, three across
oblique traces, 100,000 maximum timesteps, and a -40 dB residual-energy
threshold. `standard` uses lambda/30, six dielectric cells, five across
oblique traces, 250,000 timesteps, and -50 dB. Both use 101 frequency
samples, mesh grading 1.4, half-wavelength padding, automatic metal-edge
resolution, and 24 segments around derived wire capsules.

`simulation-profile` is a transparent structure. Construct one directly in
the following field order, or more readably derive it with keywords:

```racket
(simulation-profile name frequency-steps cells-per-wavelength
                    minimum-dielectric-cells minimum-trace-cells
                    metal-edge-resolution mesh-grading padding-wavelengths
                    maximum-timesteps end-criteria wire-segments)

(derive-simulation-profile
 base
 #:name [name (simulation-profile-name base)]
 #:frequency-steps [count (simulation-profile-frequency-steps base)]
 #:cells-per-wavelength [count (simulation-profile-cells-per-wavelength base)]
 #:minimum-dielectric-cells [count (simulation-profile-minimum-dielectric-cells base)]
 #:minimum-trace-cells [count (simulation-profile-minimum-trace-cells base)]
 #:metal-edge-resolution [metres-or-#f (simulation-profile-metal-edge-resolution base)]
 #:mesh-grading [ratio (simulation-profile-mesh-grading base)]
 #:padding-wavelengths [count (simulation-profile-padding-wavelengths base)]
 #:maximum-timesteps [count (simulation-profile-maximum-timesteps base)]
 #:end-criteria [fraction (simulation-profile-end-criteria base)]
 #:wire-segments [count (simulation-profile-wire-segments base)])
```

Every omitted derivation keyword inherits from `base`. Frequency steps must be
at least 2; cell minima and timestep limits are positive exact integers;
grading is greater than 1; end criteria is between 0 and 1; and wire segments
is at least 3. For example, a convergence run that changes only mesh density
is:

```racket
(define dense
  (derive-simulation-profile standard
    #:name 'dense
    #:cells-per-wavelength 50
    #:minimum-dielectric-cells 10
    #:minimum-trace-cells 9))
```

`record-radiation` defaults to `#t`. Setting it to `#f` omits the six-face
time-domain NF2FF recording, reducing solver I/O and retained artifact size.
It does not suppress physical radiation or change the mesh, timestep, or
termination criterion. Network, port, dielectric-loss, and lumped-element
measurements remain available, but `radiation-pattern` and the radiated-power
portion of `power-budget` require a run made with radiation recording enabled.

`record-fields` accepts a solver-neutral `field-capture` request. The capture
frequency is in MHz and must lie inside the inclusive simulation sweep. An
omitted excitation selects the first port; otherwise name a port with the same
symbol or string used in the solid model. `#:max-samples` controls automatic
spatial subsampling per requested dump, not the FDTD mesh.

```racket
(define capture
  (field-capture
   #:frequency 1000
   #:excitation 'input
   #:current 'conductors
   #:volume '(electric magnetic)
   #:max-samples 250000))

(define result
  (simulate engine openems
            sweep '(850 1150)
            record-radiation #f
            record-fields capture
            keep-artifacts #t))
```

The complete constructors and accessors are:

```racket
(field-slice quantity axis position-metres)
  quantity : (or 'electric 'magnetic)
  axis     : (or 'x 'y 'z)

(field-capture #:frequency frequency-mhz
               #:excitation [port-name-or-#f #f]
               #:current [(or #f 'conductors) #f]
               #:slices [(listof field-slice?) '()]
               #:volume [(listof (or 'electric 'magnetic)) '()]
               #:max-samples [positive-exact-integer 250000])

field-slice?
field-slice-quantity
field-slice-axis
field-slice-position
field-capture?
field-capture-frequency
field-capture-excitation
field-capture-current
field-capture-slices
field-capture-volume
field-capture-max-samples
```

At least one current, slice, or volume request is required. Field-slice coordinates are
expressed in the model's user coordinate system and must transform to an
axis-aligned Yee-grid plane. Planar sheets use direct `rot(H)` and normal-`D`
captures. Triangulated PEC, STL, CSG, and finite-conductivity boundary bodies
use paired thin-shell `H` and `D` captures. The report reconstructs complex
surface current as `K = n × (H_out - H_in)` and free surface charge as
`rho_s = n · (D_out - D_in)`. For a closed PEC volume, the interior terms are
zero and the exporter records one-sided reconstruction metadata.

Solid-body shell captures share `#:max-samples` with other requested dumps.
Their manifest entries identify the associated geometry, physical sampling
offset, whether both sides are used, units, and phasor convention. This is a
spatial interpolation of Yee-grid fields onto the rendered surface, not a
claim that openEMS solved directly at each display vertex.

`#:volume` records cell-centered complex phasors throughout the padded
simulation domain. A report can derive X-, Y-, or Z-normal planes at any
position from the same data and interpolate continuously between retained
voxel planes. `#:max-samples` is the spatial voxel budget for each requested
quantity; electric and magnetic fields use the same retained grid. The
exporter reduces the longest axis first, which normally preserves the more
densely refined transverse mesh of a transmission line. This subsampling only
affects retained report data, never the FDTD mesh or solver result.

Captured complex phasors are normalized to one watt of incident power at the
selected excitation and frequency. The manifest records the reconstruction
convention as `instantaneous = real(phasor * exp(+j*phase))`, coordinates,
units, component order, normalization, and source dump details.

### `(write-html-report result destination [#:title title-or-#f])`

Writes a single self-contained interactive HTML report and returns its complete
path. `result` must be an `openems-sweep-result` or
`openems-multiport-result` created with `record-fields`; its retained artifacts
must still be available. `destination` is a path string. `#:title` defaults to
the model title recorded in the manifest.

```racket
(define report-path
  (write-html-report result "scratch/dipole-report.html"
                     #:title "One-watt dipole current"))
```

The report embeds geometry, gzip-compressed complex float arrays, metadata,
Three.js, and all controls. It opens directly from a `file:` URL in a modern
browser and performs no network fetch. Planar conductors offer `|current|`,
`dir(current)`, and surface-charge color modes. Current is width-integrated for
the primary presentation so ideal PEC edge crowding does not consume the
palette; charge comes from a companion normal electric-flux dump. Adjacent
station colors are interpolated across display triangles without changing the
underlying capture resolution.
Planar conductor layers also provide an independent current-map choice.
`transport current` retains the width-integrated station presentation used to
suppress ideal PEC edge crowding on narrow antenna strips. `surface density`
colors the two-dimensional Yee-cell mesh from its local samples, preserving
lateral return-current structure on PCB ground planes. `auto` selects surface
density for the whole planar group when any conductor is a broad sheet and
otherwise selects transport current, keeping normalization and units
consistent within the displayed group. No additional solver capture is needed.
Triangulated conductor surfaces additionally offer a combined exploratory mode:
instantaneous charge polarity controls hue while instantaneous current
magnitude adds a neutral white highlight. The two quantities retain independent
normalization and units; the combination is a visual encoding, not a derived
physical scalar.

Report metadata includes solver termination/timing, mesh dimensions and
spacing, ports and reference impedances, the complete one-port sample or
multiport S-parameter tables, and exact-frequency port, dielectric, and lumped
power results. Power rows retain their absolute solver values and normalized
ratios relative to one watt incident at the selected capture excitation.

Co-located electric and magnetic captures on the same physical plane are
grouped into one selectable slice with an E/H toggle. Field views include
static total and plane-tangential phasor envelopes, instantaneous tangential
intensity, animated signed normal or user x/y/z components, denser
instantaneous vectors, and projected instantaneous field lines. Static
envelopes mute phase and playback controls. The normal component is the
Cartesian component named by the selected plane axis. Every scalar field view
may be linear or logarithmic with an adjustable floor; signed components use a
symmetric logarithmic transfer that preserves polarity. Vector length,
field-line visibility, and field-line color honor the same transfer. Opacity is
adjustable.
The default slice-auto range uses the
98th percentile of the complex field amplitude on the displayed plane so a
PEC- or feed-adjacent outlier cannot make the radiating field disappear. This
range is phase-independent and does not flicker during animation. A volume
range option preserves one absolute color scale while the plane moves. E uses
a warm palette and H a cool palette. The complete simulation plane is
displayed, with a toggleable dashed outline marking the inner PML boundary.

Volumetric E/H captures add a model-coordinate X/Y/Z plane selector and a
position slider. The viewer interpolates complex components before deriving
magnitude, signed components, or instantaneous vectors, preserving phase
relationships through the RF cycle. Fixed `#:slices` remain useful when a
small report needs only predetermined cross-sections. Field lines are
streamlines of the instantaneous field projected into the selected plane; they
are a visualization aid, not particle trajectories or independent solver data.

Full-volume captures also provide static-envelope and instantaneous 3-D
isosurfaces for E and H, plus time-average and instantaneous power-magnitude
isosurfaces when both fields are present. These heavier views are opt-in and
appear last in the view menu. Their dedicated dB threshold is linearly
interpolated along the retained nonuniform Yee-cell edges by marching
tetrahedra; it is not snapped to grid points. The browser bounds the traversed
cell count and throttles animated mesh replacement. This remains an
exploratory spatial overview; movable planes and the existing numerical plots
remain the clearer tools for quantitative inspection.

When co-registered E and H captures are present, `POWER` derives the Poynting
vector without another solver run. Time-average power uses
`0.5 Re(E × conjugate(H))`; instantaneous power reconstructs E and H at the
selected phase before taking `E(t) × H(t)`. Views include magnitude, signed
through-plane flow, vectors, and plane-projected flow lines. The detail line
estimates integrated time-average signed power over the non-PML portion of the
selected plane and reports it in watts. Solver port/power results remain the
authoritative accounting. A `CURRENT` checkbox overlays conductor current
on a field or power slice. Color legends retain physical units and maxima;
scale choices affect presentation only.

See `docs/HTML-REPORTS-M0.md` for schema boundaries, normalization, packaging,
security, and the limitations of direct surface-current capture.

### `(radiation-pattern result keyword-arguments ...)`

Runs or reuses NF2FF postprocessing for a completed simulation result. It is
the high-level name for `openems-radiation-grid` and accepts the same frequency,
excitation, angular resolution, Octave, reuse, and timeout keywords.

### `(power-budget result keyword-arguments ...)`

Returns an `openems-power-budget` at the model frequency. The accepted input
power is divided into power delivered to passive output ports, NF2FF radiated
power, volumetric dielectric heat, resistive lumped-element heat, and a final
conducting-sheet/numerical remainder. Port powers come directly from
`calcPort`; the dielectric subtotal comes from an OpenEMS raw-SAR dump and
`CalcSAR`. Ideal capacitors and inductors dissipate no average power.

```racket
(define budget
  (power-budget result #:excitation 'input))
(display-power-budget budget)
;; Or retain the formatted report without printing it:
(define report-text (format-power-budget budget))
```

Optional keywords are `#:frequency`, `#:excitation`, `#:theta-step`,
`#:phi-step`, `#:octave`, `#:reuse?`, and `#:timeout`. Revision 1 power
accounting records narrowband conductivity loss only at `model-frequency`, so
an explicit frequency must equal that value. Dispersive dielectric relaxation
heat is deliberately excluded and remains in the conductor/numerical
remainder. NF2FF postprocessing is performed lazily and cached just as it is
for `radiation-pattern`.

The exact related signatures are:

```racket
(power-budget result
              #:frequency [MHz-or-#f #f]
              #:excitation [port-name-or-#f #f]
              #:theta-step [degrees 2]
              #:phi-step [degrees 2]
              #:octave [path-or-#f #f]
              #:reuse? [boolean #t]
              #:timeout [seconds-or-#f #f])
(format-power-budget budget)
(display-power-budget budget [output-port (current-output-port)])
```

`format-power-budget` returns a string; `display-power-budget` writes that
report to the selected output port and returns `void`.

Raw watts reflect OpenEMS's solver excitation amplitude; percentage and dB
columns are normalized to incident power. The final conductor category also
contains PML, discretization, and numerical closure error because conducting
sheets use a surface-loss model not represented in the volumetric loss dump.
Use mesh convergence to judge that remainder before treating it as measured
copper or aluminum heat.

### `(openems-sweep start-mhz stop-mhz keyword-arguments ...)`

The current executable slice supports ordinary Turtle wires, PEC and lossy,
lossless, or Debye-dispersive dielectric volume bodies, planar PEC/conducting sheets,
rectilinear finite-conductivity body boundaries, and one or more derived or
explicit lumped ports. One-port runs return an
`openems-sweep-result`; multiport runs return an `openems-multiport-result`
containing the complete complex S-matrix and active input impedance for every
excitation and requested frequency. Materials that
overlap or touch through a sheet interface require distinct explicit CSXCAD
priorities. The mesh wavelength is reduced by the largest dielectric
`sqrt(epsilon-r * mu-r)` in the scene, including the conservative static-limit
permittivity of dispersive materials.

```racket
(openems-sweep
 800 1050
 #:steps 101
 #:cells-per-wavelength 20
 #:minimum-dielectric-cells 4
 #:minimum-trace-cells 3
 #:metal-edge-resolution #f ; defaults to half the wavelength cell limit
 #:mesh-grading 1.4
 #:padding-wavelengths 0.5
 #:max-timesteps 100000
 #:end-criteria 1e-5
 #:wire-segments 24
 #:octave #f
 #:keep-artifacts? #t
 #:progress? #t
 #:record-radiation? #t
 #:field-capture #f
 #:timeout #f)
```

This is the complete signature and shows every default. Start and stop are
positive MHz values with stop greater than start; `#:steps` includes both
endpoints. `(octave-executable [path-or-#f])` is the process-wide default
executable parameter used when `#:octave` is `#f`:

```racket
(octave-executable "/opt/openems/bin/octave")
(define result (openems-sweep 800 1000 #:progress? #f))
```

Every wire edge becomes a physical Manifold capsule using its modeled
diameter. Connected and disconnected capsules are combined into one temporary
PEC body without changing the live centerline graph. A marked wire feed becomes
a physical gap and lumped port. Its default gap is
`max(wavelength/1000, wire-radius)`; a warning is printed when that gap exceeds
the marked edge's length. `#:wire-segments` controls capsule circular
tessellation and must be at least three.

The exporter derives diameter-aware mesh helpers for capsule wires. A
grid-aligned straight wire contributes transverse lines at its physical
boundaries. If a path bends or runs obliquely, every traversed mesh axis is
subdivided at no more than the thinnest participating wire diameter. This
keeps thin loops and curved wires electrically connected in the Cartesian
FDTD grid without imposing the same fine resolution throughout unrelated
axes. Rectilinear mesh planes are global, however, so a physically large
oblique path can still increase the cell count substantially. The exporter
prints its X/Y/Z helper-line counts and records `mesh_refinement` and
`mesh_helper_lines_by_axis` under `wire_conversion` in the run manifest.

With exactly one port, the backend rigidly rotates and translates the model
into the port's local Cartesian frame. With two or more ports, it performs no
automatic rotation: every port's direction, width, and depth axes must already
align with global X, Y, and Z. An unaligned multiport frame is an error naming
the offending port. The initial implementation also requires a common
reference impedance so voltage-wave ratios are unambiguous. Each port is
excited in an independent FDTD run while all other ports remain present,
unexcited, and terminated in that reference impedance.

The mesh settings are deliberately explicit numerical controls, not promises
of cross-backend equivalence. `#:cells-per-wavelength` controls the global
wavelength-based maximum cell dimension. `#:minimum-dielectric-cells` inserts
evenly spaced critical coordinates across a dielectric extent when that global
limit would otherwise produce fewer cells; its default is 4. The effective
value and resulting critical coordinates are retained in the manifest.
`#:minimum-trace-cells` similarly resolves the width of turtle traces whose
outline contains oblique edges; wholly orthogonal traces retain ideal
metal-edge treatment without this extra refinement. Its default is 3. The
optional `#:metal-edge-resolution` is an absolute distance in metres used by
all sheets marked `mesh-edges metal`; `#f` follows the official patch tutorial
and uses half the wavelength-based maximum cell size. Metal-edge constraints
are generated before `SmoothMeshLines`. If a shifted line would create a
near-coincident sliver, the exporter reuses an existing line at that edge or
falls back to the exact geometric edge, with a warning. The
generated Octave driver reports exact mesh dimensions and cell count before
starting OpenEMS. The default `#:timeout #f`
allows long simulations to finish and remains interruptible with Ctrl-C.
By default a non-modal progress window follows the timestep, solver speed, and
residual-energy reports written to `octave.stdout`. A live history graph keeps
0 dB at the top, includes the configured stop threshold, and expands its time
and energy axes to retain every reported sample. Independent multiport
excitations are drawn as separate line segments. Its **Cancel simulation**
button terminates the complete Octave/OpenEMS process group, including all
remaining excitations. Multiport progress reports the current excitation and
aggregate completion. A cancelled call returns the corresponding result type
with empty samples and records
`"cancelled"` in the manifest status; retained artifacts remain available for
diagnosis. Closing the window merely hides it and does not cancel OpenEMS. Use
`#:progress? #f` for batch runs or when terminal-only output is preferred. If
no graphical display is available, the simulation automatically continues
without the popup and reports the GUI initialization error. The artifact
directory is printed before Octave starts, so `model.xml`, logs, and live
stdout are discoverable during a long run.

Successful and failed runs carry an artifact directory containing STL bodies,
the Octave driver, CSXCAD XML, mesh lines, raw probes, logs, results, and a
reproducibility manifest. Sheet polygons, their transforms, complete material
properties, and dielectric-adjusted mesh values are recorded in that manifest.
Call `openems-close!` to release retained artifacts. For a result created by
`openems-sweep`, this removes its temporary directory. For a result opened by
`openems-load-artifacts`, it only invalidates that in-memory handle; the
caller-owned directory remains on disk.
The driver also records a broadband time-domain NF2FF box. To keep the eight
PML cells and the NF2FF surface outside all conductors, the backend enlarges a
requested domain padding when necessary; the effective padding is recorded in
the manifest.

OpenEMS one- and multiport results can be passed directly to `show-vswr-sweep`,
`show-return-loss-sweep`, `show-impedance-sweep`, and `show-smith-chart`.
Multiport use shows each diagonal reflection/input-impedance term.
`show-s-parameter-magnitude` and `show-s-parameter-phase` display the complete
matrix.

### `(openems-load-artifacts directory)`

Reconstructs an `openems-sweep-result` or `openems-multiport-result` from a
retained OpenEMS artifact directory. It reads the reproducibility manifest and
saved network CSV files; it does not run OpenEMS or Octave.

```racket
(define recovered
  (openems-load-artifacts
   "/var/tmp/antenna-turtle-openems17915763761791576376090"))

(show-return-loss-sweep recovered)
(show-impedance-sweep recovered)
(show-smith-chart recovered)

(define recovered-pattern
  (openems-radiation-grid recovered))
(show-radiation-pattern-opengl recovered-pattern #:palette 'inferno)
```

If the requested frequency and angular grid match an existing NF2FF CSV,
`openems-radiation-grid` reuses it. Otherwise it performs NF2FF
postprocessing from the retained time-domain fields, which is much quicker
than rerunning FDTD. Loaded directories are treated as caller-owned and are
never deleted by `openems-close!`.

### `(openems-close! result-or-run-or-artifacts)`

Accepts an `openems-sweep-result`, `openems-multiport-result`,
`openems-run-info`, or `openems-artifacts`. It deletes a solver-created
temporary directory, leaves a directory loaded by `openems-load-artifacts`
on disk, marks the artifact handle unavailable, and returns `void`.

```racket
(define run (openems-sweep 800 1000 #:keep-artifacts? #t))
(define artifacts
  (openems-run-info-artifacts (openems-sweep-result-run run)))
(displayln (openems-artifacts-directory artifacts))
;; Inspect or copy the directory before releasing it.
(openems-close! run)
```

### `(openems-radiation-grid result keyword-arguments ...)`

Transforms the retained near fields from an `openems-sweep-result` or
`openems-multiport-result` into the same three-dimensional pattern grid
consumed by the existing radiation viewers:

```racket
(define pattern
  (openems-radiation-grid
   result
   #:frequency #f       ; model frequency; or MHz or 'best-match
   #:excitation #f      ; first port, or a port name for multiport data
   #:theta-step 2
   #:phi-step 2
   #:octave #f
   #:reuse? #t
   #:timeout #f))

(show-radiation-pattern-opengl pattern #:palette 'inferno)
;; The Plot3D viewer works too:
;; (show-radiation-pattern-3d pattern)
```

NF2FF postprocessing does not rerun FDTD. With the default `#:reuse? #t`, a
matching saved CSV is loaded directly; use `#:reuse? #f` to force fresh NF2FF
postprocessing. It may be repeated at arbitrary frequencies inside the
original sweep while the field artifacts remain available. The returned grid
is independent of those files and remains usable after `openems-close!`.
Directions and complex polarization components are rotated back from the
port-aligned solver frame into the user's original Turtle coordinate system.
The grid metadata records maximum directivity and radiated power. For this PEC
proof of concept the viewer's dBi scale is directivity; efficiency and realized
gain are not yet reported.

### `(show-s-parameter-magnitude result [#:legend? #f])`

### `(show-s-parameter-phase result [#:legend? #f])`

Display every term of an `openems-multiport-result`. Labels include both the
conventional matrix index and named direction, such as
`S21 (output <- input)`. Phase is unwrapped independently for each term. Both
views retain left-drag zoom and right-drag sample inspection.

All interactive 2-D plots put their legend in a separate, collapsible side
panel. The panel starts hidden; `#:legend? #t` starts a window with it visible.
The window's **Show legend** checkbox can reveal it later. Right-click or right-drag places
a cursor on the nearest measured sample and writes its complete value into a
two-line status area beneath the plot. Inspection text therefore cannot cover
the data or extend beyond the plotting viewport.

### Measurement queries

The measurement API accepts native solver results directly and returns ordinary
Racket numbers and lists. Frequencies are in MHz, impedance is complex ohms,
phase and directions are in degrees, and gain and S-parameter levels are in
dB. An exact sampled frequency or direction is required by default. Add
`#:interpolate? #t` to interpolate; the API never extrapolates.

The complete one-port/network signatures are:

```racket
(impedance-at result frequency #:port [name #f]
              #:interpolate? [boolean #f])
(admittance-at result frequency #:port [name #f]
               #:interpolate? [boolean #f])
(resistance-at result frequency #:port [name #f]
               #:interpolate? [boolean #f])
(reactance-at result frequency #:port [name #f]
              #:interpolate? [boolean #f])
(reflection-at result frequency #:port [name #f]
               #:interpolate? [boolean #f])
(s11-db-at result frequency #:port [name #f]
           #:interpolate? [boolean #f])
(return-loss-at result frequency #:port [name #f]
                #:interpolate? [boolean #f])
(vswr-at result frequency #:port [name #f]
         #:interpolate? [boolean #f])
```

```racket
(impedance-at sweep 435 #:port 'input #:interpolate? #t)
(admittance-at sweep 435 #:port 'input #:interpolate? #t)
(resistance-at sweep 435 #:port 'input #:interpolate? #t)
(reactance-at sweep 435 #:port 'input #:interpolate? #t)
(reflection-at sweep 435 #:port 'input #:interpolate? #t)
(s11-db-at sweep 435 #:port 'input #:interpolate? #t)
(return-loss-at sweep 435 #:port 'input #:interpolate? #t)
(vswr-at sweep 435 #:port 'input #:interpolate? #t)
```

The `#:port` argument may be omitted when there is exactly one port. Port
symbols and strings with the same spelling match. Complex impedance and
reflection values use rectangular interpolation, so all derived quantities
remain mutually consistent. `s11-db-at` is the signed S11 magnitude; return
loss is its positive inverse.

OpenEMS multiport results expose named matrix queries. `#:from` names the
excited/input port and `#:to` names the measured/output port; omitting `#:to`
selects the diagonal reflection term for `#:from`.

```racket
(s-parameter-at result frequency
                #:from [input-name #f] #:to [output-name #f]
                #:interpolate? [boolean #f])
(s-parameter-db-at result frequency
                   #:from [input-name #f] #:to [output-name #f]
                   #:interpolate? [boolean #f])
(s-parameter-phase-at result frequency
                      #:from [input-name #f] #:to [output-name #f]
                      #:interpolate? [boolean #f])

(characteristic-impedance-at result frequency
                             #:input [name 'input]
                             #:output [name 'output]
                             #:zref [ohms 50]
                             #:interpolate? [boolean #t])
```

```racket
(s-parameter-at result 435
                #:from 'input #:to 'output #:interpolate? #t)
(s-parameter-db-at result 435
                   #:from 'input #:to 'output #:interpolate? #t)
(s-parameter-phase-at result 435
                      #:from 'input #:to 'output #:interpolate? #t)
```

`s-parameter-phase-at` returns principal phase in the range -180 through 180
degrees. `characteristic-impedance-at` derives the characteristic impedance of
a reciprocal two-port transmission-line fixture from its complete S matrix;
`#:zref` is the S-parameter reference impedance, not a forced answer.

```racket
(define z0
  (characteristic-impedance-at result 1000
                               #:input 'input #:output 'output))
(printf "fixture Z0: ~a ohms\n" z0)
```

Radiation queries accept either a `nec2c-pattern` cut or the backend-neutral
`nec2c-pattern-grid` returned by NEC2C and OpenEMS. Grid interpolation is
bilinear with azimuth wrapping at 360 degrees. Gain is interpolated in linear
power rather than directly in dB.

```racket
(gain-at pattern #:azimuth degrees #:elevation degrees
         #:component [component 'total] #:interpolate? [boolean #f])
(maximum-gain pattern #:component [component 'total])
(maximum-gain-direction pattern #:component [component 'total])
(front-to-back-ratio pattern #:component [component 'total]
                     #:interpolate? [boolean #t])
(front-to-side-ratio pattern #:component [component 'total])

(axial-ratio-at pattern #:azimuth degrees #:elevation degrees
                #:interpolate? [boolean #f])
(polarization-tilt-at pattern #:azimuth degrees #:elevation degrees
                      #:interpolate? [boolean #f])
(polarization-sense-at pattern #:azimuth degrees #:elevation degrees)
(e-field-at pattern #:azimuth degrees #:elevation degrees
            #:interpolate? [boolean #f])
```

```racket
(gain-at pattern #:azimuth 45 #:elevation 10
         #:component 'total #:interpolate? #t)
(maximum-gain pattern)                    ; dBi
(maximum-gain-direction pattern)          ; '(azimuth elevation)
(front-to-back-ratio pattern)             ; dB
(front-to-side-ratio pattern)             ; dB

(axial-ratio-at pattern #:azimuth 45 #:elevation 10)
(polarization-tilt-at pattern #:azimuth 45 #:elevation 10)
(polarization-sense-at pattern #:azimuth 45 #:elevation 10)
(define-values (e-theta e-phi)
  (e-field-at pattern #:azimuth 45 #:elevation 10))
```

F/B compares the maximum-gain direction with the same elevation at 180 degrees
opposite azimuth. F/S compares the main lobe with the worst (highest-gain)
available direction on the great circle 90 degrees from it. Both return
positive rejection ratios when the main lobe is stronger. For a grounded
pattern, F/S searches only the modeled upper hemisphere and never invents
below-ground data. Because a single cut cannot establish the worst side lobe
around that full circle, `front-to-side-ratio` requires a pattern grid.

Use these discovery helpers when writing backend-independent optimization or
reporting code:

```racket
(measurement-frequencies result)     ; sorted MHz values
(measurement-frequency-range result) ; '(minimum maximum), or #f
(measurement-ports result)            ; names in result order
(pattern-angular-resolution pattern)  ; '(azimuth-step elevation-step)
```

## 14. Export Functions

Each exporter validates pending-feed state and returns its output path. NEC2C
and MATLAB exports replace the requested file. MMANA has the update behavior
described below.

### `(export-nec2c path)`

Writes `CM`, `CE`, `GW`, ground, complex feed `EX`, and `EN` cards. Coordinates
are metres and receive the `model-height` Z offset. Free space emits `GE 0`.
Perfect ground emits `GE 1` and `GN 1`; real ground emits `GE 1` and a
Sommerfeld `GN 2` card carrying relative permittivity and conductivity.
Frequency, execution, and pattern cards are omitted; the NEC2C measurement API
decorates a temporary copy with them.

For grounded models, endpoints at Z=0 connect to their ground-plane image.
Geometry below Z=0 and wires lying along Z=0 are rejected before NEC2C runs.

### `(export-mmana path)`

For a new path, writes MMANA-GAL Basic geometry, explicit edge subdivision
counts, free-space defaults, `model-frequency`, and source declarations.

For an existing recognizable `.maa` file, it atomically replaces only the
Antenna Turtle-owned prefix:

- title and frequency;
- wire count and wire rows;
- sources;
- loads (currently reset to an empty load section).

The existing file is retained byte-for-byte from `*** Segmentation ***`
onward. This preserves MMANA's global segmentation and calculation settings,
including ground selection, height, material, reference impedance, and pattern
angles. It also preserves the existing line-ending style in the regenerated
prefix. If the expected MMANA sections cannot be recognized in order, export
raises an error and leaves the original file untouched.

### `(export-matlab path)`

Writes the approximate rectangular-ribbon representation, a `customAntenna`,
feed creation, geometry display, and directivity stub. Only center feeds are
supported.

### `(export-matlab-loft path)`

Writes closed square-prism loft geometry with bevel joints, flat terminal caps,
a four-edge feed contour, topology checks, diameter-sensitive meshing, display,
and directivity analysis.

Current loft restrictions:

- degree-two paths and loops only; no branch vertex;
- equal diameters among edges incident on one vertex;
- zero or one feed;
- center feed location only;
- no 180-degree path reversal;
- enough adjacent length to construct every bevel setback.

## 15. NEC2C Measurement and Plotting

The measurement functions execute NEC2C as a subprocess and return transparent
data structures. They never print results or open windows implicitly. A caller
may inspect, serialize, optimize against, or explicitly plot the returned
values.

NEC2C analysis honors the model's ground and height settings. Azimuth patterns
over ground require a nonnegative elevation. Elevation cuts default to the
above-ground arc from 0 through 180 degrees, and radiation grids contain theta
0 through 90 degrees rather than a physically nonexistent lower hemisphere.

### Executable selection

`(nec2c-executable [path-or-#f])` configures an executable for subsequent
runs. With the default `#f`, each operation tries the `NEC2C` environment
variable and then searches `PATH` for `nec2c`.

Every measurement function accepts these common keyword arguments:

```racket
#:model-path path-or-#f
#:executable path-or-#f
#:keep-artifacts? boolean
#:timeout seconds-or-#f
```

An explicit `#:model-path` is used as the base deck. Otherwise the most recent
`export-nec2c` path for the current model is reused. If neither exists, a base
deck is generated in a fresh temporary directory. Analysis cards are added to
a temporary copy; an explicit export is never modified.

Successful temporary artifacts are deleted unless `#:keep-artifacts? #t` is
specified. Failed or incomplete runs retain their directory and report its
path. The default `#:timeout #f` waits without a time limit, so an expensive
analysis is allowed to finish. Ctrl-C terminates the NEC2C subprocess and
interrupts the Racket program. Supply a positive number of seconds to opt into
an automatic timeout.

### `(nec2c-measure-impedance [frequency] common-keywords ...)`

Runs one frequency, defaulting to `model-frequency`, and returns a
`nec2c-impedance-result`. Its `samples` list contains one
`nec2c-feedpoint-sample` per simultaneously driven feed, including:

- feed name, frequency, NEC wire tag, and source segment;
- complex voltage and current;
- complex active impedance and admittance;
- input power.

For multiple feeds, impedance means the active impedance under the declared
simultaneous excitations. It is not an isolated port impedance or an
S-parameter measurement.

### `(nec2c-vswr-sweep start stop [#:steps count | #:step increment] common-keywords ...)`

Runs an inclusive additive frequency sweep. `#:steps` counts both endpoints;
`#:step` is a MHz increment that must land exactly on `stop`. The default is
101 samples.

Returns a `nec2c-sweep-result`. Each `nec2c-sweep-frequency` contains one
`nec2c-sweep-sample` per feed. A sample retains its raw feedpoint result and
adds reflection coefficient, return loss in dB, and VSWR calculated against
`model-impedance`. Infinite return loss and VSWR are represented with Racket's
positive infinity where mathematically appropriate.

### `(nec2c-azimuth-pattern ...)`

```racket
(nec2c-azimuth-pattern
 #:frequency [frequency (model-frequency)]
 #:elevation [degrees 0]
 #:start [degrees 0]
 #:stop [degrees 360]
 #:step [degrees 1]
 common-keywords ...)
```

Returns a `nec2c-pattern` in requested azimuth order at one fixed elevation.

### `(nec2c-elevation-pattern ...)`

```racket
(nec2c-elevation-pattern
 #:frequency [frequency (model-frequency)]
 #:azimuth [degrees 0]
 #:start [degrees (if grounded? 0 -90)]
 #:stop [degrees (if grounded? 180 270)]
 #:step [degrees 1]
 common-keywords ...)
```

Returns a vertical-plane `nec2c-pattern`. The runner samples both the requested
azimuth and its opposite bearing, then orders them as one continuous elevation
cut. Free space defaults to a full -90 through 270 degree circle. Grounded
models default to the above-ground 0 through 180 degree arc.

### `(nec2c-radiation-grid ...)`

```racket
(nec2c-radiation-grid
 #:frequency [frequency (model-frequency)]
 #:theta-step [degrees 5]
 #:phi-step [degrees 5]
 common-keywords ...)
```

Returns a `nec2c-pattern-grid` covering theta 0–180 degrees in free space or
0–90 degrees over ground, and phi 0 up to but excluding 360 degrees. The seam
is not duplicated.
The optional `#:frequency` defaults to the current `model-frequency`, including
the value established by `(model frequency ...)`.

Every `nec2c-pattern-sample` retains NEC theta/phi, friendly
elevation/azimuth, vertical/horizontal/total gain, axial ratio, polarization
tilt and sense, and complex E-theta/E-phi fields. NEC's unavailable-gain
sentinel is represented by `#f`.

### `(write-nec2c-html-report result destination ...)`

```racket
(write-nec2c-html-report
 result destination
 [#:pattern pattern-grid]
 [#:frequency frequency-mhz]
 [#:title title-or-#f])
```

Writes a single self-contained interactive HTML report for the wire-native
NEC2C backend and returns its complete path. The report contains three
workspaces: a combined 3-D view with independently switchable antenna geometry
and radiation pattern, the same Smith/S11/return-loss/VSWR and impedance plot
viewer used by the OpenEMS report, and an interactive azimuth-pattern cut at a
continuously selectable elevation angle. The 3-D pattern is centered on the
feedpoint, or the centroid of all feedpoints, and offers ARRL modified-log,
fixed-range dB, and linear-power radial scales plus the same MMANA, magma/SDR,
inferno, viridis, grayscale, and electric color ramps as the native OpenGL
viewer. Pattern opacity is adjustable. The radiation surface uses unlit colors,
so scene lighting cannot distort the selected ramp, and an on-screen legend
labels that ramp in both dB relative to the total-pattern maximum and absolute
dBi. Total, vertical, and horizontal components all share that total-pattern
reference; component surfaces therefore preserve their correct size relative
to each other instead of each being normalized independently. NEC's vertical
and horizontal values are the local spherical-polarization components E-theta
and E-phi, respectively; the controls label that basis explicitly rather than
implying fixed Cartesian axes. The 3-D camera is Z-up, matching Antenna
Turtle and NEC coordinates; screen orientation therefore no longer makes a
horizontal Y-axis element appear vertically erected.

The optional `3 dB COLOR BANDS` checkbox matches the native Racket viewer's
banded presentation: every display triangle receives the palette color for
the 3 dB interval containing its average relative gain. The legend changes to
the identical quantized ramp, while radial geometry and simulation data remain
unchanged.
The display-settings panel can be hidden for an unobstructed presentation view;
a compact `SHOW SETTINGS` button restores it without resetting the camera or
the selected visualization.
An independently switchable XYZ triad is placed at the pattern origin; its
legend identifies the example's X boom, Y elements, and physical Z vertical
without confusing screen-up with world-up. The canonical initial/reset view
keeps model Z perceptually screen-up and places model Y across the screen, so
the Yagi elements read horizontally without allowing camera roll to redefine
physical vertical.

The 2-D cut uses linear-power interpolation between NEC angular samples and
reports both the plotted value and absolute gain on hover. Relative cuts use
the total pattern's maximum gain as zero—even while viewing a polarization
component—and one stable radial range derived
from the complete grid, so moving the elevation control never renormalizes or
rescales the chart. The Smith chart permanently marks `model-frequency` in
addition to its movable selected-frequency marker. Network-plot hover values
appear in a dedicated strip outside the plotting area, leaving the traces
unobscured. Solver markers and interpolated Smith points report the same
frequency, impedance, normalized impedance, reflection coefficient, and sample
provenance. No network connection is
required to open the resulting file.

For an ordinary `nec2c-sweep-result`, supply the radiation grid explicitly:

```racket
(define sweep (nec2c-vswr-sweep 120 180 #:steps 121))
(define pattern
  (nec2c-radiation-grid #:frequency 150 #:theta-step 3 #:phi-step 3))

(write-nec2c-html-report
 sweep "scratch/yagi-report.html"
 #:pattern pattern)
```

A `nec2c-gain-sweep-result` already retains a complete grid at every swept
frequency, so `#:pattern` may be omitted. `#:frequency` then selects the
nearest retained grid and defaults to the model frequency. The geometry comes
from the current Antenna Turtle wire model, so write the report before resetting
or replacing that model. Unlike the solid/OpenEMS writer, NEC2C reports do not
require retained solver artifacts or the optional Manifold package.

### `(nec2c-gain-sweep start stop ...)`

```racket
(nec2c-gain-sweep
 start-mhz stop-mhz
 #:steps [count #f]       ; or #:step MHz
 #:theta-step [degrees 5]
 #:phi-step [degrees 5]
 common-keywords ...)
```

Runs one inclusive multi-frequency NEC2C analysis and returns a
`nec2c-gain-sweep-result`. The initial implementation requires exactly one
feed so that mismatch and realized gain are unambiguous. Each
`nec2c-gain-sweep-sample` retains the feedpoint measurement, reflection
coefficient, return loss, VSWR, complete `nec2c-pattern-grid`, maximum gain and
its `(azimuth elevation)` direction, maximum horizon gain, and both gains after
reference-impedance mismatch loss. Realized values use
`10 log10(1 - |Gamma|^2)` relative to `model-impedance`.

```racket
(define performance
  (nec2c-gain-sweep 300 2000 #:steps 101
                    #:theta-step 5 #:phi-step 5))

(show-gain-sweep performance)
(show-radiation-pattern-opengl
 (radiation-pattern-at-frequency performance 1660))
```

The result also implements the ordinary network measurement interface, so
`impedance-at`, `s11-db-at`, `return-loss-at`, `vswr-at`, and all four network
plots can consume it directly. Scalar gain queries optionally interpolate in
linear power:

```racket
(maximum-gain-at-frequency result frequency
                           #:interpolate? [boolean #f])
(realized-maximum-gain-at-frequency result frequency
                                    #:interpolate? [boolean #f])
(horizon-gain-at-frequency result frequency
                           #:interpolate? [boolean #f])
(realized-horizon-gain-at-frequency result frequency
                                    #:interpolate? [boolean #f])
(maximum-gain-direction-at-frequency result frequency)
(radiation-pattern-at-frequency result frequency)

;; Idiomatic queries:
(maximum-gain-at-frequency performance 906 #:interpolate? #t)
(realized-maximum-gain-at-frequency performance 906 #:interpolate? #t)
(horizon-gain-at-frequency performance 906 #:interpolate? #t)
(realized-horizon-gain-at-frequency performance 906 #:interpolate? #t)
(maximum-gain-direction-at-frequency performance 906)
(radiation-pattern-at-frequency performance 906)
```

Directions and complete patterns require an exact sampled frequency because
interpolating across a lobe switch would be misleading. Runtime and output
size grow with frequency count times theta count times phi count; use a coarse
5- or 10-degree grid to discover interesting modes, then inspect selected
frequencies with a finer grid.

### Plotting

These operations explicitly open Racket Plot windows. The four network plots
accept either a `nec2c-sweep-result` or an `openems-sweep-result`:

```racket
(show-vswr-sweep sweep [#:max-vswr #f] [#:legend? #f])
(show-return-loss-sweep sweep [#:floor-db #f] [#:legend? #f])
(show-gain-sweep gain-sweep [#:legend? #f])
(show-gain-and-match-sweep gain-sweep [#:legend? #f]) ; alias
(show-impedance-sweep sweep [#:legend? #f])
(show-smith-chart sweep [#:markers? #t] [#:theme 'light] [#:legend? #f])
(show-radiation-cut pattern
                    [#:component 'total]
                    [#:floor-db -40]
                    [#:normalize? #t]
                    [#:legend? #f])
(show-radiation-pattern-3d grid
                           [#:component 'total]
                           [#:floor-db -40]
                           [#:normalize? #t]
                           [#:mesh-step 5]
                           [#:aspect-ratio 1]
                           [#:legend? #f])
(show-radiation-pattern-opengl grid
                               [#:component 'total]
                               [#:floor-db -40]
                               [#:normalize? #t]
                               [#:scale 'arrl]
                               [#:palette 'mmana]
                               [#:color-step #f]
                               [#:mesh-step 2]
                               [#:axes? #t]
                               [#:antenna? #t]
                               [#:width 1000]
                               [#:height 760])
(show-radiation-comparison
 (list (radiation-case title grid) ...)
 [#:component 'total]
 [#:floor-db -40]
 [#:scale 'arrl]
 [#:palette 'mmana]
 [#:color-step #f]
 [#:mesh-step 2]
 [#:aspect-ratio 16/9]
 [#:width 1400])

(visualization-handle? value)
(visualization-update! handle replacement)
(visualization-show! handle)
(visualization-close! handle)
(visualization-open? handle)
```

Components are `'total`, `'vertical`, or `'horizontal`. The corresponding
headless renderer constructors—`vswr-sweep-renderers`,
`return-loss-sweep-renderers`, `gain-sweep-renderers`,
`impedance-sweep-renderers`,
`smith-chart-renderers`,
`radiation-cut-renderers`, and
`radiation-grid-renderers`—return ordinary Racket Plot renderers for custom
figures or bitmap generation.

Their complete signatures are:

```racket
(vswr-sweep-renderers result #:max-vswr [number-or-#f #f])
(return-loss-sweep-renderers result #:floor-db [negative-number-or-#f #f])
(gain-sweep-renderers gain-sweep)
(impedance-sweep-renderers result)
(smith-chart-renderers result #:markers? [boolean #t]
                       #:theme [(or 'light 'dark) 'light])
(s-parameter-magnitude-renderers multiport-result)
(s-parameter-phase-renderers multiport-result)
(radiation-cut-renderers pattern #:component [component 'total]
                         #:floor-db [dB -40]
                         #:normalize? [boolean #t])
(radiation-grid-renderers grid #:component [component 'total]
                          #:floor-db [dB -40]
                          #:normalize? [boolean #t]
                          #:mesh-step [degrees 5])
```

For example, headless CI can render the same return-loss data without opening
the interactive viewer:

```racket
(require plot/no-gui)
(plot-file (return-loss-sweep-renderers sweep #:floor-db -40)
           "return-loss.png"
           #:x-label "frequency (MHz)" #:y-label "S11 (dB)")
```

The 2-D `show-*` windows preserve Racket Plot's left-drag zoom and left-click
unzoom controls. Right-click or right-drag selects the nearest actual analysis
sample in display coordinates, places a cursor on it, and writes its series
name and precise values in the status pane below the plot. Sweep status text
reports frequency plus VSWR, S11, resistance, or reactance as appropriate.
Radiation-cut status text reports angle and raw component gain in dBi.

The gain sweep overlays maximum gain, mismatch-adjusted realized maximum gain,
realized maximum horizon gain, and S11 on their common dB scale. Its data tip
also reports maximum-lobe direction, unmatched horizon gain, impedance, and
VSWR. This distinguishes a well-matched mode from one whose strongest lobe has
moved away from the horizon.

`show-smith-chart` uses the sweep's reference impedance and plots
`(Z - Z0) / (Z + Z0)` on a fixed, equal-scale unit circle. Its dense normalized
impedance grid distinguishes major and minor divisions with different line
weights and includes dashed 1.5:1 and 2.0:1 VSWR circles. Each feed is a
separate solid-colored line. With `#:markers? #t`, a right-pointing triangle
marks the first frequency, a filled circle marks the last, and an open circle
marks the minimum-VSWR sample. Values outside the passive unit circle are
clipped. `#:theme` accepts `'light` (the default) or `'dark`. Smith-chart data
tips report frequency, complex impedance, S11, and VSWR without drawing the
Cartesian viewer's vertical cursor rule. Its legend is anchored outside the
chart at the upper-left, so a sufficiently wide window keeps it entirely in
the chart's unused side margin. Smith-chart data tips use a compact two-line
layout so Plot's square overlay boundary is unlikely to clip them.

The two OpenGL operations return an opaque `visualization-handle`. Save it to
replace a live view without closing its window:

```racket
(define view
  (show-radiation-pattern-opengl initial-grid #:palette 'inferno))

;; Camera orientation, zoom, window size, and presentation options survive.
(visualization-update! view revised-grid)
```

For a comparison handle, the replacement is another list of
`radiation-case` values. It must contain exactly the same number of cases as
the original call. Titles, grids, tile peak labels, drag proxies, shared
radius, and the shared legend are all replaced in place; changing the tile
count requires closing and opening a new comparison. A single-pattern update
also snapshots the current Antenna Turtle geometry for its antenna inset.
Surface construction occurs in the calling thread and the finished scene swap
is queued to the GUI, so NEC2C analysis remains explicit and under programmer
control. `visualization-close!` hides the window, which may be reopened with
`visualization-show!`; `visualization-open?` reports its current visibility.
The Plot and Plot3D operations do not yet return these handles.

The Plot3D viewer uses equal symmetric X/Y/Z bounds and a proportional
orthographic projection. During rotation it dynamically adjusts the plot-area
shape so that one horizontal screen unit remains the same size as one vertical
screen unit. This preserves the physical proportions of the radiation surface
instead of stretching every rotated bounding box to fill the window.
`#:aspect-ratio` is an additional width-to-height multiplier; leave it at `1`
for an undistorted view. For example, `4/3` intentionally makes the view 33%
wider than its physically proportional projection.

`show-radiation-pattern-3d` and the headless `radiation-grid-renderers`
constructor deliberately use one steel-blue surface. Its geometry is
precomputed once, making it the portable and responsive Plot3D baseline.

`show-radiation-pattern-opengl` uses Pict3D's OpenGL renderer. It uploads and
freezes a triangle mesh with smoothly interpolated per-vertex colors, then
moves only the camera during interaction. Drag to orbit and use the mouse
wheel to zoom. The camera orbits the center of the radiation surface's 3-D
bounds rather than the RF origin, allowing asymmetric patterns to use the
viewport efficiently. `#:palette` selects the surface and legend color ramp:
`'mmana` (the default) follows the conventional antenna-plot progression from
deep blue through cyan, green, yellow, red, and magenta, with extra color
resolution in the first 10 dB below peak. `'magma` provides a dark
navy/purple/magenta/orange SDR-style ramp; `'sdr` is its alias. `'inferno`,
`'viridis`, and `'grayscale` are also available. Every palette covers 0
through -30 dB, independently of the radial geometry selected by `#:scale`.
The legend's right side shows those relative values. Its left side adds each
relative value to the selected component's measured peak and labels the result
in dBi, allowing colors to be read either relative to the main lobe or as
absolute gain.

By default, colors vary smoothly between mesh vertices. Set `#:color-step` to
a positive number of decibels, such as `3`, to use hard gain bands instead.
Each display triangle receives the palette color for the band containing its
average relative gain, and the legend uses the same quantization. Band edges
therefore follow the display mesh; request smaller NEC2C theta/phi steps when a
finer contour is desired. This changes presentation only, not radial geometry
or the returned samples.

Its default `#:scale 'arrl` applies the traditional ARRL modified-log radial
mapping. For attenuation `A` dB below the peak, normalized radius is
`0.89^(A/2)`: -3 dB is therefore about 0.84 radius and -23.1 dB about 0.26.
The mapping continues toward the conventional -100 dB chart center and does
not use `#:floor-db`. Select `#:scale 'db` for the earlier behavior, which maps
decibels linearly from `#:floor-db` at the center to 0 dB at the outer radius.
Surface colors continue to encode actual relative gain under either geometry
scale.
When a grounded result ends at theta 90 degrees, both 3-D viewers close the
horizon ring with a triangulated bottom cap. The cap is display geometry only;
it does not invent below-ground radiation samples.
By default, a separate lower-left orientation inset displays red X, blue Y,
and green Z arrows. Because it is drawn in screen space rather than inserted
into the radiation scene, the surface cannot occlude it and depth clipping
cannot make an axis flicker. An axis aimed almost directly at the camera is
shown as a labeled bullseye. Pass `#:axes? #f` to hide the inset.

A neighboring antenna inset projects the current Antenna Turtle wire model
using the same camera orientation. It is independently scaled around the
geometry's bounding sphere, so the complete antenna remains visible while the
view rotates; feed locations are marked in red. Pass `#:antenna? #f` to hide
this inset. The inset snapshots the current model when the viewer is opened.

`show-radiation-comparison` displays one through nine named radiation grids in
a fixed tiled window. Construct each entry with `(radiation-case title grid)`,
where `title` is a string. Dragging any tile or using its mouse wheel changes
the orbit or zoom of every tile; clicking without dragging has no other
effect. The viewer deliberately uses one orientation inset and no antenna
insets. While the mouse button is held, each surface is replaced by a coarse
wireframe sampled from the same result and projected with Racket's ordinary
2-D canvas drawing. Far-side lines remain visible, and no OpenGL work is
queued during the drag. Releasing the button restores all full-resolution
colored surfaces at the final orientation. This keeps a large comparison
responsive without changing the analyzed data or resting view.

The comparison is absolute, not merely stylistic: all surfaces share the
largest selected-component peak as their 0 dB color and radial reference, and
all cameras share the same world-space radius. A lower-gain antenna therefore
appears both smaller and lower on the common color scale. Each tile title
reports its own peak in dBi, while one compact horizontal legend reports the
shared reference. Its tick density adapts to the available width.
`#:aspect-ratio` is the requested width/height of the window; `#:width`
selects the width and the height is derived from both values. The viewer picks
a row/column arrangement once when it opens, favoring nearly square tiles and
few empty cells. Resizing does not rearrange the cases.

For example:

```racket
(show-radiation-comparison
 (list (radiation-case "Dipole" dipole-grid)
       (radiation-case "Yagi" yagi-grid)
       (radiation-case "Franklin" franklin-grid))
 #:aspect-ratio 16/9
 #:palette 'inferno)
```

`#:mesh-step` controls only the displayed surface mesh, in degrees. Plot3D
defaults to 5 degrees; OpenGL defaults to 2 degrees and uses every available
sample when the analysis grid is coarser. Neither viewer alters or discards
samples in the returned `nec2c-pattern-grid` data object.

VSWR plots are uncapped by default, allowing Plot to choose an axis that
contains every finite sample. Pass a positive `#:max-vswr` greater than one
when a manual ceiling is useful. Samples with mathematically infinite VSWR
create a break in an uncapped curve; specifying a ceiling displays them at the
ceiling instead.

Return-loss plots use the analyzer-style negative
`20 log10(|reflection coefficient|)` display, so a good match appears as a
downward dip, and include a -10 dB reference line. The returned data object
still retains conventional positive return loss. An exact match creates a
break in an uncapped curve; pass a negative `#:floor-db` to draw it at a
chosen finite floor instead.

### Run metadata, errors, and parsing

Every top-level result contains `nec2c-run-info`, including executable,
version, elapsed milliseconds, exit status, captured standard output/error,
and `nec2c-artifacts`. Retained artifact paths are useful for reproducing or
diagnosing a run.

Runner failures use `exn:fail:nec2c`; its `run-info` field is available when a
process was started. `parse-nec2c-output` accepts an input port, report string,
or path value and returns a `parsed-nec2c-report`. The parser structures retain
raw NEC coordinates and tags and are primarily useful for fixtures and
external tooling.

## 16. Public Data Structures and Low-Level Parsing

All public structures below are transparent. Each declaration exports its
constructor, `STRUCT?` predicate, and one `STRUCT-FIELD` accessor per field in
the order shown. For example, `(openems-run-info-artifacts run)` reads the
`artifacts` field from an `openems-run-info`. This convention documents the
large accessor surface without requiring callers to memorize a separate name
list.

### Core and solid-scene structures

```racket
(point3 x y z)
(vertex id point)
(feed-spec location name amplitude phase)
(ground-spec kind relative-permittivity conductivity)
(wire-edge id start end diameter feed-info)
(antenna-model vertices edges)

(material-loss kind value reference-frequency)
(broadband-loss-range lower-frequency upper-frequency
                      reference-frequency model-factor)
(relaxation-pole delta-epsilon relaxation-time)
(em-material name kind relative-permittivity relative-permeability
             electric-conductivity magnetic-conductivity thickness loss-spec)

(solid-body name material solid priority coordinates placement-transform
            metal-thickness form material-source)
(planar-sheet name material points normal priority placement-transform
              mesh-edges thickness polygons boundaries trace-width)
(lumped-port name impedance center direction transverse-u transverse-v
             gap width depth priority placement-transform)
(lumped-component name resistance inductance capacitance topology caps
                  center direction transverse-u transverse-v
                  gap width depth priority placement-transform)
(solid-scene bodies sheets ports components)
(mesh-constraint kind point plane normal)
(simulation-profile name frequency-steps cells-per-wavelength
                    minimum-dielectric-cells minimum-trace-cells
                    metal-edge-resolution mesh-grading padding-wavelengths
                    maximum-timesteps end-criteria wire-segments)
```

`antenna-model` and `solid-scene` additionally export field mutators because
they are mutable. `openems-artifacts` below also exports mutators, and
`nec2c-pattern-sample` exports `set-nec2c-pattern-sample-direction!`. These are
intended for backends and tooling; ordinary models should use the DSL and
lifecycle calls.

```racket
(define substrate
  (first (model-bodies)))
(printf "~a uses epsilon-r ~a\n"
        (solid-body-name substrate)
        (em-material-relative-permittivity
         (solid-body-material substrate)))
```

### NEC2C result structures

```racket
(nec2c-artifacts model-path input-path output-path temporary? available?)
(nec2c-run-info executable version elapsed-ms exit-code stdout stderr artifacts)
(nec2c-feedpoint-sample feed-name frequency-mhz wire-id segment
                        voltage current impedance admittance input-power)
(nec2c-impedance-result run samples)
(nec2c-sweep-sample feedpoint reflection-coefficient return-loss-db vswr)
(nec2c-sweep-frequency frequency-mhz feed-samples)
(nec2c-sweep-result run reference-impedance frequencies)
(nec2c-pattern-sample frequency-mhz theta-deg phi-deg elevation-deg azimuth-deg
                      vertical-gain-db horizontal-gain-db total-gain-db
                      axial-ratio tilt-deg polarization-sense e-theta e-phi
                      [direction #f])
(nec2c-pattern run kind fixed-angle samples)
(nec2c-pattern-grid run theta-values phi-values samples)
(nec2c-gain-sweep-sample frequency-mhz feedpoint reflection-coefficient
                         return-loss-db vswr pattern maximum-gain-db
                         realized-maximum-gain-db maximum-gain-direction
                         horizon-gain-db realized-horizon-gain-db)
(nec2c-gain-sweep-result run reference-impedance samples)
```

The raw parser uses:

```racket
(parsed-nec2c-feed frequency-mhz tag segment voltage current
                   impedance admittance input-power)
(parsed-nec2c-pattern frequency-mhz theta-deg phi-deg
                     vertical-gain-db horizontal-gain-db total-gain-db
                     axial-ratio tilt-deg polarization-sense e-theta e-phi)
(parsed-nec2c-report feeds patterns)
(parse-nec2c-output input-port-or-string-or-path)
```

```racket
(define parsed (parse-nec2c-output "fixture.out"))
(map parsed-nec2c-feed-impedance (parsed-nec2c-report-feeds parsed))
```

`exn:fail:nec2c` adds the field `run-info` to ordinary `exn:fail` fields.
`nec2c-sweep->network-sweep` and `nec2c-gain-sweep->network-sweep` each accept
their corresponding result and return the solver-neutral sweep used by plots
and measurement accessors.

### OpenEMS result structures

```racket
(openems-artifacts directory driver-path simulation-directory manifest-path
                   temporary? available?)
(openems-run-info octave-executable elapsed-ms exit-code stdout stderr
                  artifacts manifest)
(openems-port-sample frequency-mhz reflection-coefficient impedance s11-db)
(openems-sweep-result run port-name reference-impedance samples)
(openems-result-port name reference-impedance)
(openems-s-parameter-sample frequency-mhz output-port input-port value db)
(openems-multiport-result run ports s-parameters input-samples)
(openems-power-budget run frequency-mhz excitation-port
                      incident-power-w reflected-power-w accepted-power-w
                      delivered-power-w radiated-power-w dielectric-power-w
                      lumped-power-w conductor-and-unaccounted-power-w)
```

`exn:fail:openems` adds a `run-info` field. `openems-sweep->network-sweep`
accepts either OpenEMS result type. The CSV parsers are deliberately low-level:

```racket
(parse-openems-port-results csv-path)
(parse-openems-s-parameter-results csv-path port-name-list)
(parse-openems-nf2ff-results csv-path frequency-mhz directivity-linear
                             radiated-power-w inverse-transform run-metadata)
```

The first two are useful for external tooling; the NF2FF parser normally
receives its transform and metadata from `openems-radiation-grid`.

```racket
(define samples (parse-openems-port-results "simulation/port-results.csv"))
(openems-port-sample-impedance (first samples))
```

`radiation-case` has fields `title` and `grid` and is used only by the
comparison viewer. A `visualization-handle` is intentionally opaque; use
`visualization-handle?`, `visualization-update!`, `visualization-show!`,
`visualization-close!`, and `visualization-open?` rather than inspecting it.

## 17. Command-Line and Build API

### Command line

```text
raco antenna-turtle build [options] model.rkt
```

Options:

```text
--nec2c
--mmana
--matlab, --matlab-loft
--matlab-ribbon
--all
--view
-o directory, --output-dir directory
```

With no format switches, the formats are `nec2c`, `mmana`, and `matlab`.

### `(build-model source-path ...+)`

Import separately:

```racket
(require antenna-turtle/build)
```

Signature:

```racket
(build-model source-path
             #:output-directory [directory #f]
             #:formats [formats default-build-formats]
             #:view? [view? #f])
```

- Evaluates the model module, which constructs and validates the shared model.
- Default output directory: the source file's directory.
- Default formats: `'(nec2c mmana matlab)`.
- Supported symbols: `nec2c`, `mmana`, `matlab`, `matlab-ribbon`.
- Returns generated paths in requested-format order.
- Creates the output directory when necessary.
- Opens the completed model in the Plot3D viewer when `view?` is true.

Exported constants:

```racket
default-build-formats
supported-build-formats
```

When both MATLAB formats are requested, loft receives `<stem>.m` and ribbon
receives `<stem>-ribbon.m`.

## 18. Common Lisp LOOP

The imported package supports clauses such as `repeat`, `for`, `in`, `from`,
`while`, `until`, `collect`, `sum`, `initially`, and `finally`. Examples:

```racket
(loop repeat 4
      do (forward 1)
         (turn left 90))

(loop for (role position length) in element-layout
      do (element role position length))
```

Racket's native iteration forms remain available and are preferable when their
semantics are clearer for a particular model.

## 19. Geometry Semantics

- Every wire-on nonzero movement creates one DSL edge.
- Geometry survives `pop` and `from-here`.
- Vertices merge only when all coordinates compare equal with numeric `=`.
- Crossing wire interiors do not connect automatically.
- `move-nearest` is the explicit tool for robust loop closure.
- Centerline wires and ordinary OpenEMS wire capsules are PEC. Physical sheets
  and rectilinear body boundaries may instead use finite-conductivity
  materials such as copper or aluminum.
- Ground and height assumptions are deferred to target simulators.
