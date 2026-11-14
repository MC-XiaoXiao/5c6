#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/../../lib/common.sh"
p5_args "$@"; p5_required sdk linker out
SDK=$(p5_abs "$(p5_get sdk)"); LINKER=$(p5_abs "$(p5_get linker)"); OUT=$(p5_abs "$(p5_get out)")
p5_temp
clang -target armv7-apple-ios6.0 -isysroot "$SDK" -mthumb -Os -fPIC -Wall -Wextra -Werror \
    -c "$P5_ROOT/src/fairplay/compat.c" -o "$P5_TMP/compat.o"
mkdir -p "$(dirname -- "$OUT")"
"$LINKER" -arch armv7 -dylib -iphoneos_version_min 6.0 -syslibroot "$SDK" -lSystem \
    -install_name /usr/local/lib/project5c-fairplay-compat.dylib \
    -o "$P5_TMP/compat.dylib" "$P5_TMP/compat.o"
p5_native signature "$P5_TMP/compat.dylib" "$OUT" >/dev/null
