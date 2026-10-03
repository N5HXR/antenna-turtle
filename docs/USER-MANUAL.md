# Antenna Turtle User Manual

## 1. What Antenna Turtle Does

Antenna Turtle is a Racket language for describing wire antennas by moving a
stateful three-dimensional turtle. Pen-down movement creates PEC wire geometry;
pen-up movement only repositions the turtle. Models can be built into:

- NEC/`nec2c` input (`.nec`);
- MMANA-GAL Basic input (`.maa`);
- MATLAB Antenna Toolbox programs (`.m`).

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

The first installation may download the pinned Common Lisp `LOOP` package, so
an Internet connection is useful. Verify the language and build command:

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

(define wavelength (* 20 meter))
(define total-length (/ wavelength 2))

(model-title "Center-fed half-wave dipole")
(model-frequency 14.2)                 ; MHz
(maximum-segment-length (/ wavelength 100))
(wire-diameter (* 2 millimeter))

;; One wire centered at the origin and directed along local +X.
(feed)
(with-pen
  (spread forward total-length))
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
```

`--matlab` and `--matlab-loft` are synonyms. When both MATLAB representations
are requested, the preferred loft output is `<model>.m` and the ribbon output
is `<model>-ribbon.m`.

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

- forward is `+X`;
- left is `+Y`;
- up is `+Z`.

Every move and turn is relative to the current local frame. Rotations occur in
place and do not translate the turtle.

Several local axes can be combined into one movement:

```racket
(move forward 10 up 1)
```

With the pen down, that expression draws one diagonal wire—not two wires with
a corner between them. This is useful for polygonal approximations of curves.
For example, one turn of a rising helix can be written as:

```racket
(define segments-per-turn 12)
(define angle (/ 360 segments-per-turn))
(define rise-per-segment (/ helix-pitch segments-per-turn))

(loop repeat segments-per-turn
      do (move forward chord-length up rise-per-segment)
         (turn left angle))
```

Any number of direction/distance pairs may be combined. All are interpreted in
the same local frame, and together they produce one segment.

### 5.2 Pen State

Pen-down movement creates a wire segment. Pen-up movement only repositions the
turtle. Prefer the scoped form for drawing:

```racket
(with-pen
  (move forward 1)
  (turn left 90)
  (move forward 1))
```

`with-pen` requires the pen to be up on entry. It restores pen-up even if the
body raises an error, helping reveal accidentally overlapping drawing scopes.

### 5.3 Centered Elements

`spread` creates a segment centered at the current point:

```racket
(with-pen
  (spread left (* 1/2 wavelength)))
```

For `spread left`, the turtle silently repositions to the right endpoint and
then traverses the full length toward the left. `spread right` creates the same
geometry with reversed segment orientation. A feed immediately before
`spread` lies at the segment center.

### 5.4 Temporary Coordinate Contexts

`with-push` restores the complete turtle state after its body but retains all
geometry produced inside it:

```racket
(define (element boom-position length driven?)
  (with-push
    (move forward boom-position)
    (when driven? (feed))
    (with-pen
      (spread left length))))
```

This is useful for arrays because each element can be positioned relative to a
stable boom origin.

### 5.5 Scaling and Frequency Retuning

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
  (with-push
    (move forward position)
    (when (eq? role 'driven) (feed))
    (with-pen (spread left length))))

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
  (with-push
    (with-pen
      (loop repeat (sub1 sides)
            do (forward side)
               (turn left (/ 360 sides)))
      (move-nearest))))
```

`move-nearest` copies the selected existing vertex coordinate exactly. It
excludes the current point and the source of the immediately preceding move.

## 8. Feeds and Segmentation

`feed` marks the next nonzero pen-down segment. Turns and non-movement settings
may occur between `feed` and that segment, but a pen-up move is an error.

NEC2C and MMANA subdivide every DSL edge according to
`maximum-segment-length`. A fed edge always receives an odd subdivision count
so the source occupies the unique center solver segment. MATLAB places its feed
on the midpoint boundary generated for the marked DSL edge.

Multiple feeds are supported by the core language and wire exporters. The loft
MATLAB exporter currently supports at most one.

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

This supports optimization harnesses that generate a candidate, export it,
invoke a simulator, score the result, and repeat. The command-line build also
has a programmatic layer:

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

### `with-pen: pen is already down`

Remove an outer `pen-down` or nested `with-pen`. Scoped drawing deliberately
rejects an already-down pen.

### Unused or misplaced feed error

Ensure `(feed)` is followed by a nonzero movement while the pen is down. With a
centered element, use `(feed)` immediately before `(with-pen (spread ...))`.

### Loft MATLAB export rejects geometry

Loft mode currently rejects branch vertices, unequal diameters at a junction,
180-degree reversals, more than one feed, and bends too short for their wire
width. Use NEC2C/MMANA, simplify the junction, or use the ribbon MATLAB output.

## 12. Next Reference

See [API.md](API.md) for signatures, defaults, detailed semantics, model data
structures, and programmatic exporter interfaces.

## 13. Emacs `scheme-mode` Support

The project includes `editors/antenna-turtle-emacs.el`. It teaches
`scheme-mode` how to indent the scoped macros and adds theme-aware font-lock
faces for:

- Antenna Turtle procedures and exporters;
- DSL macros such as `move`, `turn`, `spread`, and the `with-*` forms;
- contextual direction words and unit constants;
- `loop` and its Common Lisp clause words.

Load it from `init.el`, using the actual project location. On Windows:

```elisp
(load "C:/Users/YourName/source/antenna-turtle/editors/antenna-turtle-emacs.el")
```

After adding the line, restart Emacs. For an already-open source buffer, use
`M-x normal-mode` to reinstall font lock, followed by `M-x font-lock-ensure` if
the buffer is not immediately recolored.

The extension activates font-lock additions only when the buffer starts with
`#lang antenna-turtle`; ordinary Scheme buffers retain their normal coloring.
