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
existing models; new code should use the wire terminology.

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

Multiplies the current movement scale by a positive factor. Wire diameter is
unchanged.

### `(scale-all factor)`

Multiplies both movement scale and diameter scale by a positive factor.

### `(with-scale factor body ...+)`

Temporarily multiplies movement scale for the body, then restores the prior
movement scale on every exit. It does not rewind position, orientation, wire
state, other settings, or generated geometry.

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

## 11. Model Lifecycle and Inspection

### `(clear-wires)`

Clears all vertices and edges and returns the turtle to the origin with its
initial orientation and wire drawing off. It also clears the turtle stack,
point-trace anchor, and any pending feed. Model settings—including frequency,
ground, height, segmentation, impedance, and wire diameter—are preserved.

Use this when regenerating geometry interactively under the current `(model
...)` declaration. It may not be called inside `with-warp`, `with-surface`, or
`radial-repeat`.

### `(reset-model!)`

Clears geometry, turtle state (including any point-trace anchor), stack,
pending feed, and settings.

### `(validate-model!)`

Currently verifies that no feed marker remains unused.

### `(current-position)`

Returns the current `point3`.

`here` is the preferred geometry-facing synonym.

### `(current-wire-diameter)`

Returns base diameter multiplied by the active diameter scale.

### `(current-antenna-model)`

A parameter containing the mutable `antenna-model` value.

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
center-fed edge. `maximum-length` is optional; its default is the explicit
model value or one-twentieth wavelength.

## 12. Geometry Viewer

### `(show-model [model] [#:vertices? vertices?] [#:wire-color color] [#:width width] [#:height height] [#:aspect-ratio ratio])`

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
running. An empty model or an unused pending feed is an error.

The command-line equivalent is:

```sh
raco antenna-turtle build model.rkt --view
```

### `(show-solid-model [#:width 900] [#:height 700] [#:aspect-ratio 1] [#:wire-segments 24])`

Opens registered Manifold volume bodies, planar sheets, and any ordinary
Turtle wire network in a proportion-preserving Plot3D window. Wires are shown
as the same temporary capsule union used by OpenEMS, including its derived
physical feed gap. `#:wire-segments` controls circular tessellation. PEC,
dielectric, and sheet geometry receive distinct materials. Derived and
explicit lumped ports appear as red boxes with a polarity arrow. This is a
geometry preflight viewer; the OpenEMS-generated `model.xml` remains the
authoritative view of the final Yee mesh and CSXCAD properties.
Like `show-model`, this window remains interactive during a blocking
`openems-sweep` call.

## 13. Physical Solid Scene and OpenEMS

Import Manifold with a prefix, then register solids and an explicit port:

```racket
(require (prefix-in m: manifold))

(body radiator
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

Bodies use the current turtle frame unless `coordinates world` is supplied.
The scene owns a transformed copy; the caller remains responsible for closing
the original Manifold handle. `anchor origin` is the default; `anchor center`
first places the center of the solid's axis-aligned bounding box on the turtle,
which is convenient for Yagi elements and arbitrary CSG assemblies. Manifold
primitives such as `m:cylinder` and `m:cube` also accept `#:center? #t` when
constructor-level centering is preferable. `clear-bodies` closes and clears
registered bodies, sheets, and their subordinate ports.

Lossless dielectric volumes use `(dielectric #:name name
#:relative-permittivity epsilon-r [#:relative-permeability 1])`. Planar
conductors use `(sheet name points ... material ... priority ...)`, where
`points` is a local-XY polygon. `pec` gives a zero-thickness perfect conductor;
`conducting-sheet-material` supplies finite conductivity and thickness. The
sheet follows the complete turtle frame, including arbitrary rotation.
`mesh-edges exact` is the compatibility default and puts mesh planes on its
geometric bounds. `mesh-edges metal` applies the openEMS 1/3--2/3 treatment to
an axis-aligned rectangular metal sheet: each in-plane edge is represented by
a line one-third of the local edge resolution inside and another two-thirds
outside. Other polygons and rotated sheets reject that treatment explicitly.

Port `priority` is optional. By default, the OpenEMS exporter chooses an
integer priority between touching dielectric and conductor geometry, following
the usual `dielectric < port < conductor` ordering. An explicit value overrides
that inference and is useful when a more complex overlap hierarchy requires
manual control. The effective value and whether it was automatic or explicit
are recorded in the simulation manifest.

### `(openems-sweep start-mhz stop-mhz keyword-arguments ...)`

The current executable slice supports ordinary Turtle wires, PEC and
nondispersive lossless dielectric volume bodies, planar PEC/conducting sheets,
and one or more derived or explicit lumped ports. One-port runs return an
`openems-sweep-result`; multiport runs return an `openems-multiport-result`
containing the complete complex S-matrix and active input impedance for every
excitation and requested frequency. Materials that
overlap or touch through a sheet interface require distinct explicit CSXCAD
priorities. The mesh wavelength is reduced by the largest dielectric
`sqrt(epsilon-r * mu-r)` in the scene.

```racket
(openems-sweep
 800 1050
 #:steps 101
 #:cells-per-wavelength 20
 #:minimum-dielectric-cells 4
 #:metal-edge-resolution #f ; defaults to half the wavelength cell limit
 #:mesh-grading 1.4
 #:padding-wavelengths 0.5
 #:max-timesteps 100000
 #:end-criteria 1e-5
 #:wire-segments 24
 #:octave #f
 #:keep-artifacts? #t
 #:progress? #t
 #:timeout #f)
```

Every wire edge becomes a physical Manifold capsule using its modeled
diameter. Connected and disconnected capsules are combined into one temporary
PEC body without changing the live centerline graph. A marked wire feed becomes
a physical gap and lumped port. Its default gap is
`max(wavelength/1000, wire-radius)`; a warning is printed when that gap exceeds
the marked edge's length. `#:wire-segments` controls capsule circular
tessellation and must be at least three.

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
value and resulting critical coordinates are retained in the manifest. The
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
residual-energy reports written to `octave.stdout`. Its **Cancel simulation**
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

### `(show-s-parameter-magnitude result)`

### `(show-s-parameter-phase result)`

Display every term of an `openems-multiport-result`. Labels include both the
conventional matrix index and named direction, such as
`S21 (output <- input)`. Phase is unwrapped independently for each term. Both
views retain left-drag zoom and right-drag sample inspection.

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

### Plotting

These operations explicitly open Racket Plot windows. The four network plots
accept either a `nec2c-sweep-result` or an `openems-sweep-result`:

```racket
(show-vswr-sweep sweep [#:max-vswr #f])
(show-return-loss-sweep sweep [#:floor-db #f])
(show-impedance-sweep sweep)
(show-smith-chart sweep [#:markers? #t] [#:theme 'light])
(show-radiation-cut pattern
                    [#:component 'total]
                    [#:floor-db -40]
                    [#:normalize? #t])
(show-radiation-pattern-3d grid
                           [#:component 'total]
                           [#:floor-db -40]
                           [#:normalize? #t]
                           [#:mesh-step 5]
                           [#:aspect-ratio 1])
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
`return-loss-sweep-renderers`, `impedance-sweep-renderers`,
`smith-chart-renderers`,
`radiation-cut-renderers`, and
`radiation-grid-renderers`—return ordinary Racket Plot renderers for custom
figures or bitmap generation.

The 2-D `show-*` windows preserve Racket Plot's left-drag zoom and left-click
unzoom controls. Right-click or right-drag selects the nearest actual analysis
sample in display coordinates and overlays its series name and precise values;
right release leaves that label pinned. Sweep labels report frequency plus
VSWR, S11, resistance, or reactance as appropriate. Radiation-cut labels
report angle and raw component gain in dBi.

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

## 15. Command-Line and Build API

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

## 16. Common Lisp LOOP

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

## 17. Geometry Semantics

- Every wire-on nonzero movement creates one DSL edge.
- Geometry survives `pop` and `from-here`.
- Vertices merge only when all coordinates compare equal with numeric `=`.
- Crossing wire interiors do not connect automatically.
- `move-nearest` is the explicit tool for robust loop closure.
- All conductors are treated as PEC in revision 1.
- Ground and height assumptions are deferred to target simulators.
