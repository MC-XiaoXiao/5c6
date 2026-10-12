#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/http.sh"
p5_validate_source() {
    local path=$1 version=$2 manifest boards board model spec
    p5_temp; p5_zip_member "$path" BuildManifest.plist "$P5_TMP/BuildManifest.plist" || return $?
    manifest=$(p5_plist "$P5_TMP/BuildManifest.plist") || return $?
    board=$(printf '%s' "$manifest"|jq -er '[.BuildIdentities[].Info.DeviceClass|ascii_downcase]|unique|if length==1 and (.[0]=="n41ap" or .[0]=="n42ap") then .[0] else error("Expected original iPhone 5 IPSW") end') || return $?
    model=iPhone5,2; [ "$board" != n41ap ] || model=iPhone5,1
    spec=$(jq -ce --arg board "${board:0:3}" --arg version "$version" '.[$board][$version]' "$P5_ROOT/tools/locks/firmware.json") || return $?
    p5_check_file "$path" "$(printf '%s' "$spec"|jq -r .size)" "$(printf '%s' "$spec"|jq -r .sha256)" || return $?
    printf '%s' "$manifest"|jq -e --arg version "$version" --arg model "$model" '.ProductVersion==$version and (.SupportedProductTypes|index($model)) and ((.ProductVersion=="6.1.3" and .ProductBuildVersion=="10B329") or (.ProductVersion=="6.1.4" and .ProductBuildVersion=="10B350"))' >/dev/null || return 2
    printf '%s\n' "$manifest"
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    p5_args "$@"; p5_required version out
    VERSION=$(p5_get version); OUT=$(p5_abs "$(p5_get out)"); mkdir -p "$OUT"
    SPEC=$(jq -ce --arg v "$VERSION" '.n42[$v]//error("Unsupported firmware")' "$P5_ROOT/tools/locks/firmware.json")
    URL=$(printf '%s' "$SPEC"|jq -r .url); DEST="$OUT/${URL##*/}"
    if [ ! -e "$DEST" ]; then
        mkdir "$DEST.lock" 2>/dev/null || { p5_fail "Download lock exists: $DEST.lock"; exit 2; }
        trap 'rmdir -- "$DEST.lock" 2>/dev/null || :' EXIT
        p5_log 'Download original Apple IPSW (~1 GB)'
        p5_http_fetch firmware 'Apple IPSW download' "$URL" "$DEST.part" "$(printf '%s' "$SPEC"|jq -r .size)" --location --max-filesize "$(printf '%s' "$SPEC"|jq -r .size)" >/dev/null
        p5_log 'Verify downloaded IPSW size and SHA-256'
        p5_check_file "$DEST.part" "$(printf '%s' "$SPEC"|jq -r .size)" "$(printf '%s' "$SPEC"|jq -r .sha256)"
        mv -n -- "$DEST.part" "$DEST"; rmdir -- "$DEST.lock"; trap - EXIT
    fi
    p5_log 'Verify source IPSW identity and integrity'
    p5_validate_source "$DEST" "$VERSION" >/dev/null
    printf '%s\n' "$DEST"
fi
