#!/usr/bin/env bash
# Use the original restored -> BasebandData -> idevicerestore -> BBUpdater flow.
p5_native_bb_restore_options() {
    # iOS 6 copy_restore_options reads this file; StartRestore flags alone do
    # not replace it. Preserve the ordinary OS restore and enable its updater.
    jq '.UpdateBaseband=true|.BasebandNVRestoreItems=3|.BasebandUpdater={DisallowFusing:true,EraseEFS:false,NVRestoreSetting:3}'
}
p5_native_bb_compat() {
    local agent="$P5_ROOT/payload/baseband/native/project5c-baseband.dylib"
    jq -e --arg source "$(p5_sha "$P5_ROOT/tools/device/baseband-compat.c")" --arg binary "$(p5_sha "$agent")" '.mode=="native" and .source_sha256==$source and .dylib_sha256==$binary and .supported_updaters==["ios6-libbbu128"] and .link_stubs_deployed==false' "${agent%.dylib}.json" >/dev/null || { p5_fail 'Native compatibility library receipt differs'; return 2; }
    printf '%s\n' "$agent"
}
p5_native_bb_ramdisk() {
    local bins=$1 image=$2 original=$3 output=$4 agent guards
    agent=$(p5_native_bb_compat) || return $?
    # iOS 6's restore image has the versioned IOKit install name, without the
    # framework-root alias normally present on later images.
    p5_temp || return $?
    p5_hfs_extract "$bins" "$image" System/Library/Frameworks/IOKit.framework/Versions/A/IOKit "$P5_TMP/native-bb-iokit" || return $?
    guards=$(p5_native baseband-image "$original" "$output") || return $?
    printf '%s' "$guards"|jq -e '.native_build=="ios6-libbbu128" and .authentication_modified==false' >/dev/null || return 2
    p5_hfs_add "$bins" "$image" usr/local/lib/project5c-baseband.dylib "$agent" 493 || return $?
    printf '%s' "$guards"|jq --arg dylib "$(p5_sha "$agent")" '.+{flow:"idevicerestore-BasebandData",compatibility_library_sha256:$dylib,ramdisk_count:1}'
}
p5_native_bb_verify() {
    local dir=$1 report=$2 bins=$3 current=${4:-no} expected agent short name actual
    printf '%s' "$report"|jq -e '.baseband_native_flow.flow=="idevicerestore-BasebandData" and .baseband_native_flow.ramdisk_count==1 and .baseband_native_flow.authentication_modified==false' >/dev/null || { p5_fail 'Rebuild session to enable native BasebandData'; return 2; }
    if [ "$current" = yes ]; then
        printf '%s' "$report"|jq -e '.baseband_native_flow.factory_preserves_transport_profile==true and .baseband_native_flow.factory_reports_initialization_errors==true' >/dev/null || { p5_fail 'Rebuild ramdisk with the native factory compatibility patch'; return 2; }
    fi
    agent=$(p5_native_bb_compat) || return $?
    expected=$(printf '%s' "$report"|jq -r .baseband_native_flow.compatibility_library_sha256)
    [ "$expected" = "$(p5_sha "$agent")" ] || return 2
    p5_temp || return $?
    p5_hfs_extract "$bins" "$dir/RestoreRamDisk.hfs" usr/local/lib/project5c-baseband.dylib "$P5_TMP/native-bb-compat" || return $?
    [ "$(p5_sha "$P5_TMP/native-bb-compat")" = "$expected" ] || return 2
    p5_hfs_extract "$bins" "$dir/RestoreRamDisk.hfs" usr/local/bin/restored_external "$P5_TMP/native-bb-restored" || return $?
    [ "$(p5_sha "$P5_TMP/native-bb-restored")" = "$(printf '%s' "$report"|jq -r .restored.sha256)" ] || { p5_fail 'Native restored readback differs'; return 2; }
    short=$(printf '%s' "$report"|jq -r '.target|ascii_downcase|.[0:3]')
    for name in options.plist "options.$short.plist"; do
        p5_hfs_extract "$bins" "$dir/RestoreRamDisk.hfs" "usr/local/share/restore/$name" "$P5_TMP/native-bb-options" || return $?
        actual=$(p5_plist "$P5_TMP/native-bb-options") || return $?
        jq -ne --argjson actual "$actual" --argjson expected "$(printf '%s' "$report"|jq .restore_options)" '$actual==$expected' >/dev/null || { p5_fail 'Ramdisk restore options readback differs'; return 2; }
    done
}
p5_native_bb_upgrade() {
    local dir=$1 out=$2 original_ram=$3 bins=$4 report flow restored ram_path short options receipts kernel_path dependency
    [ ! -e "$out" ] || { p5_fail 'Output already exists'; return 2; }
    report=$(p5_restore_session "$dir") || return $?
    printf '%s' "$report"|jq -e '.baseband_native==true' >/dev/null || { p5_fail 'Session has no native baseband source'; return 2; }
    mkdir -p "$(dirname -- "$out")" || return $?
    if [ "$(uname -s)" = Linux ]; then cp -a --reflink=auto -- "$dir" "$out" || return $?;
    else cp -Rp "$dir" "$out" || return $?; fi
    touch "$out/.project5c-incomplete" || return $?
    # Changing the ramdisk/kernel must not inherit a previous success receipt.
    p5_restore_archive "$out" || return $?
    p5_temp || return $?
    kernel_path=$(printf '%s' "$report"|jq -r .components.kernel) || return $?
    dependency=$(p5_restore_sensor_kernel "$dir/$kernel_path" "$P5_TMP/bb-restore-kernel.img3") || return $?
    mv -- "$P5_TMP/bb-restore-kernel.img3" "$out/$kernel_path" || return $?
    p5_hfs_extract "$bins" "$original_ram" usr/local/bin/restored_external "$P5_TMP/bb-original" || return $?
    flow=$(p5_native_bb_ramdisk "$bins" "$out/RestoreRamDisk.hfs" "$P5_TMP/bb-original" "$P5_TMP/bb-compat") || return $?
    restored=$(p5_patch_ramdisk_binary restored "$P5_TMP/bb-compat" "$P5_TMP/bb-restored") || return $?
    restored=$(printf '%s' "$restored"|jq --arg sha "$(p5_sha "$P5_TMP/bb-restored")" '.+{sha256:$sha}')
    p5_hfs_add "$bins" "$out/RestoreRamDisk.hfs" usr/local/bin/restored_external "$P5_TMP/bb-restored" 493 || return $?
    options=$(printf '%s' "$report"|jq '.restore_options'|p5_native_bb_restore_options)
    printf '%s' "$options"|p5_write_plist "$P5_TMP/bb-options.plist" || return $?
    short=$(printf '%s' "$report"|jq -r '.target|ascii_downcase|.[0:3]')
    for name in options.plist "options.$short.plist"; do p5_hfs_add "$bins" "$out/RestoreRamDisk.hfs" "usr/local/share/restore/$name" "$P5_TMP/bb-options.plist" 420 || return $?; done
    ram_path=$(printf '%s' "$report"|jq -r .components.ramdisk)
    p5_native img3-wrap "$dir/$ram_path" "$out/RestoreRamDisk.hfs" "$out/$ram_path" plaintext || return $?
    (cd -- "$out"; zip -q -0 -X Restore.ipsw "$ram_path" "$kernel_path") || return $?
    report=$(printf '%s' "$report"|jq --argjson dependency "$dependency" --arg path "$kernel_path" --arg sha "$(p5_sha "$out/$kernel_path")" '.restore_sensor_dependency=$dependency|.integrity_receipts[$path]=$sha') || return $?
    report=$(printf '%s' "$report"|jq --argjson flow "$flow" --argjson restored "$restored" --argjson options "$options" --arg path "$ram_path" --arg ram "$(p5_sha "$out/$ram_path")" --arg ipsw "$(p5_sha "$out/Restore.ipsw")" '.baseband_native_flow=$flow|.restored=$restored|.restore_options=$options|.integrity_receipts[$path]=$ram|.integrity_receipts["Restore.ipsw"]=$ipsw|.physical_restore_verified=false') || return $?
    printf '%s\n' "$report" > "$out/restore.json" || return $?
    p5_native_bb_verify "$out" "$report" "$bins" || return $?
    rm -- "$out/.project5c-incomplete" || return $?
    printf '%s\n' "$report"
}
