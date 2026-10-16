#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/../../lib/common.sh"
p5_args "$@"; p5_required source build out
SRC=$(p5_abs "$(p5_get source)"); BUILD=$(p5_abs "$(p5_get build)"); OUT=$(p5_abs "$(p5_get out)")
[ ! -e "$OUT" ] || { p5_fail 'Output directory already exists'; exit 2; }
for path in "$SRC/dmg/dmg.c" "$SRC/includes/dmg/dmg.h" "$BUILD/dmg/libdmg.a" "$BUILD/hfs/libhfs.a" "$BUILD/common/libcommon.a"; do [ -f "$path" ] || { p5_fail "Missing source/library: $path"; exit 2; }; done
mkdir -p "$OUT/source/dmg"; cp -- "$SRC/dmg/io.c" "$OUT/source/dmg/io.c"
(cd -- "$OUT/source"; git apply --check "$P5_ROOT/patches/host/dmg-zero.patch"; git apply "$P5_ROOT/patches/host/dmg-zero.patch")
cp -- "$OUT/source/dmg/io.c" "$OUT/io-explicit-zero.c"
p5_build_env
read -r -a CFLAGS <<< "$(pkg-config --cflags openssl)"; read -r -a LIBS <<< "$(pkg-config --libs openssl zlib)"
CC=$(p5_get cc cc)
{
    "$CC" -O2 -DHAVE_CRYPT "-I$SRC/includes" ${CFLAGS[@]+"${CFLAGS[@]}"} -c "$OUT/io-explicit-zero.c" -o "$OUT/io-explicit-zero.o"
    "$CC" -O2 -DHAVE_CRYPT "-I$SRC/includes" ${CFLAGS[@]+"${CFLAGS[@]}"} "$SRC/dmg/dmg.c" "$OUT/io-explicit-zero.o" "$BUILD/dmg/libdmg.a" "$BUILD/hfs/libhfs.a" "$BUILD/common/libcommon.a" ${LIBS[@]+"${LIBS[@]}"} -o "$OUT/dmg"
} > "$OUT/build.log" 2>&1
p5_log "Built explicit-zero DMG tool: $OUT/dmg"
