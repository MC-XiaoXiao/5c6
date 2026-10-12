#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/patchctl.sh"
source "$P5_LIB/baseband.sh"
if [ "${1:-}" = --normalize-extras ]; then p5_normalize_extras "${2:-}"; exit; fi
p5_args "$@"
if [ "$(p5_get help no)" = yes ]; then printf 'Usage: selection.sh --version VERSION --model MODEL --inputs DIR|--bundle DIR|--session DIR [--record]\n'; exit 0; fi
p5_required version model
MODEL=$(p5_get model); VERSION=$(p5_get version); PROFILE=$(p5_get profile native6-validated); EXTRAS=$(p5_normalize_extras "$(p5_get extras)"); ACTIVATION=$(p5_get activation hacktivate); JAILBREAK=$(p5_get jailbreak yes); ECID=$(p5_get ecid)
INPUTS=$(p5_get inputs); BUNDLE=$(p5_get bundle); SESSION=$(p5_get session); BB=$(p5_get baseband-firmware); NATIVE=$(p5_get baseband-source); WIFI=$(p5_get wifi-firmware-dir)
case "$VERSION/$ACTIVATION/$JAILBREAK" in 6.1.[34]/hacktivate/yes|6.1.[34]/hacktivate/no|6.1.[34]/none/yes|6.1.[34]/none/no) ;; *) p5_fail 'Invalid firmware/activation/jailbreak selection'; exit 2 ;; esac
[ "$MODEL" != iPhone5,3 ] || [[ ",$EXTRAS," != *,gps,* ]] || { p5_fail 'GPS runtime requires N49'; exit 2; }
SELECTED=$(p5_select "$PROFILE" "$EXTRAS" '' "$MODEL"); BOARD=$(p5_target "$MODEL"|jq -r .HardwareModel)
RECEIPT=$(jq -n --arg model "$MODEL" --arg version "$VERSION" --arg activation "$ACTIVATION" --arg jailbreak "$JAILBREAK" --arg profile "$PROFILE" --arg extras "$EXTRAS" '{model:$model,version:$version,activation:$activation,jailbreak:($jailbreak=="yes")}|if $profile!="native6-validated" or $extras!="" then .+{profile:$profile,extras:($extras|split(",")|map(select(length>0)))} else . end')
if [ "$(p5_get identity-only no)" = yes ]; then
    [ -n "$INPUTS" ] && [ -z "$BUNDLE$SESSION" ] || { p5_fail '--identity-only requires --inputs'; exit 2; }
else
    if [ "$PROFILE" = native6-wifi-candidate ]; then
        WIFI=${WIFI:-"$P5_ROOT/donor/$MODEL/wifi/43342a0"}
        HASHES=$(p5_wifi_files "$WIFI" "$MODEL"|jq -s 'map({key:.path,value:.sha256})|from_entries')
        RECEIPT=$(printf '%s' "$RECEIPT"|jq --argjson hashes "$HASHES" '.wifi_firmware_sha256=$hashes')
    else [ -z "$WIFI" ] || { p5_fail 'Wi-Fi firmware requires candidate profile'; exit 2; }; fi
    if [[ ",$EXTRAS," = *,baseband,* ]]; then
        [ -n "$BB$NATIVE" ] || { p5_fail 'CommCenter requires modem resources'; exit 2; }
        if [ -n "$BB" ]; then p5_validate_baseband "$BB"; RECEIPT=$(printf '%s' "$RECEIPT"|jq --arg sha "$(p5_sha "$BB")" '.baseband_firmware_sha256=$sha'); fi
        if [ -n "$NATIVE" ]; then p5_native_source "$NATIVE" "$MODEL" "${ECID:+$((ECID))}" >/dev/null; RECEIPT=$(printf '%s' "$RECEIPT"|jq --arg sha "$(p5_sha "$NATIVE/source.json")" '.baseband_source_sha256=$sha'); fi
        if [ -n "$ECID" ]; then RECEIPT=$(printf '%s' "$RECEIPT"|jq --argjson ecid "$((ECID))" '.baseband_ecid=$ecid'); fi
    else [ -z "$BB$NATIVE" ] || { p5_fail 'Modem resources require baseband extra'; exit 2; }; fi
fi
if [ "$(p5_get policy-only no)" = yes ]; then [ "$(p5_get record no)" != yes ] || exit 2; exit 0; fi
COUNT=0; for PATH_VALUE in "$INPUTS" "$BUNDLE" "$SESSION"; do [ -z "$PATH_VALUE" ] || COUNT=$((COUNT+1)); done
[ "$COUNT" = 1 ] || { p5_fail 'Select one inputs, bundle or session directory'; exit 2; }
if [ -n "$INPUTS" ]; then METADATA=$(p5_plist "$INPUTS/SystemVersion.plist");
elif [ -n "$BUNDLE" ]; then
    METADATA=$(jq .target "$BUNDLE/build.json")
    jq -e --argjson selected "$SELECTED" --arg model "$MODEL" --arg board "$BOARD" '([.files[].id]|sort)==($selected|sort) and .target.ProductType==$model and .target.HardwareModel==$board' "$BUNDLE/build.json" >/dev/null || { p5_fail 'Bundle selection differs'; exit 2; }
else
    METADATA=$(jq .source_version "$SESSION/restore.json")
    jq -e --arg board "$BOARD" --arg activation "$ACTIVATION" --arg jailbreak "$JAILBREAK" --argjson selected "$SELECTED" --argjson wanted "$RECEIPT" '
      .target==$board and ((.activation!=null)==($activation=="hacktivate")) and ((.jailbreak!=null)==($jailbreak=="yes")) and ((.selected_artifacts|sort)==($selected|sort))
      and (. as $r|all($wanted|to_entries[]|select(.key|IN("wifi_firmware_sha256","baseband_firmware_sha256","baseband_ecid","baseband_source_sha256"));$r[.key]==.value))
      and ((.wifi_firmware_files//[]|sort)==($wanted.wifi_firmware_sha256//{}|keys|sort))' "$SESSION/restore.json" >/dev/null || { p5_fail 'Restore session selection differs'; exit 2; }
    if [ "$(p5_get record no)" != yes ]; then jq -e --argjson wanted "$RECEIPT" '.==$wanted' "$SESSION/selection.json" >/dev/null || { p5_fail 'Saved session selection differs'; exit 2; }; fi
fi
[ "$(printf '%s' "$METADATA"|jq -r .ProductVersion)" = "$VERSION" ] || { p5_fail 'Firmware version differs from selection'; exit 2; }
if [ "$(p5_get record no)" = yes ]; then [ -n "$SESSION" ] || exit 2; (set -o noclobber; printf '%s\n' "$RECEIPT" > "$SESSION/selection.json"); fi
p5_log "Firmware identity checked: $MODEL / $VERSION"
