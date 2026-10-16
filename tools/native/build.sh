#!/usr/bin/env bash
set -euo pipefail
SRC=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ARCH=$(uname -m); [ "$ARCH" != aarch64 ] || ARCH=arm64
PLATFORM="linux/$ARCH"; [ "$(uname -s)" != Darwin ] || PLATFORM=macos
OUT=${1:-"$SRC/../bin/$PLATFORM/p5-native"}
if [ "$(uname -s)" = Darwin ]; then
    export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
    for formula in openssl@3 curl libxml2 libarchive zlib; do
        prefix=$(brew --prefix "$formula" 2>/dev/null || :)
        [ -z "$prefix" ] || export PKG_CONFIG_PATH="$prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    done
fi
mkdir -p "$(dirname -- "$OUT")"
# libplist 2.3+ supplies the JSON reader; DATA is preserved by our typed adapter.
command -v pkg-config >/dev/null || { printf 'Install pkg-config and the native development libraries.\n' >&2; exit 2; }
pkg-config --atleast-version=2.3 libplist-2.0 || { printf 'libplist 2.3 or newer is required.\n' >&2; exit 2; }
pkg-config --exists libplist-2.0 openssl libzip libcurl zlib libxml-2.0 libarchive
read -r -a CFLAGS <<< "$(pkg-config --cflags libplist-2.0 openssl libzip libcurl zlib libxml-2.0 libarchive)"
read -r -a LIBS <<< "$(pkg-config --libs libplist-2.0 openssl libzip libcurl zlib libxml-2.0 libarchive)"
TEMP="$OUT.tmp.$$"
trap 'rm -f -- "$TEMP"' EXIT
"${CC:-cc}" -O2 -std=gnu11 -Wall -Wextra -Werror -Wno-deprecated-declarations ${CFLAGS[@]+"${CFLAGS[@]}"} "$SRC/core.c" "$SRC/plist.c" "$SRC/zip.c" "$SRC/mux.c" "$SRC/archive.c" "$SRC/process.c" "$SRC/macho.c" ${LIBS[@]+"${LIBS[@]}"} -lbz2 -o "$TEMP"
chmod 755 "$TEMP"
mv -f -- "$TEMP" "$OUT"
printf 'Built native format tool: %s\n' "$OUT" >&2
