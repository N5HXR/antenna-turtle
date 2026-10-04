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

`(model-wavelength)` is shorthand for converting the current
`model-frequency`:

```racket
(model-frequency 446)
(define wavelength (model-wavelength))
```

`(span length unit)` expresses a physical length as a unitless count of the
chosen positive unit. The length may be signed, which also makes `span` useful
for offsets:

```racket
(span (model-wavelength) millimeter) ; objective millimetres
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

The settings are Racket parameters: call with no arguments to read and one
argument to set.

### `(model-title [title])`

- Default: `"Antenna Turtle model"`.
- Supplies the human-readable title written by exporters.

### `(model-frequency [megahertz])`

- Default: `1.0`.
- Units: MHz.
- Written into MMANA output and used to initialize MATLAB analysis and its
  wavelength-based mesh bound.
- `mmana-frequency` is a compatibility alias to the same parameter.

### `(maximum-segment-length [length])`

- Default: `#f`.
- Units: metres.
- Must be a positive real before NEC2C or MMANA export.
- The count for an edge is `ceiling(edge-length / maximum-segment-length)`.
- A fed edge's count is increased when necessary to make it odd.

### `(wire-diameter length)`

- Initial value: `1 millimeter`.
- Requires a positive finite real.
- Sets the base diameter for subsequently created edges.
- Effective diameter also includes the current `scale-all` diameter factor.

## 4. Pen Operations

### `(pen-up)`

Subsequent movement changes turtle state without generating an edge.

### `(pen-down)`

Subsequent nonzero movement generates a wire edge.

### `(with-pen body ...+)`

Requires the pen to be up, sets it down for `body`, and restores pen-up on
normal or exceptional exit. Returns the body's values. Entering with an
already-down pen is an error.

```racket
(with-pen
  (forward 1)
  (turn left 90)
  (forward 1))
```

## 5. Movement

All directions below are in the current local frame. Distance expressions are
evaluated exactly once and multiplied by the current movement scale.

### `(forward distance)`

Moves along local `+X`.

### `(back distance)`

Moves along local `-X`.

### `(move direction distance [direction distance] ...)`

`direction` is a contextual keyword and does not require quoting:

```racket
(move forward distance) ; +X
(move back distance)    ; -X
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

This creates one diagonal edge from the old position to the new position when
the pen is down. It does not create a forward edge followed by an upward edge.
Pairs may be supplied in any order, repeated directions are added, and opposing
directions subtract. Every distance expression is evaluated exactly once in
source order. The current movement scale applies uniformly to the completed
local displacement vector.

### `(spread direction distance)`

Creates or traverses one full movement centered at the original position.
The turtle silently relocates by half the distance opposite `direction`, then
performs one full ordinary movement in `direction`.

- Pen down: creates exactly one centered edge.
- Pen up: changes position but creates no edge.
- Pending feed: applies to the centered full edge.
- Final position: the endpoint in the named direction.

All six `move` direction words are accepted.

### `(move-nearest)`

Moves to the closest existing model vertex, copying its coordinates exactly.
The search excludes vertices equal to the current point and the source of the
immediately preceding movement. Ties retain vertex creation order. Pen state
controls whether the closing movement draws.

### Zero movement

Zero distance is legal and creates no edge. It is an error when a feed is
pending because no segment would receive the feed.

## 6. Rotation

Rotations occur in place around local axes and use degrees.

### `(turn direction degrees)`

```racket
(turn left degrees)   ; positive local Z
(turn right degrees)  ; negative local Z
(turn up degrees)     ; negative local Y
(turn down degrees)   ; positive local Y
```

The direction is a contextual keyword; the degree expression is evaluated
exactly once.

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
movement scale on every exit. It does not rewind position, orientation, pen
state, other settings, or generated geometry.

Neither scaling form changes the global `maximum-segment-length` setting.

## 8. Turtle State Stack

### `(push)` and `(pop)`

`push` saves position, orientation, pen state, movement and diameter scales,
base diameter, and previous-movement information. `pop` restores that state.
Generated geometry is global and is not removed. Popping an empty stack is an
error; exiting a model with unmatched pushes is legal.

### `(with-push body ...+)`

Exception-safe `push`/`pop`. Returns the body's values, restores the complete
turtle state, and retains geometry generated inside the body.

## 9. Feeds

### `(feed)`

Marks the next nonzero pen-down edge as fed. Multiple model feeds are permitted
unless a selected exporter imposes a narrower limit.

Before the marked edge, the program may rotate or change non-movement settings.
These are errors while a feed is pending:

- another `feed`;
- pen-up movement;
- zero movement;
- module termination without a consuming edge.

Target behavior:

- NEC2C: `1.0` volt, `0` degree source on the center solver segment;
- MMANA: source at the fed wire's center segment;
- MATLAB: feed boundary at the DSL edge midpoint.

## 10. Model Lifecycle and Inspection

### `(reset-model!)`

Clears geometry, turtle state, stack, pending feed, and settings.

### `(validate-model!)`

Currently verifies that no feed marker remains unused.

### `(current-position)`

Returns the current `point3`.

### `(current-wire-diameter)`

Returns base diameter multiplied by the active diameter scale.

### `(current-antenna-model)`

A parameter containing the mutable `antenna-model` value.

### `(model-vertices [model])` and `(model-edges [model])`

Return model vertices and edges; the current model is the default.

### Public structures

```racket
(point3 x y z)
(vertex id point)
(wire-edge id start end diameter feed?)
(antenna-model vertices edges)
```

All structure predicates and accessors are exported. `antenna-model` also
exports mutators because it is declared mutable; tooling should prefer normal
turtle operations unless deliberate model transformation is required.

### `(edge-length edge)`

Returns Euclidean edge length.

### `(edge-segment-count edge maximum-length)`

Returns the solver subdivision count, including odd-count adjustment for a fed
edge.

## 11. Export Functions

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
feed creation, geometry display, and directivity stub.

### `(export-matlab-loft path)`

Writes closed square-prism loft geometry with bevel joints, flat terminal caps,
a four-edge feed contour, topology checks, diameter-sensitive meshing, display,
and directivity analysis.

Current loft restrictions:

- degree-two paths and loops only; no branch vertex;
- equal diameters among edges incident on one vertex;
- zero or one feed;
- no 180-degree path reversal;
- enough adjacent length to construct every bevel setback.

## 12. Command-Line and Build API

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
             #:formats [formats default-build-formats])
```

- Evaluates the model module, which constructs and validates the shared model.
- Default output directory: the source file's directory.
- Default formats: `'(nec2c mmana matlab)`.
- Supported symbols: `nec2c`, `mmana`, `matlab`, `matlab-ribbon`.
- Returns generated paths in requested-format order.
- Creates the output directory when necessary.

Exported constants:

```racket
default-build-formats
supported-build-formats
```

When both MATLAB formats are requested, loft receives `<stem>.m` and ribbon
receives `<stem>-ribbon.m`.

## 13. Common Lisp LOOP

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

## 14. Geometry Semantics

- Every pen-down nonzero movement creates one DSL edge.
- Geometry survives `pop` and `with-push`.
- Vertices merge only when all coordinates compare equal with numeric `=`.
- Crossing wire interiors do not connect automatically.
- `move-nearest` is the explicit tool for robust loop closure.
- All conductors are treated as PEC in revision 1.
- Ground and height assumptions are deferred to target simulators.
