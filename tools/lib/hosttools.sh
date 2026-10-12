#!/usr/bin/env bash
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
p5_recovery_fields() { p5_run_timeout 15 "$1" irecovery -q | awk 'match($0,/^[A-Z]+:/) {key=substr($0,1,RLENGTH-1);value=substr($0,RLENGTH+1);sub(/^[ \t]+/,"",value);print key "\t" value}' | jq -Rn '[inputs|split("\t")|{key:.[0],value:.[1]}]|from_entries'; }
p5_check_dfu() {
    local fields=$1 ecid=$2 target=$3 actual chip board mode
    actual=$(printf '%s' "$fields"|jq -r '.ECID//"0"'); chip=$(printf '%s' "$fields"|jq -r '.CPID//"0"'); board=$(printf '%s' "$fields"|jq -r '.BDID//"0"'); mode=$(printf '%s' "$fields"|jq -r '.MODE//""')
    [ "$((actual))" = "$((ecid))" ] && [ "$((chip))" = "$((0x8950))" ] && [ "$((board))" = "$(p5_target "$target"|jq -r .board_id)" ] && [ "$mode" = DFU ] || { p5_fail 'DFU device identity differs'; return 2; }
}
p5_check_recovery() {
    local fields=$1 ecid=$2 target=$3 actual chip board mode
    actual=$(printf '%s' "$fields"|jq -r '.ECID//"0"'); chip=$(printf '%s' "$fields"|jq -r '.CPID//"0"'); board=$(printf '%s' "$fields"|jq -r '.BDID//"0"'); mode=$(printf '%s' "$fields"|jq -r '.MODE//""')
    [ "$((actual))" = "$((ecid))" ] && [ "$((chip))" = "$((0x8950))" ] && [ "$((board))" = "$(p5_target "$target"|jq -r .board_id)" ] && [[ "$mode" = Recovery* ]] || { p5_fail 'Recovery device identity differs'; return 2; }
}
p5_dfu_stage() {
    local fields=$1 flags srtg srnm
    flags=$(printf '%s' "$fields"|jq -r '.IBFL//"0"'); srtg=$(printf '%s' "$fields"|jq -r '.SRTG//empty'); srnm=$(printf '%s' "$fields"|jq -r '.SRNM//empty')
    if [ "$srtg" = N/A ] && [ "$srnm" = N/A ] && [ "$((flags))" = 27 ]; then printf 'pwned-ibss\n'; return; fi
    [ -n "$srtg" ] && [ "$srtg" != N/A ] || { p5_fail 'Unrecognized DFU stage; re-enter physical DFU'; return 2; }
    if printf '%s' "$fields"|jq -e 'has("PWND") or any(.[];contains("PWND:"))' >/dev/null; then printf 'pwned-dfu\n'; else printf 'rom-dfu\n'; fi
}
p5_exploit_binary() {
    if [ "$(uname -s)" = Darwin ]; then if [ "$(uname -m)" = arm64 ]; then printf 'ipwnder\n'; else printf 'x86_64/ipwnder32\n'; fi; else printf 'a6meowing\n'; fi
}
p5_require_boot() { p5_require_tools "$1" irecovery gaster "$(p5_exploit_binary)"; }
p5_prepare_ibss() {
    local bins ecid=$2 target=$3 ibss fields stage nonce next status=0
    bins=$(p5_abs "$1") || return $?; ibss=$(p5_abs "$4") || return $?
    fields=$(p5_recovery_fields "$bins") || return $?
    p5_check_dfu "$fields" "$ecid" "$target" || return $?
    stage=$(p5_dfu_stage "$fields") || return $?
    if [ "$stage" = pwned-ibss ]; then p5_log 'Compatible pwned iBSS already loaded'; return; fi
    p5_require_boot "$bins" || return $?
    if [ "$stage" = rom-dfu ]; then
        p5_log 'Prepare pwned DFU with checkm8'
        (cd -- "$bins" || exit $?; case "$(p5_exploit_binary)" in ipwnder) p5_run_live 180 "$bins" checkm8 ipwnder -pv ;; x86_64/ipwnder32) p5_run_live 180 "$bins" checkm8 x86_64/ipwnder32 -p --noibss ;; *) p5_run_live 180 "$bins" checkm8 a6meowing ;; esac) >&2 || status=$?
        if [ "$status" -ne 0 ]; then
            if [ "$status" = 124 ]; then p5_fail 'checkm8 timed out after 180 seconds; re-enter physical DFU and retry' || :
            else p5_fail "checkm8 exited with status $status" || :; fi
            return "$status"
        fi
        fields=$(p5_recovery_fields "$bins") || return $?
        p5_check_dfu "$fields" "$ecid" "$target" || return $?
        [ "$(p5_dfu_stage "$fields")" = pwned-dfu ] || return 2
    fi
    p5_run_timeout 30 "$bins" gaster reset >&2 || return $?; sleep 1 || return $?
    fields=$(p5_recovery_fields "$bins") || return $?
    p5_check_dfu "$fields" "$ecid" "$target" || return $?
    [ "$(p5_dfu_stage "$fields")" = pwned-dfu ] || return 2
    nonce=$(printf '%s' "$fields"|jq -er .NONC) || return $?
    p5_log 'Upload iBSS and verify DFU identity'
    p5_run_timeout 60 "$bins" irecovery -f "$ibss" >&2 || return $?; sleep 2 || return $?
    fields=$(p5_recovery_fields "$bins") || return $?
    p5_check_dfu "$fields" "$ecid" "$target" || return $?
    [ "$(p5_dfu_stage "$fields")" = pwned-ibss ] && [ "$(printf '%s' "$fields"|jq -r .NONC)" = "$nonce" ] || { p5_fail 'Uploaded iBSS/nonce differs'; return 2; }
}
p5_device_lock() {
    # The inherited descriptor keeps the kernel lock until this Bash exits.
    local path=${1:-"$HOME/.cache/project5c-native6-device.lock"}
    mkdir -p "$(dirname -- "$path")" || return $?
    exec 9> "$path" || return $?
    p5_native lock-fd 9 || { p5_fail 'Another device operation is running'; return 2; }
}
p5_ramboot() {
    local bundle=$1 bins=$2 ecid=$3 execute=$4 report target args id fields
    report=$(p5_verify_bundle "$bundle" yes) || return $?; target=$(printf '%s' "$report"|jq -r .target.HardwareModel) || return $?
    local commands; commands=$(jq -n --arg bins "$bins" --arg bundle "$(p5_abs "$bundle")" '[[($bins+"/irecovery"),"-f",($bundle+"/boot/iBEC.dfu")],[($bins+"/irecovery"),"-f",($bundle+"/boot/DeviceTree.img3")],[($bins+"/irecovery"),"-c","devicetree"],[($bins+"/irecovery"),"-f",($bundle+"/boot/kernelcache.img3")],[($bins+"/irecovery"),"-c","bootx"]]')
    if [ "$execute" = yes ]; then
        p5_device_lock || return $?; p5_prepare_ibss "$bins" "$ecid" "$target" "$bundle/boot/iBSS.dfu" || return $?
        p5_run_timeout 60 "$bins" irecovery -f "$bundle/boot/iBEC.dfu" >&2 || return $?; sleep 2 || return $?
        fields=$(p5_recovery_fields "$bins") || return $?; p5_check_recovery "$fields" "$ecid" "$target" || return $?
        p5_run_timeout 60 "$bins" irecovery -f "$bundle/boot/DeviceTree.img3" >&2 || return $?; p5_run_timeout 60 "$bins" irecovery -c devicetree >&2 || return $?
        p5_run_timeout 60 "$bins" irecovery -f "$bundle/boot/kernelcache.img3" >&2 || return $?; p5_run_timeout 60 "$bins" irecovery -c bootx >&2 || return $?
    else printf '%s\n' "$commands" | jq -r '.[]|@sh' >&2; fi
    jq -n --argjson commands "$commands" --arg execute "$execute" '{preview:($execute!="yes"),commands:$commands,nand_kernel_written:false}'
}
