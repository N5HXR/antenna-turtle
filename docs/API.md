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
one-millionth wavelength, and wire diameter of one millimetre.

### `(model [setting value] ...)`

Sets any desired subset using contextual `title`, `frequency`, `max-length`,
`snaplen`, and `wire-diameter` pairs. Each setting may appear at most once:

```racket
(model title "Three-element Yagi"
       frequency 14.1
       max-length {wavelength / 40}
       snaplen {wavelength / 1000000}
       wire-diameter {2 * millimeter})
```

Pair order is not significant. Frequency is applied before derived lengths, so
`max-length` and `snaplen` expressions may safely call `model-wavelength` in
any order.

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

### `(move direction distance ... [feed location | steps count])`

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

The optional contextual `feed` pair marks the resulting edge at `'start`,
`'center`, or `'end`:

```racket
(move forward length feed 'start)
```

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

### `(point direction distance ... [feed location])`

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

### `(spread direction distance [feed location])`

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

### `(feed location)`

Marks the next nonzero edge with mandatory location `'start`, `'center`, or
`'end`. Multiple model feeds are permitted unless an exporter imposes a
narrower limit. `move`, `point`, and `spread` can attach the same location
inline.

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

- NEC2C: `1.0` volt, `0` degree source on the first, middle, or last solver
  segment;
- MMANA: `b`, `c`, or `e` source designation;
- MATLAB: center feeds only; start or end feeds produce an export error.

## 11. Model Lifecycle and Inspection

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
(wire-edge id start end diameter feed-location)
(antenna-model vertices edges)
```

`wire-edge-feed-location` returns `#f`, `'start`, `'center`, or `'end`.
`wire-edge-feed?` remains available as a Boolean convenience predicate. All
structure predicates and accessors are exported. `antenna-model` also
exports mutators because it is declared mutable; tooling should prefer normal
turtle operations unless deliberate model transformation is required.

### `(edge-length edge)`

Returns Euclidean edge length.

### `(edge-segment-count edge maximum-length)`

Returns the solver subdivision count, including odd-count adjustment for a
center-fed edge. `maximum-length` is optional; its default is the explicit
model value or one-twentieth wavelength.

## 12. Geometry Viewer

### `(show-model [model] [#:vertices? vertices?] [#:wire-color color] [#:width width] [#:height height])`

Opens the current model in a separate interactive Plot3D window. The optional
`model` defaults to `(current-antenna-model)`. Drag the plot to rotate it.

Conductors default to medium blue (`"steelblue"`) and feed locations are marked
in red. `#:wire-color` accepts a Plot3D color such as `"navy"` or `"orange"`.
With `#:vertices? #t`, every Antenna Turtle vertex is also marked. `width` and
`height` are positive integer window dimensions and default to `900` and `700`.

The viewer gives every coordinate axis the same metric range, avoiding the
independent axis stretching common in general-purpose plots. It renders DSL
edges before solver subdivision and uses a fixed visible line width rather
than physical conductor diameter. An empty model or an unused pending feed is
an error.

The command-line equivalent is:

```sh
raco antenna-turtle build model.rkt --view
```

## 13. Export Functions

Each exporter validates pending-feed state and returns its output path. NEC2C
and MATLAB exports replace the requested file. MMANA has the update behavior
described below.

### `(export-nec2c path)`

Writes `CM`, `CE`, `GW`, `GE 0`, feed `EX`, and `EN` cards. Coordinates are
metres. Ground, frequency, execution, and pattern cards are intentionally
omitted.

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

## 14. Command-Line and Build API

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

## 15. Common Lisp LOOP

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

## 16. Geometry Semantics

- Every wire-on nonzero movement creates one DSL edge.
- Geometry survives `pop` and `from-here`.
- Vertices merge only when all coordinates compare equal with numeric `=`.
- Crossing wire interiors do not connect automatically.
- `move-nearest` is the explicit tool for robust loop closure.
- All conductors are treated as PEC in revision 1.
- Ground and height assumptions are deferred to target simulators.
