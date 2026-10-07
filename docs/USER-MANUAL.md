# Antenna Turtle User Manual

## 1. What Antenna Turtle Does

Antenna Turtle is a Racket language for describing wire antennas by moving a
stateful three-dimensional turtle. Wire-on movement creates PEC wire geometry;
wire-off movement only repositions the turtle. Models can be built into:

- NEC/`nec2c` input (`.nec`);
- MMANA-GAL Basic input (`.maa`);
- MATLAB Antenna Toolbox programs (`.m`).

Generated geometry can also be inspected immediately in an interactive 3-D
preview without loading an external simulator.

The language describes geometry, conductor diameter, segmentation guidance,
and feed locations. Ground, material choices other than PEC, source details
beyond the default unit-voltage feed, and most measurement setup remain in the
target simulator.

## 2. Installing on Windows 11

### 2.1 Install Racket

1. Download the Windows installer from the
   [official Racket download page](https://download.racket-lang.org/).
2. Install the full distribution. DrRacket is useful but not required.
3. Open a new PowerShell window and verify the command-line tools:

```powershell
racket --version
raco --help
```

If Windows cannot find either command, add the directory containing
`racket.exe` and `raco.exe` to `PATH`, then open a new PowerShell window. This
is commonly the Racket installation directory selected by the installer.

Racket packages are installed with `raco pkg`; local package directories can
be installed as links, so edits to the source tree take effect without copying
the package. See the official
[Racket package guide](https://docs.racket-lang.org/pkg/getting-started.html).

### 2.2 Copy Antenna Turtle

Copy the complete `antenna-turtle` project directory to the laptop using Git,
a ZIP archive, a network share, or removable storage. The directory is correct
when it contains both `info.rkt` and the inner `antenna-turtle` directory.

For example:

```text
C:\Users\YourName\source\antenna-turtle\
    info.rkt
    README.md
    antenna-turtle\
    docs\
    examples\
```

### 2.3 Install the Language

In PowerShell:

```powershell
cd C:\Users\YourName\source\antenna-turtle
raco pkg install --auto --link .
```

The first installation may download the `k-infix` package and the pinned
Common Lisp `LOOP` package, so an Internet connection is useful. Verify the
language and build command:

```powershell
racket .\examples\dipole.rkt
raco antenna-turtle --help
```

The first command validates the model and normally prints nothing. The second
should display the `build` command.

If the language works but the `raco` command is not registered, refresh the
linked package:

```powershell
raco setup --pkgs antenna-turtle
```

For an offline installation where the LOOP dependency is not already cached,
install it while connected and then rerun setup:

```powershell
raco pkg install --auto k-infix
raco planet install jphelps loop.plt 1 25
raco setup --pkgs antenna-turtle
```

### 2.4 Updating or Removing

After replacing or updating files in a linked source tree:

```powershell
raco setup --pkgs antenna-turtle
```

To remove the package registration:

```powershell
raco pkg remove antenna-turtle
```

This removes the link from Racket; it does not delete the project directory.

## 3. First Model

Create `dipole.rkt`:

```racket
#lang antenna-turtle

(model title "Center-fed half-wave dipole"
       frequency 14.2
       max-length {wavelength / 100}
       snaplen {wavelength / 1000000}
       wire-diameter {2 * millimeter})

(define total-length half-wave)

;; One wire centered at the origin and directed along local +X.
(with-wire
  (spread forward total-length feed center))
```

The entire `model` form is optional. With no declaration, the title is
`"Turtle Antenna"`, frequency is 14.1 MHz, wire diameter is 1 mm, maximum
segment length is one-twentieth wavelength, and vertex snap length is
one-millionth wavelength. The NEC2C environment defaults to free space with no
height offset. Therefore this is also complete:

```racket
#lang antenna-turtle
(with-wire (move forward 5))
```

Validate it:

```powershell
racket .\dipole.rkt
```

Build the standard outputs:

```powershell
raco antenna-turtle build .\dipole.rkt
```

This writes `dipole.nec`, `dipole.maa`, and loft-based `dipole.m` beside the
source. To keep generated files separate:

```powershell
raco antenna-turtle build .\dipole.rkt --output-dir .\build\dipole
```

### 3.1 Curly infix arithmetic

Antenna Turtle retains Racket's S-expression structure while allowing ordinary
mathematical notation inside curly braces:

```racket
(define circumference {diameter * pi})
(define segment-length {circumference / segments-per-turn})
(define angle {360 / segments-per-turn})

(with-scale {28.5 / 29.0}
  (with-wire
    (move forward segment-length up {pitch / segments-per-turn})
    (turn left angle)))
```

Multiplication and division bind more tightly than addition and subtraction.
Nested braces provide explicit grouping, lexical variables work normally, and
exact inputs remain exact:

```racket
{1 + 2 * 3}       ; 7
{{1 + 2} * 3}     ; 9
{360 / 7}         ; exact 360/7
```

Put spaces around operators. Racket reads `{a+b}` as a single identifier, so
write `{a + b}`. Use `~` when embedding a prefix Racket expression that should
not be interpreted as infix syntax:

```racket
{radius * ~(sin angle)}
```

Curly infix notation is provided by the `#lang antenna-turtle` reader. It is
not enabled in an ordinary `#lang racket` module merely by requiring the API.
Parenthesized prefix expressions remain available everywhere.

## 4. Build Command

With no format switches, `build` produces NEC2C, MMANA, and loft MATLAB files:

```powershell
raco antenna-turtle build model.rkt
```

Select formats explicitly when desired:

```powershell
raco antenna-turtle build model.rkt --nec2c
raco antenna-turtle build model.rkt --mmana
raco antenna-turtle build model.rkt --matlab
raco antenna-turtle build model.rkt --matlab-ribbon
raco antenna-turtle build model.rkt --all --output-dir build
raco antenna-turtle build model.rkt --view
```

`--matlab` and `--matlab-loft` are synonyms. When both MATLAB representations
are requested, the preferred loft output is `<model>.m` and the ribbon output
is `<model>-ribbon.m`. `--view` generates the selected outputs and opens the
completed model in the interactive geometry viewer.

Use quotes around Windows paths containing spaces:

```powershell
raco antenna-turtle build ".\My Antennas\yagi.rkt" `
  --output-dir ".\Simulation Output\yagi"
```

### 4.1 MMANA save-and-regenerate workflow

MMANA builds are designed for an iterative division of responsibility:

1. Build the model to create its `.maa` file.
2. Open it in MMANA-GAL, configure the simulation, and save the file.
3. Edit the turtle program and build it again.
4. Reload the file in MMANA-GAL and rerun the simulation.

When the target does not exist, Antenna Turtle writes the normal free-space
defaults. When an existing target is a recognizable MMANA model, Antenna
Turtle replaces its title, frequency, wires, sources, and loads, then preserves
everything from the global `*** Segmentation ***` section onward. Thus MMANA's
saved ground, height, material, reference-impedance, segmentation, and pattern
settings survive geometry regeneration.

`model-frequency` remains authoritative, because frequency is part of the
antenna program. Loads are currently cleared on every regeneration so stale
wire references cannot survive changed geometry. If an existing file is not
recognizable, the exporter reports an error without modifying it. Updates are
written atomically, and the existing LF or CRLF line-ending style is retained.

## 5. Turtle Model

### 5.1 Coordinates

The initial local frame is right-handed:

- forward/forwards is `+X`;
- back/backward/backwards is `-X`;
- left is `+Y`;
- up is `+Z`.

Every move and turn is relative to the current local frame. Rotations occur in
place and do not translate the turtle.

Several local axes can be combined into one movement:

```racket
(move forward 10 up 1)
```

With the wire on, that expression draws one diagonal wire—not two wires with
a corner between them.

Add `steps` to divide the combined displacement into explicit equal edges:

```racket
(move forward run up rise steps 12)
```

This is useful for grids and warped curves because each step supplies a vertex
for transformation. The count must be an exact positive integer. A segmented
move cannot carry or consume a feed marker; draw and mark the desired feed
segment separately.

For radial curves, `point` can instead emit endpoints relative to a stationary
turtle. The first point establishes a trace anchor; later points connect to it
without moving the turtle itself. One turn of a rising helix can therefore be
written directly in terms of radius:

```racket
(define segments-per-turn 12)
(define angle (/ 360 segments-per-turn))
(define rise-per-segment (/ helix-pitch segments-per-turn))

(point right helix-radius)
(loop repeat segments-per-turn
      do (turn left angle)
         (move up rise-per-segment)
         (point right helix-radius))
```

No circumference, chord-length, or pi calculation is needed. Any number of
direction/distance pairs may be combined in either `move` or `point`. All are
interpreted in the same local frame.

Turns may also be chained, but they are applied sequentially because 3D
rotations do not commute:

```racket
(turn left 90 up 15 roll-right 30)
```

`roll-left` and `roll-right` rotate around local forward. The direction is
named from the turtle's point of view looking forward; roll-left lowers its
local left side.

`here` records the current global `point3`, and `goto` returns directly to a
recorded global coordinate regardless of current local orientation or scale:

```racket
(define anchor (here))
(move forward 10 up 2)
(goto anchor)
```

Wire state still determines whether `goto` merely repositions or draws.

### 5.2 Wire State

Wire-on movement creates a wire segment. Wire-off movement only repositions the
turtle. Prefer the scoped form for drawing:

```racket
(with-wire
  (move forward 1)
  (turn left 90)
  (move forward 1))
```

`with-wire` requires the wire to be off on entry. It restores wire-off even if
the body raises an error, helping reveal accidentally overlapping drawing
scopes.

An explicit `point` sequence is the exception to the usual wire-off geometry
rule. It traces between stationary relative endpoints while ordinary turtle
movement remains non-drawing. `point` is an error while the wire is on. Calling
either `wire-on` or `wire-off` ends any open point trace, so `wire-off` is the
simple low-level way to separate independent paths. A single unconnected point
is discarded, including at normal program termination.

Prefer `with-points` when a path has a natural lexical extent:

```racket
(with-points
  (point right radius)
  (loop repeat segments do
    (turn roll-left angle)
    (point right radius)))
```

It requires wire-off and no active point trace, and discards its final anchor
on normal or exceptional exit. Geometry and other turtle changes survive.

The former `pen-up`, `pen-down`, and `with-pen` names remain compatibility
aliases, but new models should use wire terminology.

### 5.3 Centered Elements

`spread` creates a segment centered at the current point:

```racket
(with-wire
  (spread left (* 1/2 wavelength)))
```

The turtle remains at the center afterward. `spread left` and `spread right`
create the same geometry with reversed segment orientation, which matters for
`'start` and `'end` feeds. A center feed can be attached directly:

```racket
(with-wire (spread left length feed center))
```

### 5.4 Temporary Coordinate Contexts

`from-here` restores the complete turtle state after its body but retains all
geometry produced inside it:

```racket
(define (element boom-position length driven?)
  (from-here
    (move forward boom-position)
    (with-wire
      (if driven?
          (spread left length feed center)
          (spread left length)))))
```

This is useful for arrays because each element can be positioned relative to a
stable boom origin.

The former name `with-push` remains a compatibility alias.

### 5.5 Bilateral Symmetry

`reflect` executes a construction once and mirrors the wire geometry produced
inside it. Directions are local and select the normal of the reflection plane:

```racket
(reflect up
  (construct-upper-half))
```

Here the original geometry is reflected across the local XY plane through the
turtle's position at entry. `down` is equivalent. Likewise, left/right reflect
local Y and forward/back reflect local X. This remains local-relative after any
prior turtle rotation.

Only geometry is copied: the body and its ordinary Racket side effects execute
once. Wire diameter is retained, feeds are suppressed on the reflected copy,
and geometry in the reflection plane is shared rather than duplicated. The
turtle remains wherever the original body finished.

For rotational repetition around local up, use `radial-repeat`:

```racket
(radial-repeat 42
  (rib))
```

The current heading is used first, every copy starts from the same captured
turtle state, and that state is restored afterward. Feeds and ordinary side
effects in the body are repeated normally. Inside the body,
`radial-iterations` reports the nested repetition context as zero-based
`(index count)` pairs. A nested 2-by-3 repetition therefore reaches values such
as `'((1 2) (2 3))`.

### 5.6 Warped Surfaces

`with-surface` lets the turtle draw an ordinary flat parameter-space mesh and
projects each emitted vertex straight up onto a height field. For a centered
parabolic reflector:

```racket
(define focal-length (* 30 centimeters))

(define (dish-height x y)
  (/ (+ (* x x) (* y y)) (* 4 focal-length)))

(with-surface dish-height
  (flat-circular-dish-grid))
```

The standard paraboloid constructor removes the formula boilerplate:

```racket
(with-surface (paraboloid focal-length)
  (flat-circular-dish-grid))
```

Other standard mappings are available:

```racket
;; X is circumferential arc length; Y is the cylinder axis.
(with-warp (cylinder radius)
  (cylindrical-grid))

;; Both are vertex-anchored at the current turtle position.
(with-surface (dome radius)
  (flat-circular-grid))

(with-surface (bowl radius)
  (flat-circular-grid))

;; X spans the supports; Y is the extrusion axis.
(with-surface (catenary support-spacing center-sag)
  (segmented-hanging-wire))
```

A dome falls toward local negative Z away from its crown. A bowl rises toward
local positive Z away from its bottom. Hemisphere inputs must remain inside
the radius. A cylinder wraps local X as arc length around an axis parallel to
local Y; logical Z represents inward radial offset. A catenary places supports
at local X `+/- span/2` at height zero and lowers its center by `sag`; local Y
does not affect its height.

Coordinates are local to the turtle pose enclosing the form: `x` is forward,
`y` is left, and height is local up. Logical `z` from the body is added to the
surface height. The complete turtle state is restored afterward, as though the
form were wrapped in `from-here`.

For transformations that also alter `x` or `y`, use `with-warp`. Its procedure
receives three coordinates and returns a three-item list:

```racket
(with-warp
 (lambda (x y z)
   (list x (* y 0.8) (+ z (dish-height x y))))
 (flat-circular-dish-grid))
```

These forms move vertices rather than bending continuous wires. Add explicit
intermediate points wherever a curved surface needs a closer chord
approximation. Warps cannot be nested, and `move-nearest`, model reset, and
reflection initiated inside a warp are deliberately rejected. Wrapping a warp
in `reflect` is supported.

### 5.7 Scaling and Frequency Retuning

`scale` multiplies movement distances but not conductor diameter. The scoped
form makes frequency correction concise:

```racket
;; A model optimized at 28.5 MHz is being retuned to 29.0 MHz.
(with-scale (/ 28.5 29.0)
  (construct-antenna))
```

Resonant frequency varies approximately inversely with linear dimensions, so
`observed-frequency / target-frequency` is a useful first correction. Physical
wire diameter remains unchanged. Use `scale-all` only when diameter should
scale with geometry too.

The conversion helpers remove the unit arithmetic normally needed around this
workflow:

```racket
(model-frequency 446)

;; The wavelength identifiers are physical lengths in metres. Convert one to a
;; unitless count when authoring under (with-scale millimeter ...).
(define wavelength-mm (span wavelength millimeter))

;; Convert either direction for calculated designs.
(define two-metre-frequency (wavelength->frequency {2 * meter}))
(define seventy-centimetre-wave (frequency->wavelength 446))

(with-scale (frequency-retuning-scale 28.5 29.0)
  (construct-antenna))
```

`frequency->wavelength` and `wavelength->frequency` accept positive values in
MHz and metres respectively. They use the exact SI speed of light, so exact
inputs remain exact. `span` accepts a physical length and a positive unit and
returns the unitless number of those units; signed lengths are allowed for
offset calculations. The read-only identifiers `wavelength`, `half-wave`, and
`quarter-wave` resolve from the current model frequency whenever used. They
therefore follow `reset-model!` and a subsequent frequency change in iterative
generators. `(model-wavelength)` remains the equivalent procedural API.

### 5.8 Measuring Wire Usage

`wire-used` reports the total physical conductor length generated so far in
metres. Record a reading before a helper call and subtract it afterward to
measure that construction:

```racket
(define curl-start (wire-used))
(curl #f)
(displayln (- (wire-used) curl-start))
```

The same idiom measures a complete antenna:

```racket
(define antenna-start (wire-used))
(construct-antenna)
(define required-wire (- (wire-used) antenna-start))
```

This is an odometer over actual model edges. It accounts for movement scale,
diagonal point-to-point distances, snapped endpoints, and reflected geometry.
It ignores wire-off positioning, an unpaired point anchor, and the solver's
export-time segmentation because none of those adds physical conductor.

### 5.9 Previewing Geometry

Call `show-model` after constructing geometry to open a Plot3D window:

```racket
(with-wire
  (spread forward half-wave feed center))

(show-model)
```

Drag inside the window to rotate the view. Feedpoints are red and conductors
default to medium blue. A different Plot3D color can be selected directly:

```racket
(show-model #:wire-color "navy")
```

To expose the endpoints created by turtle operations:

```racket
(show-model #:vertices? #t)
```

The viewer uses an equal numeric range for X, Y, and Z and dynamically adjusts
the Plot3D viewport while it rotates, preserving the model's physical
proportions at every viewing angle. `#:aspect-ratio` defaults to `1`; another
positive value deliberately multiplies the projected width-to-height ratio.
The viewer shows Antenna Turtle's edges before NEC/MMANA solver subdivision.
Lines are intentionally screen-visible and do not depict the physical wire
diameter; use the simulator or MATLAB solid export when surface geometry
matters.

## 6. Repetition and Layout Tables

Normal Racket iteration is available, and Antenna Turtle also imports the
Common Lisp `LOOP` macro. A self-describing Yagi layout can keep each element's
role, boom position, and length together:

```racket
(define element-layout
  '((reflector    0 330)
    (driven     164 342)
    (director-1 216 311)
    (director-2 339 308)))

(define (element role position length)
  (from-here
    (move forward position)
    (with-wire
      (if (eq? role 'driven)
          (spread left length feed center)
          (spread left length)))))

;; The table contains millimetres; scale only the movements in this scope.
(with-scale millimeter
  (loop for (role position length) in element-layout
        do (element role position length)))
```

Racket's native `for`, `for/list`, and `for/fold` remain available as well.

## 7. Closing Loops Reliably

Trigonometric rotations can introduce inexact coordinates. To close a polygon,
draw all but the final side and use `move-nearest`:

```racket
(define (regular-loop sides perimeter)
  (define side (/ perimeter sides))
  (from-here
    (with-wire
      (loop repeat (sub1 sides)
            do (forward side)
               (turn left (/ 360 sides)))
      (move-nearest))))
```

`move-nearest` copies the selected existing vertex coordinate exactly. It
excludes the current point and the source of the immediately preceding move.

## 8. Feeds and Segmentation

`feed` requires one of `start`, `center`, or `end` and marks the next
nonzero wire-on segment. Turns and non-movement settings may occur between
`feed` and that segment, but a wire-off move is an error. Usually the inline
form is clearer:

```racket
(move forward radiator feed start)
(spread left driven-length feed center)
```

The older quoted forms remain valid. For simultaneous sources, add a unique
name, voltage magnitude, and phase in degrees:

```racket
(move forward radiator feed (center "horizontal" 1.0 0))
(move left radiator feed (center "vertical" 1.0 90))
```

NEC2C and MMANA subdivide every DSL edge according to
`maximum-segment-length`. When no explicit maximum is supplied, one-twentieth
of `model-wavelength` is used. A center-fed edge receives an odd subdivision
count so the source occupies the unique center solver segment. Start and end
feeds use the first and last NEC segment or MMANA's `b` and `e` locations.
MATLAB supports center feeds only and reports an error for start/end feeds.

Multiple feeds are supported by the core language and wire exporters. The loft
MATLAB exporter currently supports at most one.

### Vertex snapping

Newly drawn endpoints snap to an existing model vertex when they differ only
by the configured tolerance. The default is `model-wavelength / 1000000`,
which is intended to absorb floating-point rotation error without closing
ordinary intentional gaps. Override it in metres or disable proximity snapping:

```racket
(model snaplen {0.5 * millimeter})
(model snaplen 0) ; exact coordinate merging remains enabled
```

The nearest qualifying vertex wins, with creation order breaking ties. The
turtle adopts the copied exact coordinate, preventing drift from propagating.
Only endpoints are considered: crossing wires and endpoints near the interior
of another wire do not become junctions automatically.

## 9. MATLAB Workflow

The preferred MATLAB exporter builds closed square-prism loft geometry, creates
the feed, displays the antenna, meshes it, and runs a directivity pattern stub.
Its generated mesh limit is:

```text
min(wavelength / 10, 5 * minimum wire diameter)
```

This diameter-sensitive rule helps MATLAB retain long, thin conductors. The
generated frequency is initialized from `model-frequency`; edit or sweep it in
MATLAB when tuning a physical design.

The ribbon exporter is lighter and useful for comparison, but represents wires
as rectangular strips rather than closed solids.

## 10. Programmatic and Optimization Workflows

The individual exporters remain callable from Racket:

```racket
(require antenna-turtle)

(reset-model!)
;; Generate or mutate geometry here.
(validate-model!)
(export-nec2c "candidate.nec")
(export-mmana "candidate.maa")
(export-matlab-loft "candidate.m")
```

For interactive regeneration under the current model settings, use
`clear-wires` instead of `reset-model!`. It removes the generated geometry and
returns the turtle to its initial construction state while retaining settings
such as frequency, ground, height, impedance, segmentation, and wire diameter:

```racket
(define (build scale)
  (clear-wires)
  (with-scale scale
    (with-wire
      (spread left half-wave feed center))))
```

NEC2C can also be invoked directly. Measurements return data and never open a
window unless the program explicitly calls a `show-*` operation:

```racket
(nec2c-executable "/path/to/nec2c") ; omit when it is on PATH

(define feedpoint (nec2c-measure-impedance))
(define sweep (nec2c-vswr-sweep 440 450 #:steps 51))
(define horizontal-cut
  (nec2c-azimuth-pattern #:elevation 0 #:step 2))
(define vertical-cut
  (nec2c-elevation-pattern #:azimuth 0 #:step 2))
(define sphere
  (nec2c-radiation-grid #:theta-step 5 #:phi-step 5))

(show-vswr-sweep sweep)
(show-return-loss-sweep sweep)
(show-smith-chart sweep)
(show-radiation-cut horizontal-cut)
(show-radiation-pattern-3d sphere)
(show-radiation-pattern-opengl sphere #:palette 'magma)
```

To compare previously calculated designs in one synchronized view, name each
grid and pass up to nine of them to the comparison viewer:

```racket
(show-radiation-comparison
 (list (radiation-case "reference" reference-grid)
       (radiation-case "longer directors" longer-grid)
       (radiation-case "wider spacing" wider-grid))
 #:aspect-ratio 16/9
 #:palette 'inferno)
```

Both OpenGL viewers return a reusable visualization handle. This is useful at
a REPL when geometry and analysis are being regenerated repeatedly:

```racket
(define view
  (show-radiation-pattern-opengl reference-grid #:palette 'inferno))

;; Rebuild the model and calculate another NEC2C grid, then:
(visualization-update! view revised-grid)
```

The same window, camera orientation, zoom, dimensions, palette, and other
presentation choices remain in use. The surface, gain legend, centroid and
radius are replaced, and the single-view antenna inset snapshots the current
model geometry. A comparison handle accepts a revised list with the same
number of `radiation-case` values; changing the tile count still requires a
new window. Use `visualization-close!`, `visualization-show!`, and
`visualization-open?` to manage the retained window. The ordinary Plot and
Plot3D graph windows are not yet dynamically replaceable.

Every tile rotates and zooms together. The brightest and largest case sets the
single absolute gain reference, so weaker antennas are not independently
normalized to look equally strong. Tile headings retain their individual peak
gain in dBi. The window aspect ratio is explicit, and the initial tiling is
kept when the window is resized. The comparison view has one shared axis inset
and legend and omits antenna thumbnails to preserve tile area. During a drag,
the viewer temporarily substitutes inexpensive 2-D projected wireframes for
the colored OpenGL surfaces; the full meshes return at the requested
orientation on mouse release.

VSWR plots include every finite value by default and let Plot choose the
vertical extent. For a deliberately clipped overview, supply a ceiling such
as `(show-vswr-sweep sweep #:max-vswr 10)`.

All 2-D analysis graphs include a data cursor. Left-drag zooms and left-click
unzooms as usual. Right-click or hold the right button while dragging to select
the nearest actual NEC2C sample; release the button to leave its label pinned.
On sweep plots the label identifies the feed or impedance component, frequency,
and value. On polar cuts it reports angle and raw gain in dBi.

Return loss presents the same match data on the familiar analyzer-style
`20 log10(|reflection coefficient|)` scale: a better match makes a deeper
negative dip. Use `(show-return-loss-sweep sweep)` for the automatically scaled
plot. It includes a -10 dB reference line. The data object retains conventional
positive return loss, and a mathematically exact match remains infinite there;
the uncapped plot omits that point. Supply a floor such as `#:floor-db -40`
when you want it drawn at a finite limit.

For a normalized impedance view of the same sweep, use
`(show-smith-chart sweep)`. The chart uses the sweep's reference impedance,
draws fine minor grid divisions beneath stronger major divisions, and includes
dashed 1.5:1 and 2.0:1 VSWR circles. Separate feeds retain separate line
colors. By default a triangle marks the first frequency, a filled circle the
last frequency, and an open circle the minimum-VSWR sample; pass
`#:markers? #f` for an unmarked trace. The default `#:theme 'light` matches the
other Plot windows, while `#:theme 'dark` provides a black presentation.
Right-button inspection reports frequency, complex impedance, S11, and VSWR.
The legend stays outside the upper-left of the circular plot; widening the
window gives it a side margin without covering the Smith grid. Smith data tips
are split over two compact lines to stay inside the square plot boundary.

The Plot3D viewer locks all coordinate axes to the same scale and dynamically
adjusts its orthographic viewport during rotation. Resizing or rotating the
window therefore does not stretch the radiation pattern. `#:aspect-ratio` is
an optional additional width-to-height multiplier; `1` is the
distortion-free default.

`show-radiation-pattern-3d` is the conservative, single-color Plot3D view.
Its polygons are prepared once, and it renders at a 5-degree mesh step by
default even when NEC2C was asked for a finer analysis grid.

`show-radiation-pattern-opengl` is the accelerated presentation view. It uses
a frozen Pict3D mesh with smoothly interpolated gain colors, a perspective
camera, drag-to-orbit navigation, and wheel zoom. Its display mesh defaults to
2 degrees. The camera targets the center of the pattern's 3-D bounds, so an
asymmetric main lobe does not waste zoom room on the opposite side of the RF
origin.

Select the color ramp with `#:palette`. The choices are `'mmana` (the bright
antenna-plot default), `'magma` (also named `'sdr`) for a dark-purple through
orange SDR-waterfall style, `'inferno`, `'viridis`, and `'grayscale`. The
legend names the active palette and radial scale. Relative attenuation appears
to the right of its color strip; matching absolute gain in dBi appears to the
left, calculated from the selected component's peak.

Add `#:color-step 3` to either OpenGL viewer for hard 3 dB color bands instead
of a continuous gradient. A triangle is colored from its average gain, so the
contour precision follows the theta/phi resolution requested from NEC2C. The
legend switches to the same stepped ramp automatically.

The default ARRL radial scale emphasizes the main pattern without making weak
lobes disappear: a point `A` dB below peak is drawn at radius `0.89^(A/2)`.
Use `#:scale 'db` to recover the linear-in-decibels geometry controlled by
`#:floor-db`.

Grounded radiation grids contain an upper hemisphere only. The viewers add a
downward-facing cap across its horizon ring so the display remains a solid
model when viewed from below; the cap is not additional simulated radiation.

A separate lower-left inset displays red X, blue Y, and green Z
orientation arrows without subjecting them to surface occlusion or 3-D depth
clipping. An axis aimed into the camera becomes a labeled bullseye instead of
vanishing. The inset can be hidden with `#:axes? #f`. Beside it, a synchronized
wireframe inset shows the current antenna in the same orientation, always
scaled to contain its complete geometry and with feedpoints marked in red.
Hide that inset with `#:antenna? #f`. Both viewers preserve the full-resolution
result returned to the program; `#:mesh-step` changes only what is displayed.

The model's `impedance` setting controls the reference used for VSWR and
return loss and defaults to 50 ohms:

```racket
(model frequency 446 impedance 200)
```

Every feed retains complex voltage, current, active impedance, admittance, and
power in the returned structures. With multiple feeds, those are active
impedances under simultaneous excitation rather than S-parameters. The
pattern is the combined field.

NEC2C ground and antenna height belong in the same declarative model block:

```racket
(model title "20 m dipole"
       frequency 14.1
       ground real
       height half-wave)
```

`ground none` is free space and remains the default. `ground perfect` is an
infinite perfect conductor. `ground real` selects average earth with relative
permittivity 13 and conductivity 0.005 S/m. Use
`ground (real permittivity conductivity)` for measured or chosen soil values.
Conductivity is in siemens per metre.

Grounded decks use NEC's ground-contact geometry mode: a wire endpoint at the
translated Z=0 plane is grounded. Put an endpoint distinctly above zero when
it should remain insulated. Wires below the plane or lying along it are model
errors. Pattern requests become hemisphere-aware automatically: azimuth cuts
cannot be below the horizon, default elevation cuts traverse horizon–zenith–
opposite horizon, and 3-D grids stop at the ground plane.

This supports optimization harnesses that generate a candidate, measure it,
score the returned values, and repeat. The command-line build also has a
programmatic layer:

```racket
(require antenna-turtle/build)

(build-model "candidate.rkt"
             #:output-directory "build"
             #:formats '(nec2c mmana matlab))
```

## 11. Troubleshooting

### `raco: Unrecognized command: antenna-turtle`

From the project directory, run:

```powershell
raco setup --pkgs antenna-turtle
```

If that fails, verify installation with `raco pkg show antenna-turtle` and
repeat `raco pkg install --auto --link .`.

### `collection not found` for `antenna-turtle`

The package is not installed for the Racket installation used by the current
terminal. Check `where.exe racket` and `where.exe raco`; both should belong to
the same Racket installation.

### LOOP package download failure

Connect to the Internet and run:

```powershell
raco planet install jphelps loop.plt 1 25
raco setup --pkgs antenna-turtle
```

### `with-wire: wire is already on`

Remove an outer `wire-on` or nested `with-wire`. Scoped drawing deliberately
rejects an already-on wire.

### Unused or misplaced feed error

Ensure `(feed location)` is followed by a nonzero wire-on movement or a
completed point-trace edge. Prefer `(move ... feed location)`,
`(point ... feed location)`, or `(spread ... feed location)` when the feed
belongs directly to that edge.

### Loft MATLAB export rejects geometry

Loft mode currently rejects branch vertices, unequal diameters at a junction,
180-degree reversals, more than one feed, and bends too short for their wire
width. Use NEC2C/MMANA, simplify the junction, or use the ribbon MATLAB output.

## 12. Next Reference

See [API.md](API.md) for signatures, defaults, detailed semantics, model data
structures, and programmatic exporter interfaces.

## 13. Emacs Scheme Mode and Racket Mode Support

The project includes `editors/antenna-turtle-emacs.el`. It teaches
both Emacs Scheme Mode and the optional Racket Mode package how to indent the
scoped macros, and adds theme-aware font-lock faces for:

- Antenna Turtle procedures and exporters;
- DSL macros such as `move`, `point`, `turn`, `spread`, and the `with-*` forms;
- contextual direction words and unit constants;
- emphasized infix operators with muted `{` and `}` delimiters;
- `loop` and its Common Lisp clause words.

Load it from `init.el`, using the actual project location. On Windows:

```elisp
(load "C:/Users/YourName/source/antenna-turtle/editors/antenna-turtle-emacs.el")
```

After adding the line, restart Emacs. Loading or reloading the helper refreshes
already-open Antenna Turtle buffers. Its setup command is also available as
`M-x antenna-turtle-setup` (with `antenna-turtle-scheme-setup` retained as a
compatibility alias); re-entering the major mode is unnecessary.

The extension activates font-lock additions only when the buffer starts with
`#lang antenna-turtle`; ordinary Scheme and Racket buffers retain their normal
coloring. Racket Mode is not required merely to load the helper; when installed,
its normal `racket-mode-hook` activates the same Antenna Turtle support.
