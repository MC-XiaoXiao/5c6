#!/usr/bin/env bash
set -euo pipefail
SRC=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ARCH=$(uname -m); [ "$ARCH" != aarch64 ] || ARCH=arm64
PLATFORM="linux/$ARCH"; [ "$(uname -s)" != Darwin ] || PLATFORM=macos
OUT=${1:-"$SRC/../../bin/$PLATFORM/p5-native"}
source "$SRC/../../lib/host.sh"
p5_build_env
mkdir -p "$(dirname -- "$OUT")"
# libplist 2.3+ supplies the JSON reader; DATA is preserved by our typed adapter.
command -v pkg-config >/dev/null || { printf 'Install pkg-config and the native development libraries.\n' >&2; exit 2; }
pkg-config --atleast-version=2.3 libplist-2.0 || { printf 'libplist 2.3 or newer is required.\n' >&2; exit 2; }
pkg-config --exists libplist-2.0 openssl libxml-2.0
read -r -a CFLAGS <<< "$(pkg-config --cflags libplist-2.0 openssl libxml-2.0)"
read -r -a LIBS <<< "$(pkg-config --libs libplist-2.0 openssl libxml-2.0)"
DL_LIBS=()
# dlopen is in libSystem on macOS and the standard system libdl on Linux.
[ "$(uname -s)" = Darwin ] || DL_LIBS=(-ldl)
TEMP="$OUT.tmp.$$"
trap 'rm -f -- "$TEMP"' EXIT
"${CC:-cc}" -O2 -std=gnu11 -Wall -Wextra -Werror -Wno-deprecated-declarations ${CFLAGS[@]+"${CFLAGS[@]}"} "$SRC/core.c" "$SRC/plist.c" "$SRC/mux.c" "$SRC/macho.c" "$SRC/media.c" "$SRC/kernel.c" "$SRC/usb.c" ${LIBS[@]+"${LIBS[@]}"} ${DL_LIBS[@]+"${DL_LIBS[@]}"} -o "$TEMP"
chmod 755 "$TEMP"
mv -f -- "$TEMP" "$OUT"
printf 'Built project firmware helper: %s\n' "$OUT" >&2
