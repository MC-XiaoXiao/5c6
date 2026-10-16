#!/usr/bin/env bash
source "$(dirname -- "${BASH_SOURCE[0]}")/patches.sh"
source "$P5_LIB/config.sh"
source "$P5_LIB/baseband.sh"
p5_root_add() {
    local path=$1 source=$2 mode=${3:-420} originals=${4:-null} dest before=null after
    dest=$(p5_relative "$P5_FS_ROOT" "$path")
    [ ! -e "$dest" ] || [ -f "$dest" ] || { p5_fail "Installation target is not a file: $path"; return 2; }
    after=$(p5_sha "$source")
    if [ -f "$dest" ]; then
        before=$(p5_sha "$dest"); [ "$before" != "$after" ] || return 0
        if [ "$originals" != null ]; then printf '%s' "$originals"|jq -e --arg before "$before" 'index($before)' >/dev/null || { p5_fail "Unknown existing firmware file: $path"; return 2; }; fi
    fi
    p5_json_update "$P5_FS_PLAN" --arg path "$path" --arg source "$(p5_abs "$source")" --argjson mode "$mode" --arg before "$before" --arg after "$after" '.+[{path:$path,source:$source,mode:$mode,before_sha256:(if $before=="null" then null else $before end),after_sha256:$after}]'
}
p5_root_config() {
    local name=$1 option=$2 remote source output mode
    remote="System/Library/LaunchDaemons/com.apple.$name.plist"; source=$(p5_relative "$P5_FS_ROOT" "$remote")
    [ -f "$source" ] || { p5_fail "Missing original launchd plist: $remote"; return 2; }
    output="$P5_FS_DATA/$name.plist"; p5_config "$name" "$source" "$option" "$output"
    if [ "$(uname -s)" = Darwin ]; then mode=$(stat -f %Lp "$source"); else mode=$(stat -c %a "$source"); fi
    p5_root_add "$remote" "$output" "$((8#$mode))"
}
p5_rootfs_plan() {
    local bundle=$1 root=$2 data=$3 plan=$4 bb=${5:-} native=${6:-} jailbreak=${7:-no} report version ids row path source originals name model board cfg media='' native_report
    P5_FS_ROOT=$(p5_abs "$root"); P5_FS_DATA=$(p5_abs "$data"); P5_FS_PLAN=$(p5_abs "$plan")
    [ "$P5_FS_ROOT" != / ] || { p5_fail 'Host root is not an installation target'; return 2; }
    mkdir -p "$P5_FS_DATA"; printf '[]\n' > "$P5_FS_PLAN"
    report=$(cat "$bundle/build.json"); version=$(p5_plist "$root/System/Library/CoreServices/SystemVersion.plist")
    jq -ne --argjson report "$report" --argjson version "$version" '$report.target.ProductVersion==$version.ProductVersion and $report.target.ProductBuildVersion==$version.ProductBuildVersion' >/dev/null || { p5_fail 'RootFS differs from the bundle source'; return 2; }
    ids=$(printf '%s' "$report"|jq '[.files[].id]'); model=$(printf '%s' "$report"|jq -r .target.ProductType); board=$(printf '%s' "$report"|jq -r .target.HardwareModel)
    while IFS= read -r row; do
        path=$(printf '%s' "$row"|jq -r .path); source=$(p5_relative "$bundle" "$path")
        originals=$(jq -n --argjson row "$row" --argjson report "$report" '[$row.original_inputs[] as $id|$report.input_receipts[$id].sha256//empty]')
        p5_root_add "${path#rootfs/}" "$source" "$(printf '%s' "$row"|jq -r .mode)" "$originals"
    done < <(printf '%s' "$report"|jq -c '.files[]|select(.path|startswith("rootfs/"))')
    if printf '%s' "$ids"|jq -e 'any(startswith("kernel-"))' >/dev/null; then
        cfg="$root/System/Library/CoreServices/SpringBoard.app/N42AP.plist"; [ -f "$cfg" ] || cfg="$root/System/Library/CoreServices/SpringBoard.app/N41AP.plist"
        p5_plist "$cfg"|jq -e '.capabilities and .iconState' >/dev/null || { p5_fail 'Unexpected source SpringBoard configuration'; return 2; }
        p5_root_add "System/Library/CoreServices/SpringBoard.app/$board.plist" "$cfg" 420 '[]'
    fi
    if [ "$jailbreak" = yes ] || printf '%s' "$ids"|jq -e 'any(startswith("kernel-"))' >/dev/null; then
        name=readonly; [ "$jailbreak" != yes ] || name=jailbreak
        p5_config fstab "$root/private/etc/fstab" "$name" "$P5_FS_DATA/fstab"; p5_root_add private/etc/fstab "$P5_FS_DATA/fstab"
    fi
    if printf '%s' "$ids"|jq -e 'index("media-cache")' >/dev/null; then
        printf '%s' "$ids"|jq -e 'index("camera-isp") and index("camera-setfile")' >/dev/null || { p5_fail 'H4ISP requires ISP and setfile'; return 2; }; media=camera-offline
    fi
    if printf '%s' "$ids"|jq -e 'index("virtual-audio")' >/dev/null; then
        if [ -n "$media" ]; then media=media-offline; else media=audio-offline; fi
    fi
    [ -z "$media" ] || p5_root_config mediaserverd "$media"
    if printf '%s' "$ids"|jq -e 'index("autolock-runtime")' >/dev/null; then p5_root_config SpringBoard autolock; fi
    if printf '%s' "$ids"|jq -e 'index("bluetooth")' >/dev/null; then p5_root_config BTServer bluetooth; p5_root_config BlueTool bluetooth; fi
    if printf '%s' "$ids"|jq -e 'index("gps-runtime")' >/dev/null; then
        printf '%s' "$ids"|jq -e 'index("locationd-heading")' >/dev/null || return 2; p5_root_config locationd gps
    fi
    name=$(printf '%s' "$board"|tr '[:upper:]' '[:lower:]'); name=${name:0:3}
    if printf '%s' "$ids"|jq -e 'index("commcenter-runtime") or index("commcenter-bridge")' >/dev/null; then
        printf '%s' "$ids"|jq -e 'index("commcenter-runtime") and index("commcenter-bridge")' >/dev/null || { p5_fail 'Select both CommCenter patches'; return 2; }
        [ -n "$bb$native" ] || { p5_fail 'CommCenter requires native or personalized modem resources'; return 2; }
        if [ -n "$bb" ]; then p5_validate_baseband "$bb"; p5_root_add usr/local/share/project5c/Mav7/Mav7personalized.zip "$bb" 420 '[]'; fi
        if [ -n "$native" ]; then
            native_report=$(p5_native_source "$native" "$model"); path=$(printf '%s' "$native_report"|jq -r .identity.Manifest.BasebandFirmware.Info.Path)
            p5_root_add "usr/local/share/project5c/Mav7/${path##*/}" "$native/Baseband.bbfw" 420 '[]'
        fi
        p5_root_config CommCenter "$name-baseband"
    else
        [ -z "$bb$native" ] || { p5_fail 'Modem resources require the baseband extra'; return 2; }; p5_root_config CommCenter "$name-native"
    fi
    cat "$P5_FS_PLAN"
}
