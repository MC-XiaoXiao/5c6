#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/download.sh"
source "$P5_LIB/patches.sh"
p5_args "$@"; p5_required source-ipsw tools-dir work model version
IPSW=$(p5_get source-ipsw); BINS=$(p5_get tools-dir); WORK=$(p5_abs "$(p5_get work)"); MODEL=$(p5_get model); VERSION=$(p5_get version)
p5_target "$MODEL" >/dev/null; p5_require_tools "$BINS" dmg hfsplus; mkdir -p "$WORK"
[ ! -e "$WORK/firmware" ] && [ ! -e "$WORK/inputs" ] || { p5_fail 'Firmware/inputs destination exists'; exit 2; }
p5_temp "$WORK"; mkdir -p "$P5_TMP/firmware" "$P5_TMP/inputs"
MANIFEST=$(p5_validate_source "$IPSW" "$VERSION")
IDENTITY=$(printf '%s' "$MANIFEST"|jq -ce '[.BuildIdentities[]|select(.Info.RestoreBehavior=="Erase")]|if length==1 then .[0] else error("Erase identity ambiguous") end')
BOARD=$(printf '%s' "$IDENTITY"|jq -r '.Info.DeviceClass|ascii_downcase'); PREFIX=${BOARD:0:3}
KEYFILE=$(p5_get keys)
if [ -n "$KEYFILE" ]; then cp -- "$KEYFILE" "$P5_TMP/keys.json";
else
    SOURCE_MODEL=iPhone5,2; [ "$PREFIX" != n41 ] || SOURCE_MODEL=iPhone5,1
    bash "$P5_LIB/keys.sh" --model "$SOURCE_MODEL" --version "$VERSION" --build "$(printf '%s' "$MANIFEST"|jq -r .ProductBuildVersion)" --components KernelCache,DeviceTree,RestoreRamDisk --rootfs yes | jq '{source:.}' > "$P5_TMP/keys.json"
fi
member_path() { local path; path=$(printf '%s' "$IDENTITY"|jq -er --arg name "$1" '.Manifest[$name].Info.Path'); p5_relative "$P5_TMP" "$path" >/dev/null; printf '%s\n' "$path"; }
decrypt_component() {
    local kind=$1 output=$2 iv key
    p5_zip_member "$IPSW" "$(member_path "$kind")" "$P5_TMP/$kind.img3"
    iv=$(jq -er --arg kind "$kind" '.source[$kind].iv' "$P5_TMP/keys.json"); key=$(jq -er --arg kind "$kind" '.source[$kind].key' "$P5_TMP/keys.json")
    p5_native img3-data "$P5_TMP/$kind.img3" "$output" "$iv" "$key"
}
p5_log 'Extract/decrypt original RootFS'
unzip -p "$IPSW" "$(member_path OS)" > "$P5_TMP/source-rootfs.dmg"
ROOTKEY=$(jq -er .source.rootfs "$P5_TMP/keys.json")
p5_run_timeout 1800 "$BINS" dmg extract "$P5_TMP/source-rootfs.dmg" "$P5_TMP/source-rootfs.raw" -k "$ROOTKEY" > "$P5_TMP/decrypt.log" 2>&1 || { p5_fail 'RootFS decryption failed; check workspace space/quota and keys'; exit 2; }
rm -- "$P5_TMP/source-rootfs.dmg"
p5_native hfs-copy "$P5_TMP/source-rootfs.raw" "$P5_TMP/firmware/source-rootfs.hfs" >/dev/null
rm -- "$P5_TMP/source-rootfs.raw"
p5_log 'Decode source kernel and DeviceTree'
decrypt_component KernelCache "$P5_TMP/kernel.complzss"
p5_native lzss-unpack "$P5_TMP/kernel.complzss" "$P5_TMP/inputs/$PREFIX-kernel.macho"
LENGTH=$(p5_native hex-range "$P5_TMP/kernel.complzss" 16 4); LENGTH=$((16#$LENGTH+384))
dd if="$P5_TMP/kernel.complzss" of="$P5_TMP/inputs/$PREFIX-kernel.complzss" bs="$LENGTH" count=1 2>/dev/null
decrypt_component DeviceTree "$P5_TMP/tree.dtb"; p5_native tree-trim "$P5_TMP/tree.dtb" "$P5_TMP/inputs/$PREFIX-devicetree.dtb"
p5_log 'Extract original runtime inputs'
for suffix in cache virtualaudio locationd commcenter bluetool; do
    id="$PREFIX-$suffix"; path=$(p5_input_path "$id")
    p5_hfs_run 180 "$BINS" "$P5_TMP/firmware/source-rootfs.hfs" extract "$path" "$P5_TMP/inputs/$id"
done
p5_hfs_run 180 "$BINS" "$P5_TMP/firmware/source-rootfs.hfs" extract /System/Library/CoreServices/SystemVersion.plist "$P5_TMP/inputs/SystemVersion.plist"
decrypt_component RestoreRamDisk "$P5_TMP/ramdisk.raw"
cp -- "$P5_TMP/RestoreRamDisk.img3" "$P5_TMP/firmware/restore-ramdisk.img3"
p5_native hfs-copy "$P5_TMP/ramdisk.raw" "$P5_TMP/firmware/restore-ramdisk.hfs" >/dev/null
p5_log "Install model-matched donor inputs: $MODEL"
copy_donor() { cp -- "$P5_ROOT/resources/$2" "$P5_TMP/inputs/$1"; }
copy_donor n49-isp.bin firmware/isp.bin
copy_donor n49-setfile.dat firmware/setfile.dat
if [ "$MODEL" = iPhone5,4 ]; then
    copy_donor n49-mtprops firmware/touch.mtprops
    copy_donor n49-ibss.bin n49/n49-ibss.bin
    copy_donor n49-ibec.bin n49/n49-ibec.bin
else
    copy_donor N48.mtprops firmware/touch.mtprops
    copy_donor iBSS.n48.dfu n48/iBSS.n48.dfu
    copy_donor iBEC.n48.dfu n48/iBEC.n48.dfu
fi
if [ "$MODEL" = iPhone5,4 ]; then cp -- "$P5_TMP/inputs/n49-ibec.bin" "$P5_TMP/firmware/donor-ibec.bin";
else
    if jq -e .donor "$P5_TMP/keys.json" >/dev/null; then jq .donor "$P5_TMP/keys.json" > "$P5_TMP/donor-keys.json";
    else bash "$P5_LIB/keys.sh" --model "$MODEL" --version 7.0.1 --build 11A470a --components iBSS,iBEC > "$P5_TMP/donor-keys.json"; fi
    for kind in iBSS iBEC; do
        iv=$(jq -er --arg kind "$kind" '.[$kind].iv' "$P5_TMP/donor-keys.json"); key=$(jq -er --arg kind "$kind" '.[$kind].key' "$P5_TMP/donor-keys.json")
        p5_native img3-data "$P5_TMP/inputs/$kind.n48.dfu" "$P5_TMP/$kind.bin" "$iv" "$key"
        LC_ALL=C grep -aFq "$kind for n48ap" "$P5_TMP/$kind.bin" || exit 2
    done
    cp -- "$P5_TMP/iBEC.bin" "$P5_TMP/inputs/iBEC.n48.bin"; cp -- "$P5_TMP/iBEC.bin" "$P5_TMP/firmware/donor-ibec.bin"
    jq -n --slurpfile original "$P5_TMP/keys.json" --slurpfile donor "$P5_TMP/donor-keys.json" '$original[0]+{donor:$donor[0]}' > "$P5_TMP/firmware/keys.json"
fi
[ "$(p5_plist "$P5_TMP/inputs/SystemVersion.plist"|jq -r .ProductVersion)" = "$VERSION" ] || exit 2
[ -f "$P5_TMP/firmware/keys.json" ] || cp -- "$P5_TMP/keys.json" "$P5_TMP/firmware/keys.json"
# Publish only after all originals and donor inputs are ready.
mv -- "$P5_TMP/firmware" "$WORK/firmware"; mv -- "$P5_TMP/inputs" "$WORK/inputs"
p5_log "Inputs ready: $WORK/inputs"
