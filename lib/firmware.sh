#!/usr/bin/env bash
# Format checks used by the builder and restore scripts.
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
p5_tree_node() {
    p5_native tree-json "$1" | jq --arg path "$2" '
      def text: . as $s | [range(0;length;2) as $i|(("0123456789abcdef"|index($s[$i:$i+1]))*16+("0123456789abcdef"|index($s[$i+1:$i+2])))]|map(select(.!=0))|implode;
      def name: [.properties[]|select(.name=="name")|.value|text][0];
      ($path|split("/")|map(select(length>0))) as $names
      |if name==$names[0] then reduce $names[1:][] as $n (.;[.children[]|select(name==$n)]|if length==1 then .[0] else error("DeviceTree node missing/ambiguous") end) else error("DeviceTree root differs") end
      |.properties|map({key:.name,value:.value})|from_entries'
}
p5_tree_identity() {
    local input=$1 model=$2 board props
    board=$(p5_target "$model" | jq -r .HardwareModel) || return $?
    props=$(p5_native tree-json "$input" | jq '.properties|map({key:.name,value:.value})|from_entries') || return $?
    local mh bh; mh=$(printf '%s\0' "$model" | od -An -v -tx1 | tr -d '[:space:]'); bh=$(printf '%s\0' "$board" | od -An -v -tx1 | tr -d '[:space:]')
    printf '%s\n' "$props" | jq -e --arg model "$mh" --arg board "$bh" '.model==$model and (.compatible|contains($board))' >/dev/null || { p5_fail 'DeviceTree identity differs'; return 2; }
}
p5_unpack_kernel() {
    local input=$1 output=$2 raw="$2.raw"
    if [ "$(p5_native hex-range "$input" 0 4)" = cefaedfe ]; then cp -- "$input" "$output"; return; fi
    p5_native img3-data "$input" "$raw" || return $?
    if [ "$(p5_native hex-range "$raw" 0 8)" = 636f6d706c7a7373 ]; then p5_native lzss-unpack "$raw" "$output" || return $?; else cp -- "$raw" "$output" || return $?; fi
    rm -f -- "$raw"
}
p5_wifi_files() {
    local dir=$1 model=$2 prefix name path size
    prefix=muscat; [ "$model" != iPhone5,3 ] || prefix=barolo
    for name in "$prefix.trx" "$prefix-m-mt.txt" "$prefix-t-kk.txt" "$prefix-u-kk.txt"; do
        path="$dir/$name"
        [ -f "$path" ] && [ ! -L "$path" ] || { p5_fail "Missing WiFi donor: $name"; return 2; }
        if [[ "$name" = *.trx ]]; then
            [ "$(p5_native hex-range "$path" 0 4)" = 48445230 ] || { p5_fail 'Invalid WiFi TRX'; return 2; }
            size=$(p5_native hex-range "$path" 4 4); size=$((16#${size:6:2}${size:4:2}${size:2:2}${size:0:2}))
            [ "$size" = "$(p5_size "$path")" ] || { p5_fail 'WiFi TRX length differs'; return 2; }
        else
            LC_ALL=C grep -q 'moduleid=' "$path" && LC_ALL=C grep -q 'devid=' "$path" || { p5_fail 'Invalid WiFi calibration'; return 2; }
            [ "$(tr -d '\000' < "$path" | wc -c | tr -d '[:space:]')" = "$(p5_size "$path")" ] || return 2
        fi
        jq -nc --arg path "usr/share/firmware/wifi/43342a0/$name" --arg source "$(p5_abs "$path")" --arg sha "$(p5_sha "$path")" '{path:$path,source:$source,sha256:$sha}'
    done
}
p5_apply_fixed() {
    local input=$1 info=$2 profile=$3 output=$4 idempotent=${5:-no} row patch sha size id model
    id=$(printf '%s' "$info"|jq -r .id); model=$(printf '%s' "$info"|jq -r .model)
    sha=$(p5_sha "$input") || return $?; size=$(p5_size "$input") || return $?
    row=$(awk -F '\t' -v id="$id" -v model="$model" -v profile="$profile" -v sha="$sha" -v size="$size" -v idempotent="$idempotent" \
      '$1==id && ($2=="*" || $2==model) && ($3=="*" || $3==profile) && (($4==size && $5==sha) || (idempotent=="yes" && $7==size && $8==sha)) {print; n++} END {if(n!=1)exit 2}' "$P5_ROOT/patches/files.tsv") || { p5_fail "Unsupported original for $id ($model/$profile)"; return 2; }
    local input_size input_sha patch_path output_size output_sha
    IFS=$'\t' read -r id model profile input_size input_sha patch_path output_size output_sha <<< "$row"
    patch=$(p5_relative "$P5_ROOT/patches" "$patch_path") || return $?
    if [ "$idempotent" = yes ] && [ "$size" = "$output_size" ] && [ "$sha" = "$output_sha" ]; then
        cp -- "$input" "$output" || return $?
    else p5_native apply "$input" "$patch" "$output" || return $?; fi
    p5_check_file "$output" "$output_size" "$output_sha" || return $?
    jq -nc --arg patch "$patch_path" --arg source "$sha" --arg output "$output_sha" '{format:"BSDIFF40",patch:$patch,source_sha256:$source,output_sha256:$output}'
}
# Dense u32 handoff and the retained 1296 MHz boost use the same checked deltas
# for stock, normal-boot and restore iBoot-1940.1.75 binaries on N48 and N49.
p5_patch_pmgr_boot() {
    local kind=$1 input=$2 output=$3 id model info
    [ "$input" != "$output" ] || { p5_fail 'PMGR patch requires a separate output'; return 2; }
    case "$kind" in iBSS) id=pmgr-ibss ;; iBEC) id=pmgr-ibec ;; *) p5_fail 'Unknown PMGR boot component'; return 2 ;; esac
    LC_ALL=C grep -aFq 'iBoot-1940.1.75' "$input" || { p5_fail 'Unsupported PMGR boot version'; return 2; }
    if LC_ALL=C grep -aFq "$kind for n48ap" "$input"; then model=iPhone5,3
    elif LC_ALL=C grep -aFq "$kind for n49ap" "$input"; then model=iPhone5,4
    else p5_fail 'Wrong PMGR boot donor'; return 2; fi
    info=$(jq -nc --arg id "$id" --arg model "$model" '{id:$id,model:$model}') || return $?
    p5_apply_fixed "$input" "$info" '' "$output" yes >/dev/null || return $?
    case "$kind" in
        iBSS) printf '{"cpu_boost_hz":1296000000,"voltage_indices_preserved":true}\n' ;;
        iBEC) printf '{"period_cell_bytes":4,"reserved_word_store_removed":true}\n' ;;
    esac
}
p5_patch_ramdisk_binary() {
    local kind=$1 input=$2 output=$3 anchor replacement relative start at epilogue
    case "$kind" in
        asr) anchor=784410f0b6e80125f3e717980ff012ef4df6a430c0f20000784410f0aae8502419980ff0; relative=16; replacement=fff7ebbf ;;
        restored) anchor=2046a8478346bbf1000f11d14af64a210822c0f20c0141f2c9307944c0f20800cdf8048009687844; relative=12; replacement=002400f036b9 ;;
        *) p5_fail 'Unknown dynamic binary patch'; return 2 ;;
    esac
    [ "$(p5_native hex-range "$input" 0 4)" = cefaedfe ] || return 2
    start=$(p5_native locate "$input" "$anchor") || return $?
    if [ "$kind" = restored ]; then
        epilogue=0398002c01684ff00000419a08bf0120914202bf42b0bde8000df0bd
        [ "$(p5_native hex-range "$input" "$((start+0x27e))" "$((${#epilogue}/2))")" = "$epilogue" ] || { p5_fail 'Restored epilogue layout differs'; return 2; }
    fi
    at=$((start+relative)); p5_native edit "$input" "$output" "$at" "$replacement" || return $?
    local pages; pages=$(p5_native signature "$output" "$output") || return $?; p5_native signature "$output" >/dev/null || return $?
    jq -n --argjson offset "$at" --argjson pages "$pages" '{feature_offset:$offset,code_pages_updated:$pages}'
}
