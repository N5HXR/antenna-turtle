#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
readonly DEFAULT_PREFIX="$PROJECT_ROOT/.local/macos"
readonly MANIFOLD_REPOSITORY="https://github.com/elalish/manifold.git"
readonly MANIFOLD_REF="${ANTENNA_TURTLE_MANIFOLD_REF:-7b35cb6f3ebc3900e0858e08c1caa27fe716345a}"
readonly RACKET_MANIFOLD_REPOSITORY="https://github.com/N5HXR/racket-manifold.git"
readonly NEC2C_REPOSITORY="https://github.com/KJ7LNW/nec2c.git"
readonly NEC2C_REF="${ANTENNA_TURTLE_NEC2C_REF:-master}"
readonly OPENEMS_REPOSITORY="https://github.com/thliebig/openEMS-Project.git"
readonly OPENEMS_REF="${ANTENNA_TURTLE_OPENEMS_REF:-master}"

PREFIX="$DEFAULT_PREFIX"
ASSUME_YES=0
SKIP_OPENEMS=0

usage() {
  cat <<EOF
Usage: scripts/install-macos.sh [options]

Install Antenna Turtle and its native macOS dependencies from a full checkout.
Homebrew supplies the major build/runtime dependencies. Manifold, NEC2C, and
openEMS are built without a system-wide install under:

  $DEFAULT_PREFIX

Options:
  --prefix PATH     Use a different checkout-local installation prefix.
  --skip-openems    Install Racket, Manifold, and NEC2C, but skip openEMS.
  --yes             Accept installation and dotfile prompts.
  -h, --help        Show this help.

Source revisions may be overridden for testing with:
  ANTENNA_TURTLE_MANIFOLD_REF, ANTENNA_TURTLE_NEC2C_REF,
  ANTENNA_TURTLE_OPENEMS_REF
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix)
      [ "$#" -ge 2 ] || { echo "--prefix requires a path" >&2; exit 2; }
      PREFIX="$2"
      shift 2
      ;;
    --skip-openems) SKIP_OPENEMS=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$(uname -s)" != "Darwin" ]; then
  echo "This installer supports macOS only (uname reported $(uname -s))." >&2
  exit 1
fi
if [ "$(id -u)" -eq 0 ]; then
  echo "Do not run this installer as root or with sudo." >&2
  exit 1
fi

confirm() {
  local prompt="$1"
  if [ "$ASSUME_YES" -eq 1 ]; then
    printf '%s [yes]\n' "$prompt"
    return 0
  fi
  [ -t 0 ] || return 1
  printf '%s [y/N] ' "$prompt"
  local answer
  IFS= read -r answer
  case "$answer" in [Yy]|[Yy][Ee][Ss]) return 0 ;; *) return 1 ;; esac
}

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { echo "install-macos: $*" >&2; exit 1; }

if ! xcode-select -p >/dev/null 2>&1; then
  echo "The Xcode Command Line Tools are required." >&2
  xcode-select --install >/dev/null 2>&1 || true
  die "finish the Command Line Tools installation, then rerun this script"
fi

if ! command -v brew >/dev/null 2>&1; then
  if ! confirm "Homebrew is not installed. Run Homebrew's official installer?"; then
    die "install Homebrew from https://brew.sh and rerun this script"
  fi
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
fi
command -v brew >/dev/null 2>&1 || die "Homebrew installation completed but brew is not on PATH"
readonly BREW_PREFIX="$(brew --prefix)"

PREFIX="$(mkdir -p "$PREFIX" && cd "$PREFIX" && pwd -P)"
readonly SOURCE_ROOT="$PREFIX/src"
readonly BUILD_ROOT="$PREFIX/build"
readonly MANIFOLD_PREFIX="$PREFIX/manifold"
readonly NEC2C_PREFIX="$PREFIX/nec2c"
readonly OPENEMS_PREFIX="$PREFIX/openems"
readonly ENV_FILE="$PREFIX/activate.sh"
readonly EMACS_ENV_FILE="$PREFIX/antenna-turtle-env.el"
readonly RACKET_FALLBACK_ROOT="${ANTENNA_TURTLE_RACKET_HOME:-$HOME/Library/Application Support/Antenna Turtle/racket}"
mkdir -p "$SOURCE_ROOT" "$BUILD_ROOT"

install_verified_racket() {
  local version="9.3" architecture filename expected
  case "$(uname -m)" in
    arm64)
      architecture="aarch64"
      expected="21f4937ca0bf37c31e60c1d77f5fd20f175e3ad51f6197f27149055bc222e559"
      ;;
    x86_64)
      architecture="x86_64"
      expected="07a35b94f8118be6728db0bce355576373deddb265e75f0295524e297e14f839"
      ;;
    *) die "Racket has no supported macOS download for architecture $(uname -m)" ;;
  esac

  filename="racket-${version}-${architecture}-macosx-cs.dmg"
  local url="https://download.racket-lang.org/releases/${version}/installers/${filename}"
  local download_dir="$PREFIX/downloads"
  local dmg="$download_dir/$filename"
  local brew_cache=""
  mkdir -p "$download_dir"

  # Homebrew may already have the newly reissued, valid image cached even when
  # its cask still records the old checksum. Reuse it only after independently
  # checking Racket's currently published checksum.
  brew_cache="$(brew --cache --cask racket 2>/dev/null || true)"
  if [ -n "$brew_cache" ] && [ -f "$brew_cache" ] && \
     [ "$(shasum -a 256 "$brew_cache" | awk '{print $1}')" = "$expected" ]; then
    dmg="$brew_cache"
    echo "Using Homebrew's cached Racket image after verification against Racket's published checksum."
  else
    echo "Downloading Racket $version directly from Racket's official release archive."
    curl --fail --location --retry 3 --output "$dmg" "$url"
  fi

  local actual
  actual="$(shasum -a 256 "$dmg" | awk '{print $1}')"
  [ "$actual" = "$expected" ] || \
    die "Racket download checksum mismatch (expected $expected, received $actual)"

  local racket_parent="$RACKET_FALLBACK_ROOT"
  local racket_suite="$racket_parent/Racket v$version"
  if [ ! -x "$racket_suite/bin/racket" ]; then
    local mount_point
    mount_point="$(mktemp -d "${TMPDIR:-/tmp}/antenna-turtle-racket.XXXXXX")"
    hdiutil attach -nobrowse -readonly -mountpoint "$mount_point" "$dmg" >/dev/null
    if [ ! -d "$mount_point/Racket v$version" ]; then
      hdiutil detach "$mount_point" >/dev/null || true
      rmdir "$mount_point" 2>/dev/null || true
      die "verified Racket image does not contain the expected Racket v$version suite"
    fi
    mkdir -p "$racket_parent"
    if ! ditto "$mount_point/Racket v$version" "$racket_suite"; then
      hdiutil detach "$mount_point" >/dev/null || true
      rmdir "$mount_point" 2>/dev/null || true
      die "could not copy the verified Racket suite into $racket_parent"
    fi
    hdiutil detach "$mount_point" >/dev/null
    rmdir "$mount_point" 2>/dev/null || true
  fi
  RACKET_BIN_DIR="$racket_suite/bin"
}

step "Installing major dependencies with Homebrew"
brew install git cmake ninja pkgconf coreutils autoconf automake libtool \
  python node tbb clipper2 octave boost hdf5 cgal vtk

# Racket occasionally reissues a same-version image before Homebrew updates its
# cask checksum. Never bypass Homebrew's check: independently verify the image
# against Racket's current architecture-specific checksum and install that
# suite under the user's Application Support directory. Also respect an
# existing Racket on PATH.
RACKET_BIN_DIR=""
LEGACY_RACKET_SUITE="$PREFIX/racket/Racket v9.3"
CURRENT_RACKET_SUITE="$RACKET_FALLBACK_ROOT/Racket v9.3"
if [ ! -x "$CURRENT_RACKET_SUITE/bin/racket" ] && \
   [ -x "$LEGACY_RACKET_SUITE/bin/racket" ]; then
  mkdir -p "$RACKET_FALLBACK_ROOT"
  mv "$LEGACY_RACKET_SUITE" "$CURRENT_RACKET_SUITE"
  rmdir "$PREFIX/racket" 2>/dev/null || true
  echo "Moved the checkout-local Racket fallback outside the package tree:"
  echo "  $CURRENT_RACKET_SUITE"
fi
LOCAL_RACKET_BIN="$CURRENT_RACKET_SUITE/bin"
if [ -x "$LOCAL_RACKET_BIN/racket" ] && [ -x "$LOCAL_RACKET_BIN/raco" ]; then
  RACKET_BIN_DIR="$LOCAL_RACKET_BIN"
  echo "Using Antenna Turtle's user-local Racket: $RACKET_BIN_DIR/racket"
elif ! command -v racket >/dev/null 2>&1 || ! command -v raco >/dev/null 2>&1; then
  if ! brew install --cask racket; then
    echo "Homebrew's Racket cask is stale or unavailable; using the verified local fallback." >&2
    install_verified_racket
  fi
else
  echo "Using existing Racket: $(command -v racket)"
fi

if [ -z "$RACKET_BIN_DIR" ]; then
  RACKET_BIN_DIR="$(dirname "$(command -v racket)")"
fi

# openEMS' current macOS build helper uses GNU readlink -f. Homebrew installs
# GNU coreutils with a g-prefix and provides the ordinary names in gnubin.
export PATH="$RACKET_BIN_DIR:$(brew --prefix coreutils)/libexec/gnubin:$BREW_PREFIX/bin:$PATH"
hash -r
for command_name in git cmake ninja python3 racket raco octave; do
  command -v "$command_name" >/dev/null 2>&1 || die "$command_name is unavailable after Homebrew installation"
done

checkout() {
  local repository="$1" destination="$2" ref="$3" recursive="${4:-0}" allow_generated="${5:-0}"
  if [ ! -d "$destination/.git" ]; then
    if [ "$recursive" -eq 1 ]; then
      git clone --recursive "$repository" "$destination"
    else
      git clone "$repository" "$destination"
    fi
  fi
  if [ "$allow_generated" -eq 0 ] && \
     { ! git -C "$destination" diff --quiet || \
       ! git -C "$destination" diff --cached --quiet; }; then
    die "$destination contains local changes; preserve them and rerun"
  fi
  git -C "$destination" fetch --tags origin
  git -C "$destination" checkout --detach "$ref"
  if [ "$recursive" -eq 1 ]; then
    git -C "$destination" submodule update --init --recursive
  fi
}

step "Building checkout-local Manifold C bindings"
readonly MANIFOLD_SOURCE="$SOURCE_ROOT/manifold"
checkout "$MANIFOLD_REPOSITORY" "$MANIFOLD_SOURCE" "$MANIFOLD_REF" 1
readonly MANIFOLD_BUILD="$BUILD_ROOT/manifold"
cmake -S "$MANIFOLD_SOURCE" -B "$MANIFOLD_BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$MANIFOLD_PREFIX" \
  -DCMAKE_PREFIX_PATH="$BREW_PREFIX" \
  -DBUILD_SHARED_LIBS=ON \
  -DMANIFOLD_CBIND=ON \
  -DMANIFOLD_CROSS_SECTION=ON \
  -DMANIFOLD_PAR=ON \
  -DMANIFOLD_PYBIND=OFF \
  -DMANIFOLD_TEST=OFF
cmake --build "$MANIFOLD_BUILD" --parallel "$(sysctl -n hw.logicalcpu)"
cmake --install "$MANIFOLD_BUILD"

MANIFOLD_LIBRARY=""
for candidate in \
  "$MANIFOLD_PREFIX/lib/libmanifoldc.dylib" \
  "$MANIFOLD_PREFIX/lib64/libmanifoldc.dylib"; do
  if [ -f "$candidate" ]; then MANIFOLD_LIBRARY="$candidate"; break; fi
done
[ -n "$MANIFOLD_LIBRARY" ] || die "the Manifold build did not produce libmanifoldc.dylib"

step "Building checkout-local NEC2C"
readonly NEC2C_SOURCE="$SOURCE_ROOT/nec2c"
# Older NEC2C autogen.sh runs configure in the source tree unless
# NOCONFIGURE is set. Clean that state left by an interrupted/older installer
# before resuming the dependency checkout.
if [ -f "$NEC2C_SOURCE/Makefile" ]; then
  make -C "$NEC2C_SOURCE" distclean
fi
checkout "$NEC2C_REPOSITORY" "$NEC2C_SOURCE" "$NEC2C_REF" 0 1
readonly NEC2C_BUILD="$BUILD_ROOT/nec2c"
mkdir -p "$NEC2C_BUILD"
(
  cd "$NEC2C_SOURCE"
  NOCONFIGURE=1 ./autogen.sh
)
(
  cd "$NEC2C_BUILD"
  "$NEC2C_SOURCE/configure" --prefix="$NEC2C_PREFIX"
  make -j"$(sysctl -n hw.logicalcpu)"
  make install
)
[ -x "$NEC2C_PREFIX/bin/nec2c" ] || die "the NEC2C build did not install an executable"

if [ "$SKIP_OPENEMS" -eq 0 ]; then
  step "Building checkout-local openEMS (headless solver and Octave interface)"
  readonly OPENEMS_SOURCE="$SOURCE_ROOT/openEMS-Project"
  checkout "$OPENEMS_REPOSITORY" "$OPENEMS_SOURCE" "$OPENEMS_REF" 1
  (
    cd "$OPENEMS_SOURCE"
    ./scripts/install_deps.sh --check --disable-gui --with-ctb || {
      echo "openEMS reports a missing Homebrew dependency." >&2
      echo "Run the suggested brew command above, then rerun this installer." >&2
      exit 1
    }
    ./update_openEMS.sh --verbose --disable-GUI \
      --njobs="$(sysctl -n hw.logicalcpu)" "$OPENEMS_PREFIX"
  )
fi

step "Writing the checkout-local runtime environment"
{
  echo "# Generated by Antenna Turtle scripts/install-macos.sh"
  printf 'export ANTENNA_TURTLE_ROOT=%q\n' "$PROJECT_ROOT"
  printf 'export RACKET_MANIFOLDC_LIB=%q\n' "$MANIFOLD_LIBRARY"
  printf 'export NEC2C=%q\n' "$NEC2C_PREFIX/bin/nec2c"
  printf 'export OCTAVE=%q\n' "$(command -v octave)"
  if [ "$SKIP_OPENEMS" -eq 0 ]; then
    printf 'export OPENEMS_ROOT=%q\n' "$OPENEMS_PREFIX"
    printf 'export PATH=%q:%q:%q:%q:$PATH\n' \
      "$RACKET_BIN_DIR" "$NEC2C_PREFIX/bin" "$OPENEMS_PREFIX/bin" "$(brew --prefix coreutils)/libexec/gnubin"
  else
    printf 'export PATH=%q:%q:%q:$PATH\n' \
      "$RACKET_BIN_DIR" "$NEC2C_PREFIX/bin" "$(brew --prefix coreutils)/libexec/gnubin"
  fi
} > "$ENV_FILE"
chmod 0644 "$ENV_FILE"

# Finder- and Dock-launched Emacs instances do not inherit ~/.zprofile. Build
# one complete bootstrap that supplies the native environment, configures
# Racket Mode, and loads Antenna Turtle's editing support.
{
  echo ";;; Generated by Antenna Turtle scripts/install-macos.sh"
  echo ";;; Require only this file from ~/.emacs; rerunning the installer refreshes it."
  printf "(dolist (directory (reverse '(\"%s\" \"%s\"" \
    "$RACKET_BIN_DIR" "$NEC2C_PREFIX/bin"
  if [ "$SKIP_OPENEMS" -eq 0 ]; then
    printf ' "%s"' "$OPENEMS_PREFIX/bin"
  fi
  printf ' "%s" "%s")))\n' \
    "$(brew --prefix coreutils)/libexec/gnubin" "$BREW_PREFIX/bin"
  echo "  (add-to-list 'exec-path directory))"
  echo '(setenv "PATH" (mapconcat #'\''identity exec-path path-separator))'
  printf '(setenv "ANTENNA_TURTLE_ROOT" "%s")\n' "$PROJECT_ROOT"
  printf '(setenv "RACKET_MANIFOLDC_LIB" "%s")\n' "$MANIFOLD_LIBRARY"
  printf '(setenv "NEC2C" "%s")\n' "$NEC2C_PREFIX/bin/nec2c"
  printf '(setenv "OCTAVE" "%s")\n' "$(command -v octave)"
  if [ "$SKIP_OPENEMS" -eq 0 ]; then
    printf '(setenv "OPENEMS_ROOT" "%s")\n' "$OPENEMS_PREFIX"
  fi
  printf '(setq racket-program "%s")\n' "$RACKET_BIN_DIR/racket"
  echo "(unless (require 'racket-mode nil t)"
  echo "  (display-warning 'antenna-turtle"
  echo '                   "Install the Emacs racket-mode package, then restart Emacs."'
  echo '                   :warning))'
  printf '(load "%s")\n' "$PROJECT_ROOT/editors/antenna-turtle-emacs.el"
  echo "(provide 'antenna-turtle-macos)"
} > "$EMACS_ENV_FILE"
chmod 0644 "$EMACS_ENV_FILE"

# Activate the same environment for the remainder of this installation.
# shellcheck disable=SC1090
source "$ENV_FILE"

step "Installing the Racket packages"
raco pkg install --auto --skip-installed k-infix
if ! raco planet show 2>/dev/null | grep -q 'jphelps.*loop.plt.*1.*25'; then
  raco planet install jphelps loop.plt 1 25
fi
raco pkg install --auto --skip-installed --name racket-manifold \
  "$RACKET_MANIFOLD_REPOSITORY"
raco pkg install --auto --link --skip-installed "$PROJECT_ROOT"
INSTALLED_MAIN="$(racket -e '(display (path->string (collection-file-path "main.rkt" "antenna-turtle")))')"
case "$INSTALLED_MAIN" in
  "$PROJECT_ROOT"/*) ;;
  *) die "the installed antenna-turtle package is not linked to $PROJECT_ROOT (found $INSTALLED_MAIN)" ;;
esac
# Set up only the public Antenna Turtle collection. Using `--pkgs` here makes
# Racket recursively treat every top-level checkout directory (including
# MMANA data, scratch programs, and JavaScript node_modules) as a collection.
# The package installers above have already set up racket-manifold and its
# dependencies.
raco setup antenna-turtle

step "Verifying Manifold, NEC2C, and Antenna Turtle"
racket -e '(require manifold) (displayln (format "Manifold ~a" (manifold-version)))'
"$NEC2C" -v
racket -e '(require antenna-turtle) (displayln "Antenna Turtle loaded with solid support")'
SMOKE_OUTPUT="$(mktemp -d "${TMPDIR:-/tmp}/antenna-turtle-install.XXXXXX")"
raco antenna-turtle build "$PROJECT_ROOT/examples/dipole.rkt" \
  --nec2c --output-dir "$SMOKE_OUTPUT"
grep -Eq '^EX[[:space:]]' "$SMOKE_OUTPUT/dipole.nec" \
  || die "the generated NEC2C smoke-test deck has no excitation card"
rm -f "$SMOKE_OUTPUT/dipole.nec"
rmdir "$SMOKE_OUTPUT"

if [ "$SKIP_OPENEMS" -eq 0 ]; then
  octave --quiet --no-gui --eval \
    "root=getenv('OPENEMS_ROOT'); addpath(fullfile(root,'share','openEMS','matlab')); addpath(fullfile(root,'share','CSXCAD','matlab')); assert(exist('RunOpenEMS','file') == 2); assert(exist('InitCSX','file') == 2); disp('openEMS Octave interface found');"
fi

step "Optional shell activation"
readonly SHELL_PROFILE="$HOME/.zprofile"
readonly SOURCE_LINE="source \"$ENV_FILE\""
if grep -Fqx "$SOURCE_LINE" "$SHELL_PROFILE" 2>/dev/null; then
  echo "$SHELL_PROFILE already activates Antenna Turtle."
elif confirm "Add the Antenna Turtle environment to $SHELL_PROFILE?"; then
  PROFILE_BACKED_UP=0
  if [ -f "$SHELL_PROFILE" ]; then
    cp -p "$SHELL_PROFILE" "$SHELL_PROFILE.antenna-turtle.bak"
    PROFILE_BACKED_UP=1
  fi
  {
    echo ""
    echo "# Antenna Turtle native dependencies"
    echo "$SOURCE_LINE"
  } >> "$SHELL_PROFILE"
  if [ "$PROFILE_BACKED_UP" -eq 1 ]; then
    echo "Updated $SHELL_PROFILE (backup: $SHELL_PROFILE.antenna-turtle.bak)."
  else
    echo "Created $SHELL_PROFILE."
  fi
else
  echo "To activate a shell manually, run:"
  printf '  source %q\n' "$ENV_FILE"
fi

step "Optional Emacs integration"
readonly EMACS_FILE="$HOME/.emacs"
EMACS_ENV_ESCAPED="${EMACS_ENV_FILE//\\/\\\\}"
EMACS_ENV_ESCAPED="${EMACS_ENV_ESCAPED//\"/\\\"}"
readonly EMACS_ENV_LOAD="(load \"$EMACS_ENV_ESCAPED\")"
readonly EMACS_ENV_REQUIRE="(require 'antenna-turtle-macos \"$EMACS_ENV_ESCAPED\")"
if [ -f "$EMACS_FILE" ]; then
  if grep -Fqx "$EMACS_ENV_REQUIRE" "$EMACS_FILE" || \
     grep -Fqx "$EMACS_ENV_LOAD" "$EMACS_FILE"; then
    echo "$EMACS_FILE already loads the complete Antenna Turtle integration."
  else
    echo "GUI Emacs does not inherit the PATH configured by ~/.zprofile."
    echo "The installer can load the complete Antenna Turtle integration from:"
    echo "  $EMACS_ENV_FILE"
    if confirm "Configure Racket Mode and all Antenna Turtle tools in Emacs?"; then
      cp -p "$EMACS_FILE" "$EMACS_FILE.antenna-turtle.bak"
      printf '\n;; Antenna Turtle: native tools, Racket Mode, and editing support\n%s\n' \
        "$EMACS_ENV_REQUIRE" >> "$EMACS_FILE"
      echo "Updated $EMACS_FILE (backup: $EMACS_FILE.antenna-turtle.bak)."
    else
      echo "Left the Emacs configuration unchanged."
    fi
  fi
else
  echo "No ~/.emacs file exists; no Emacs configuration was created."
  echo "After installing racket-mode, add this one line to your Emacs configuration:"
  echo "  $EMACS_ENV_REQUIRE"
fi

cat <<EOF

Antenna Turtle's native macOS installation is ready.

Local dependency prefix: $PREFIX
Activation file:         $ENV_FILE
Emacs environment:       $EMACS_ENV_FILE
Project checkout:        $PROJECT_ROOT

Open a new Terminal window before normal use if .zprofile was updated.
EOF
