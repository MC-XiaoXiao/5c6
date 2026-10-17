#!/usr/bin/env bash
# Host paths are needed before package installation and by standalone builders.
p5_host_arch() {
    local architecture
    architecture=$(uname -m) || return $?
    [ "$architecture" != aarch64 ] || architecture=arm64
    # A6 exploit selection follows the physical Mac, including under Rosetta.
    if [ "$(uname -s)" = Darwin ] && [ "$(sysctl -in hw.optional.arm64 2>/dev/null || :)" = 1 ]; then architecture=arm64; fi
    printf '%s\n' "$architecture"
}
p5_prepend_path() {
    local name=$1 directory=$2 current
    current=":${!name}:"
    while [[ "$current" = *":$directory:"* ]]; do current=${current//":$directory:"/:}; done
    current=${current#:}; current=${current%:}
    printf -v "$name" '%s' "$directory${current:+:$current}"
    export "$name"
}
p5_macos_env() {
    [ "$(uname -s)" = Darwin ] || return 0
    local candidate prefix directory
    unset P5_BREW P5_BREW_PREFIX
    candidate=$(command -v brew 2>/dev/null || :)
    if [ -z "$candidate" ]; then
        # Respect the selected Homebrew when it is on PATH. Only discover a
        # default installation when a non-login shell cannot find it.
        if [ "$(uname -m)" = arm64 ]; then candidate=/opt/homebrew/bin/brew; else candidate=/usr/local/bin/brew; fi
        [ -x "$candidate" ] || return 0
    fi
    prefix=$("$candidate" --prefix) || return $?
    P5_BREW=$candidate
    P5_BREW_PREFIX=$prefix
    # opt paths cover keg-only and installed-but-unlinked formulae, and work
    # immediately after deps.sh installs a missing formula in a child shell.
    for directory in "$prefix/sbin" "$prefix/bin" "$prefix/opt/jq/bin" "$prefix/opt/pkgconf/bin" "$prefix/opt/flock/bin" "$prefix/opt/coreutils/bin" "$prefix/opt/libimobiledevice/bin" "$prefix/opt/libplist/bin" "$prefix/opt/libxml2/bin" "$prefix/opt/openssl@3/bin" "$prefix/opt/curl/bin" "$prefix/opt/libarchive/bin"; do
        p5_prepend_path PATH "$directory"
    done
    export PATH
}
p5_build_env() {
    unset LD_LIBRARY_PATH DYLD_LIBRARY_PATH
    p5_macos_env || return $?
    [ "$(uname -s)" = Darwin ] || return 0
    [ -n "${P5_BREW_PREFIX:-}" ] || return 0
    # Homebrew prefixes GNU libtool commands with g to avoid Apple's libtool.
    if [ -x "$P5_BREW_PREFIX/opt/libtool/bin/glibtoolize" ]; then
        export LIBTOOLIZE="${LIBTOOLIZE:-$P5_BREW_PREFIX/opt/libtool/bin/glibtoolize}"
    fi
    local formula prefix directory
    for formula in git cmake autoconf automake libtool; do p5_prepend_path PATH "$P5_BREW_PREFIX/opt/$formula/bin"; done
    for formula in libplist openssl@3 zlib curl libxml2 libarchive libpng bzip2 libimobiledevice libirecovery libimobiledevice-glue libtatsu libusbmuxd libzip; do
        prefix="${P5_BREW_PREFIX:-}/opt/$formula"
        [ -d "$prefix" ] || continue
        directory="$prefix/lib/pkgconfig"
        PKG_CONFIG_PATH=${PKG_CONFIG_PATH:-}; CMAKE_PREFIX_PATH=${CMAKE_PREFIX_PATH:-}
        p5_prepend_path PKG_CONFIG_PATH "$directory"
        p5_prepend_path CMAKE_PREFIX_PATH "$prefix"
    done
}
