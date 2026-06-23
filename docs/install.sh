#!/bin/sh
# Ember installer - builds emberc + the standard library from source and installs
# them under ~/.ember, then puts emberc on your PATH.
#
#   curl -fsSL https://ember-lang.org/install.sh | sh
#
# Ember is pre-1.0 and has no prebuilt releases yet, so this builds from source.
# The default build is the FULL "flagship" compiler (networking + graphics), so the
# Claude desktop app and ordinary programs both run from the same emberc. If the
# graphics/networking dependencies can't be set up, it falls back to the plain,
# dependency-free compiler automatically (which still runs all non-GUI programs).
#
# Tunables (all optional, set as environment variables before running):
#   EMBER_PREFIX           install location              (default: $HOME/.ember)
#   EMBER_REF              git branch/tag/SHA to build   (default: main)
#   EMBER_PROFILE          full | plain                  (default: full)
#   EMBER_REPO             source repository             (default: the official repo)
#   EMBER_NO_MODIFY_PATH   set to 1 to skip editing your shell rc file
#
# Re-running is safe: it rebuilds and replaces the existing install in place.

set -eu

EMBER_REPO="${EMBER_REPO:-https://github.com/kmcnally5/ember-lang}"
EMBER_REF="${EMBER_REF:-main}"
EMBER_PREFIX="${EMBER_PREFIX:-$HOME/.ember}"
EMBER_PROFILE="${EMBER_PROFILE:-full}"
BUILD_LOG="${TMPDIR:-/tmp}/ember-install-build.log"
WORKDIR=""

if [ -t 1 ]; then
    BOLD=$(printf '\033[1m'); DIM=$(printf '\033[2m')
    RED=$(printf '\033[31m'); GRN=$(printf '\033[32m'); YLW=$(printf '\033[33m')
    RST=$(printf '\033[0m')
else
    BOLD=; DIM=; RED=; GRN=; YLW=; RST=
fi





info() { printf '%s==>%s %s\n' "$GRN" "$RST" "$*"; }





step() { printf '%s  -%s %s\n' "$DIM" "$RST" "$*"; }





warn() { printf '%swarning:%s %s\n' "$YLW" "$RST" "$*" >&2; }





err() { printf '%serror:%s %s\n' "$RED" "$RST" "$*" >&2; }





die() { err "$@"; exit 1; }





# Remove the temporary checkout on any exit (success, error, or Ctrl-C).
cleanup() {
    [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ] && rm -rf "$WORKDIR"
    return 0
}





have() { command -v "$1" >/dev/null 2>&1; }





# Only macOS is supported today; the build is exercised on arm64 and x86_64. On any
# other OS, point the user at a manual `make` build rather than guessing.
detect_platform() {
    os=$(uname -s 2>/dev/null || echo unknown)
    arch=$(uname -m 2>/dev/null || echo unknown)
    if [ "$os" != "Darwin" ]; then
        err "Ember currently installs on macOS only (detected: $os)."
        die "Build from source instead: git clone $EMBER_REPO && cd ember-lang && make install"
    fi
    info "macOS detected ($arch)."
}





# emberc is C17 and builds with the Apple toolchain - clang + make from the Xcode
# Command Line Tools. There is no way to compile without them, so stop with the
# one-line fix rather than failing deep inside make.
ensure_toolchain() {
    if ! xcode-select -p >/dev/null 2>&1 || ! have cc || ! have make; then
        err "The Xcode Command Line Tools (clang + make) are required to build Ember."
        err "Install them, then re-run this script:"
        err "    xcode-select --install"
        exit 1
    fi
    for tool in curl tar; do
        have "$tool" || die "'$tool' is required but was not found on PATH."
    done
    step "Toolchain OK (clang + make)."
}





# The flagship build links raylib + FreeType (graphics) and libcurl (networking).
# raylib/freetype are resolved via pkg-config; libcurl via curl-config. We provision
# them with Homebrew. Returns 0 if the full build can proceed, 1 to fall back to plain.
ensure_full_deps() {
    if ! have brew; then
        warn "Homebrew not found - needed for the flagship (graphics + networking) build."
        warn "Install it from https://brew.sh and re-run for the full compiler."
        return 1
    fi

    step "Installing build dependencies via Homebrew (pkg-config, raylib, freetype, curl)..."
    brew install pkg-config raylib freetype curl >/dev/null 2>&1 || \
        warn "brew reported an issue; checking whether the dependencies resolve anyway..."

    # Homebrew's curl is keg-only (not on PATH by default), so expose its curl-config;
    # and make sure pkg-config can see Homebrew's .pc files regardless of how it was installed.
    brew_prefix=$(brew --prefix 2>/dev/null || true)
    if [ -n "$brew_prefix" ]; then
        [ -d "$brew_prefix/opt/curl/bin" ] && PATH="$brew_prefix/opt/curl/bin:$PATH"
        PKG_CONFIG_PATH="$brew_prefix/lib/pkgconfig:$brew_prefix/share/pkgconfig:${PKG_CONFIG_PATH:-}"
        export PATH PKG_CONFIG_PATH
    fi

    if pkg-config --exists raylib freetype2 2>/dev/null && have curl-config; then
        step "Graphics + networking dependencies OK."
        return 0
    fi

    warn "Could not resolve raylib/freetype2/libcurl after install."
    return 1
}





# Download and unpack the requested ref. GitHub's /archive/<ref>.tar.gz works for a
# branch, tag, or commit SHA, so EMBER_REF can be any of them.
fetch_source() {
    WORKDIR=$(mktemp -d)
    trap cleanup EXIT INT TERM
    url="$EMBER_REPO/archive/$EMBER_REF.tar.gz"
    info "Downloading source ($EMBER_REF)..."
    curl -fsSL "$url" -o "$WORKDIR/src.tar.gz" \
        || die "Download failed: $url"
    tar -xzf "$WORKDIR/src.tar.gz" -C "$WORKDIR" \
        || die "Could not unpack the source archive."
    SRCDIR=$(find "$WORKDIR" -maxdepth 1 -type d -name 'ember-lang-*' | head -n1)
    [ -n "$SRCDIR" ] && [ -d "$SRCDIR" ] \
        || die "Unexpected archive layout (no ember-lang-* directory)."
}





# Compile the chosen profile. `make net-graphics` -> build/emberc-net-gfx (a superset
# that also runs plain programs); `make release` -> build/emberc-release. Build output
# goes to a log that survives cleanup so a failure is debuggable.
build_compiler() {
    if [ "$EMBER_PROFILE" = "full" ]; then
        target="net-graphics"; built="build/emberc-net-gfx"
    else
        target="release"; built="build/emberc-release"
    fi

    info "Compiling emberc ($EMBER_PROFILE build - this can take a minute)..."
    if ! ( cd "$SRCDIR" && make "$target" ) >"$BUILD_LOG" 2>&1; then
        err "Build failed. Last lines of $BUILD_LOG:"
        tail -n 30 "$BUILD_LOG" >&2
        exit 1
    fi

    BUILT_BIN="$SRCDIR/$built"
    [ -x "$BUILT_BIN" ] || die "Build reported success but $built is missing."
    rm -f "$BUILD_LOG"
}





# Install layout: $PREFIX/bin/emberc + $PREFIX/std/*.em. emberc resolves the stdlib as
# <dir-of-binary>/../std, so this layout needs no environment variables to work.
install_files() {
    info "Installing to $EMBER_PREFIX..."
    mkdir -p "$EMBER_PREFIX/bin" "$EMBER_PREFIX/std"

    # rm-then-cp, never cp-in-place: macOS caches an ad-hoc code signature per inode,
    # and overwriting the bytes under a reused inode makes the kernel SIGKILL the next
    # exec ("Killed: 9"). Removing first gives the new binary a fresh inode.
    rm -f "$EMBER_PREFIX/bin/emberc"
    cp "$BUILT_BIN" "$EMBER_PREFIX/bin/emberc"
    chmod +x "$EMBER_PREFIX/bin/emberc"

    rm -f "$EMBER_PREFIX"/std/*.em 2>/dev/null || true
    cp "$SRCDIR"/std/*.em "$EMBER_PREFIX/std/"
    step "Installed emberc + $(ls -1 "$EMBER_PREFIX"/std/*.em | wc -l | tr -d ' ') stdlib modules."
}





# Add $PREFIX/bin to PATH via the user's shell rc, guarded so re-runs don't duplicate.
setup_path() {
    bindir="$EMBER_PREFIX/bin"
    case ":$PATH:" in
        *":$bindir:"*) step "$bindir already on PATH."; return 0 ;;
    esac

    if [ "${EMBER_NO_MODIFY_PATH:-0}" = "1" ]; then
        warn "PATH not modified (EMBER_NO_MODIFY_PATH=1). Add this yourself:"
        warn "    export PATH=\"$bindir:\$PATH\""
        return 0
    fi

    case "$(basename "${SHELL:-sh}")" in
        zsh)  rc="$HOME/.zshrc" ;;
        bash) rc="$HOME/.bash_profile" ;;
        *)    rc="$HOME/.profile" ;;
    esac

    marker="# added by ember install.sh"
    if ! { [ -f "$rc" ] && grep -qF "$marker" "$rc"; }; then
        {
            printf '\n%s\n' "$marker"
            printf 'export PATH="%s:$PATH"\n' "$bindir"
        } >>"$rc"
        step "Added $bindir to PATH in $rc."
    fi
    PATH_RC="$rc"
}





# Prove the freshly installed binary actually runs (also confirms stdlib resolution).
verify_install() {
    if ! ver=$("$EMBER_PREFIX/bin/emberc" --version 2>/dev/null); then
        die "Installed emberc did not run. See $BUILD_LOG if the build looked off."
    fi
    info "Installed ${BOLD}emberc${RST} - $ver"
}





print_next_steps() {
    printf '\n%sEmber is installed.%s\n\n' "$BOLD" "$RST"
    if [ -n "${PATH_RC:-}" ]; then
        printf 'Open a new terminal (or run %ssource %s%s) so emberc is on PATH, then:\n\n' \
            "$BOLD" "$PATH_RC" "$RST"
    else
        printf 'Try it:\n\n'
    fi
    printf '    emberc --emit=run hello.em        %s# compile and run on the VM%s\n' "$DIM" "$RST"
    printf '    emberc -o hello hello.em && ./hello %s# native binary%s\n' "$DIM" "$RST"
    if [ "$EMBER_PROFILE" = "full" ]; then
        printf '    ANTHROPIC_API_KEY=sk-ant-... emberc --emit=run app.em   %s# the desktop app%s\n' "$DIM" "$RST"
    fi
    printf '\nRun %semberc --doctor%s to health-check the toolchain, %semberc --help%s for usage.\n' \
        "$BOLD" "$RST" "$BOLD" "$RST"
}





main() {
    printf '%sInstalling Ember%s\n' "$BOLD" "$RST"
    detect_platform
    ensure_toolchain

    if [ "$EMBER_PROFILE" = "full" ]; then
        if ! ensure_full_deps; then
            warn "Falling back to the plain (dependency-free) compiler."
            warn "It runs all non-GUI programs; re-run with deps installed for the desktop app."
            EMBER_PROFILE="plain"
        fi
    fi

    fetch_source
    build_compiler
    install_files
    setup_path
    verify_install
    print_next_steps
}

main "$@"
