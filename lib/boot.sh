#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/patches.sh"
source "$P5_LIB/kernel.sh"
COMMAND=${1:-help}; [ "$#" -eq 0 ] || shift; p5_args "$@"
case "$COMMAND" in help|--help) printf 'Usage: boot.sh check|record|resolve --state DIR --model MODEL --ecid ECID [--work DIR]\n'; exit 0 ;; check|record|resolve) ;; *) exit 2 ;; esac
p5_required state model ecid
STATE=$(p5_abs "$(p5_get state)"); MODEL=$(p5_get model); ECID=$(p5_get ecid); ECID=$((ECID)); [ "$ECID" -gt 0 ] || exit 2
printf -v HEX '0x%x' "$ECID"; RECEIPT="$STATE/$HEX.json"; SAVED=null; WORK=$(p5_get work)
if [ "$COMMAND" = resolve ] && [ -f "$RECEIPT" ]; then
    SAVED=$(cat "$RECEIPT"); printf '%s' "$SAVED"|jq -e --arg model "$MODEL" --argjson ecid "$ECID" '.model==$model and .ecid==$ecid' >/dev/null || { p5_fail 'Saved boot device differs'; exit 2; }
    SAVED_WORK=$(printf '%s' "$SAVED"|jq -r .workspace); case "$SAVED_WORK" in /*) ;; *) SAVED_WORK="$STATE/$SAVED_WORK" ;; esac; SAVED_WORK=$(p5_abs "$SAVED_WORK")
    [ -z "$WORK" ] || [ "$(p5_abs "$WORK")" = "$SAVED_WORK" ] || { p5_fail "Use this device's last restore workspace: $SAVED_WORK"; exit 2; }; WORK=$SAVED_WORK
fi
[ -n "$WORK" ] || { p5_fail 'No installed boot bundle; flash first or supply --work'; exit 2; }; WORK=$(p5_abs "$WORK")
BOOT_ONLY=yes
REPORT=$(p5_verify_bundle "$WORK/bundle" "$BOOT_ONLY"); BOARD=$(p5_target "$MODEL"|jq -r .HardwareModel)
printf '%s' "$REPORT"|jq -e --arg model "$MODEL" --arg board "$BOARD" '.target.ProductType==$model and .target.HardwareModel==$board and (.target.ProductVersion=="6.1.3" or .target.ProductVersion=="6.1.4")' >/dev/null || { p5_fail 'Boot bundle model/version differs'; exit 2; }
if [ "$COMMAND" != resolve ] || [ "$SAVED" != null ]; then
    COMPONENTS=$(p5_components "$BOARD")
    jq -e --arg board "$BOARD" --arg version "$(printf '%s' "$REPORT"|jq -r .target.ProductVersion)" '.target==$board and .source_version.ProductVersion==$version' "$WORK/session/restore.json" >/dev/null || exit 2
    for KEY in kernel devicetree; do
        FILE=kernelcache.img3; [ "$KEY" != devicetree ] || FILE=DeviceTree.img3
        REL=$(printf '%s' "$COMPONENTS"|jq -r --arg key "$KEY" '.[$key]')
        MATCH_FILE="$WORK/bundle/boot/$FILE"
        if [ "$KEY" = kernel ] && jq -e '.restore_sensor_dependency!=null' "$WORK/session/restore.json" >/dev/null; then
            p5_temp; MATCH_FILE="$P5_TMP/bootstate-kernel.img3"
            p5_restore_sensor_kernel "$WORK/bundle/boot/$FILE" "$MATCH_FILE" >/dev/null || exit $?
        fi
        [ "$(p5_sha "$MATCH_FILE")" = "$(jq -r --arg rel "$REL" '.integrity_receipts[$rel]' "$WORK/session/restore.json")" ] || { p5_fail "Restored $KEY differs from boot bundle"; exit 2; }
    done
fi
HASHES='{}'; for FILE in iBSS.dfu iBEC.dfu DeviceTree.img3 kernelcache.img3; do HASHES=$(printf '%s' "$HASHES"|jq --arg file "$FILE" --arg sha "$(p5_sha "$WORK/bundle/boot/$FILE")" '.[$file]=$sha'); done
if [ "$COMMAND" = record ]; then
    jq -e --argjson ecid "$ECID" '.physical_restore_verified==true and .restore_finished==true and .returncode==0 and (.device_probe.ecid==null or .device_probe.ecid==$ecid)' "$WORK/session/result.json" >/dev/null || { p5_fail 'Boot registration requires a successful matching restore'; exit 2; }
    # An absolute workspace also remains valid when state and work are on different volumes.
    mkdir -p "$STATE"
    jq -n --arg model "$MODEL" --argjson ecid "$ECID" --arg workspace "$WORK" --arg version "$(printf '%s' "$REPORT"|jq -r .target.ProductVersion)" --argjson hashes "$HASHES" '{model:$model,ecid:$ecid,workspace:$workspace,version:$version,boot_sha256:$hashes}' > "$RECEIPT.tmp"; mv -- "$RECEIPT.tmp" "$RECEIPT"
elif [ "$SAVED" != null ]; then
    printf '%s' "$SAVED"|jq -e --arg version "$(printf '%s' "$REPORT"|jq -r .target.ProductVersion)" --argjson hashes "$HASHES" '.version==$version and (.boot_sha256==null or .boot_sha256==$hashes)' >/dev/null || { p5_fail 'Boot files differ from last successful restore'; exit 2; }
fi
printf '%s\n' "$WORK"
