#!/usr/bin/env bash
# Use the original restored -> BasebandData -> idevicerestore -> BBUpdater flow.
p5_native_bb_restore_options() {
    # iOS 6 copy_restore_options reads this file; StartRestore flags alone do
    # not replace it. Preserve the ordinary OS restore and enable its updater.
    jq '.UpdateBaseband=true|.BasebandNVRestoreItems=3|.BasebandUpdater={DisallowFusing:true,EraseEFS:false,NVRestoreSetting:3}'
}
p5_native_bb_compat() {
    local agent="$P5_ROOT/resources/baseband.dylib"
    [ -s "$agent" ] || { p5_fail 'Missing baseband compatibility library'; return 2; }
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
    # restore_install already verified these immutable files before booting.
    [ "${P5_VERIFIED_SESSION:-}" != "$dir" ] || return 0
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
