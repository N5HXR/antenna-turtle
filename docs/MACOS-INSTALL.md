# Native macOS installation

The repository includes a native macOS bootstrapper for a complete checkout:

```sh
./scripts/install-macos.sh
```

Do not run it with `sudo`. The installer requires Apple's Xcode Command Line
Tools and uses Homebrew for the major build and runtime dependencies, including
Racket, Octave, CMake, Ninja, TBB, Clipper2, and the libraries needed by
openEMS. If Homebrew is absent, the script asks before invoking Homebrew's
official installer.

If a Racket download mirror returns a bad file, the installer does not disable
Homebrew's checksum verification. If Racket has reissued the same version
before Homebrew updates its checksum, the installer verifies the image against
the architecture-specific checksum published on Racket's official release page
and copies that suite into
`~/Library/Application Support/Antenna Turtle/racket`. Keeping the fallback
outside the checkout allows Racket to link the checkout as a development
package. It reuses Homebrew's cached image when that image passes the
independent check. A working Racket already present on `PATH` is accepted
instead of forcing a duplicate installation.

The fallback location can be overridden with `ANTENNA_TURTLE_RACKET_HOME`.
When resuming a run made by an earlier installer, the script automatically
moves `.local/macos/racket/Racket v9.3` to the new user-local location before
installing the package.

Manifold is deliberately **not** installed from Homebrew. The version targeted
by `racket-manifold` is compiled with its C bindings and installed under the
checkout-local `.local/macos/manifold` prefix. NEC2C and openEMS are likewise
built beneath `.local/macos`; no `sudo make install` or system-library symlink
is used. Because `racket-manifold` is not published in the Racket package
catalog, the installer obtains it explicitly from the
[N5HXR/racket-manifold](https://github.com/N5HXR/racket-manifold) repository.
The generated `.local/macos/activate.sh` exports:

- `RACKET_MANIFOLDC_LIB`, pointing directly to the local
  `libmanifoldc.dylib`;
- `NEC2C`, pointing to the local solver;
- `OPENEMS_ROOT`, pointing to the local openEMS installation;
- `OCTAVE` and the required executable search path.

The installer offers to source this file from `~/.zprofile`. If declined, it
prints the command needed to activate a terminal manually. The current
installation process always uses the environment directly, so its validation
does not depend on accepting the profile change.

When `~/.emacs` already exists, the installer separately asks permission to
load its generated `antenna-turtle-env.el` and to append a `(load "...")`
call for `editors/antenna-turtle-emacs.el`. The generated environment supplies
GUI Emacs with the Racket, NEC2C, openEMS, GNU coreutils, and Homebrew binary
directories plus `RACKET_MANIFOLDC_LIB`, `NEC2C`, `OCTAVE`, and
`OPENEMS_ROOT`. This is needed by Emacs instances launched from Finder or the
Dock, which do not normally inherit `~/.zprofile`. Rerunning the installer
refreshes the generated file. The installer creates a backup before editing
and never creates `.emacs` or changes it without confirmation.

## Options

```text
--prefix PATH     Select another local dependency prefix.
--skip-openems    Install Racket, Manifold, and NEC2C without building openEMS.
--yes             Accept dependency and dotfile prompts (useful for automation).
```

Source revisions can be overridden for installation testing with
`ANTENNA_TURTLE_MANIFOLD_REF`, `ANTENNA_TURTLE_NEC2C_REF`, and
`ANTENNA_TURTLE_OPENEMS_REF`. The default Manifold revision is pinned to the
revision targeted by `racket-manifold`; solver projects default to their
current maintained branches.

The openEMS build is headless because Antenna Turtle supplies its own geometry,
field, plot, and HTML viewers. This avoids making the unrelated AppCSXCAD GUI a
condition of solver installation while retaining the openEMS executable and
complete Octave interface used by Antenna Turtle.

## Re-running and cleanup

The script is safe to rerun when its local source checkouts are clean. It
updates/fetches the selected revisions and rebuilds incrementally. Build files
live outside the source checkouts under `.local/macos/build`. It refuses to
overwrite tracked local changes inside those dependency checkouts. NEC2C is
the exception because its legacy bootstrap regenerates tracked autotools files;
Git itself still refuses a revision switch if such changes would be lost.

NEC2C's legacy `autogen.sh` normally configures its source directory as a side
effect. The installer suppresses that behavior and performs an out-of-tree
build; when resuming an installation made by an older version of the script,
it first runs `make distclean` on that installer-created source configuration.

The generated dependency tree is excluded from Git. To remove it, first remove
the optional `source` line from `~/.zprofile`, then delete `.local/macos` from
the checkout. If the verified fallback was used, its Racket suite lives in
`~/Library/Application Support/Antenna Turtle/racket` and must be removed
separately. Removing either local tree does not uninstall Homebrew packages or
the linked Racket package.
