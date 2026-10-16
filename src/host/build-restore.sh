#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/../../lib/common.sh"
p5_args "$@"; p5_required out
REVISION=45145e9fdc8458022c61a4b87bd029b866d5bcdc
OUT=$(p5_abs "$(p5_get out)"); [ ! -e "$OUT" ] || { p5_fail 'Output directory already exists'; exit 2; }
p5_temp
if [ -n "$(p5_get source-archive)" ]; then
    ARCHIVE=$(p5_get source-archive)
    SPEC=$(p5_source_tool idevicerestore)
    p5_check_file "$ARCHIVE" "$(printf '%s' "$SPEC"|jq -r .bytes)" "$(printf '%s' "$SPEC"|jq -r .sha256)"
    mkdir -p "$OUT"; bsdtar -xf "$ARCHIVE" -C "$OUT" --strip-components 1 --no-same-owner
elif [ -n "$(p5_get source)" ]; then
    git -C "$(p5_get source)" archive "$REVISION" > "$P5_TMP/source.tar"
    mkdir -p "$OUT"; bsdtar -xf "$P5_TMP/source.tar" -C "$OUT" --no-same-owner
else p5_fail 'Specify --source or --source-archive'; exit 2; fi
printf '1.0.0-native6-5c-bb-native-v2\n' > "$OUT/.tarball-version"
(cd -- "$OUT"; git apply --check "$P5_ROOT/patches/host/restore.patch"; git apply "$P5_ROOT/patches/host/restore.patch")
cp -- "$P5_ROOT/src/host/sign.c" "$OUT/src/project5c-baseband-sign.c"
(cd -- "$OUT"; git apply --check "$P5_ROOT/patches/host/sign.patch"; git apply "$P5_ROOT/patches/host/sign.patch")
cp -- "$P5_ROOT/src/host/modem.c" "$OUT/src/project5c-baseband-native.c"
(cd -- "$OUT"; git apply --check "$P5_ROOT/patches/host/modem.patch"; git apply "$P5_ROOT/patches/host/modem.patch")
(
    p5_build_env
    cd -- "$OUT"
    autoreconf -fi
    ./configure --without-reverse-proxy
    make -j4
) > "$OUT/build.log" 2>&1
p5_log "Built restore host: $OUT/src/idevicerestore"
