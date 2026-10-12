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
p5_springboard_check() {
    local data=$1 offset value
    while IFS=$'\t' read -r offset value; do
        [ "$(p5_native hex-range "$data" "$offset" "$((${#value}/2))")" = "$value" ] || { p5_fail 'SpringBoard instruction differs'; return 2; }
    done < <(jq -r '.features[]|[.offset,.feature]|@tsv' "$P5_ROOT/patches/springboard.json")
}
p5_prelink_check() {
    local data=$1 spec=$2
    p5_native prelink "$data" | jq -e --argjson spec "$spec" '
      [._PrelinkInfoDictionary[]|select(.CFBundleIdentifier==$spec.bundle_id)]
      |length==1 and any(.[0].IOKitPersonalities[]; . as $p|all($spec.matching|to_entries[];$p[.key]==.value))' >/dev/null || { p5_fail 'Required prelink personality missing'; return 2; }
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
p5_wifi_check() {
    local kernel=$1 tree=$2 model=$3 prefix=muscat props meta raw exe offset value
    [ "$model" != iPhone5,3 ] || prefix=barolo
    p5_temp; raw="$P5_TMP/wifi-kernel.$RANDOM"; exe="$P5_TMP/wifi-kext.$RANDOM"
    p5_unpack_kernel "$kernel" "$raw" || return $?
    props=$(p5_tree_node "$tree" '/device-tree/arm-io/usb-complex/usb-ehci/wlan') || return $?
    local module; module=$(printf '%s\0' "$prefix" | od -An -v -tx1 | tr -d '[:space:]')
    printf '%s\n' "$props" | jq -e --arg module "$module" '."module-instance"==$module' >/dev/null || return 2
    if [ "$model" = iPhone5,4 ]; then
        printf '%s\n' "$props" | jq -e ' ."bcom.btc.params"=="060000000f00000008000000c8af000009000000983a00000a000000204e0000" and ."rx-calibration-2.4"==("00"*27) and ."rx-calibration-5.0"==("00"*16) and ."rx-calibration-temp"=="00" and ."wlan.dfrts"=="3c00c80002000500"' >/dev/null || return 2
    fi
    meta=$(p5_native prelink "$raw") || return $?
    printf '%s\n' "$meta" | jq -e --arg prefix "$prefix" '
      [._PrelinkInfoDictionary[]|select(.CFBundleIdentifier=="com.apple.driver.AppleBCMWLANBusInterfaceHSICShim")][0].IOKitPersonalities."43342" as $p
      |($p.idVendor==2652 and $p.idProduct==48417 and ($p.HSICProductInfo|length)==3)
      and ([$p.HSICProductInfo[].HSICRFHardwareInfo[1]]|sort)==["V=m","V=t","V=u"]
      and all($p.HSICProductInfo[];.HSICChipInfo==["s=A1"] and .HSICRFHardwareInfo[0]=="M=IMPE" and (.HSICRFHardwareInfo|length)==2 and (.FilesDB|keys|sort)==(["default",$prefix]|sort) and .FilesDB.default==.FilesDB[$prefix])
      and ([$p.HSICProductInfo[].FilesDB[$prefix][]]|unique|sort)==([".trx","-m-mt.txt","-t-kk.txt","-u-kk.txt"]|map("43342a0/"+$prefix+.)|sort)
      and any(._PrelinkInfoDictionary[];.CFBundleIdentifier=="com.apple.driver.AppleBCMWLANHSICDevice" and (.IOKitPersonalities|has("43342")))' >/dev/null || { p5_fail 'WiFi kernel personalities differ'; return 2; }
    p5_native kext-extract "$raw" 'com.apple.driver.AppleBCMWLANBusInterfaceHSIC' "$exe" || return $?
    while read -r offset value; do [ "$(p5_native hex-range "$exe" "$offset" "$((${#value}/2))")" = "$value" ] || { p5_fail "WiFi instruction differs: $offset"; return 2; }; done <<'CHECKS'
0xf34 4af64e12
0xdd8 4af64e10
0xdf0 4ff40020
0x2d18 00f00cf8
0x2d32 27e0
0x2d34 08b58847204605f0ddf8204608bd
CHECKS
    jq -n --arg model "$model" --arg module "$prefix" --arg sha "$(p5_sha "$exe")" '{model:$model,module:$module,hsic_v2_features_verified:true,bus_executable_sha256:$sha}'
    rm -f -- "$raw" "$exe"
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
