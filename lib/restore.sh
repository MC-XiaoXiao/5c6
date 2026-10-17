#!/usr/bin/env bash
source "$(dirname -- "${BASH_SOURCE[0]}")/rootfs.sh"
source "$P5_LIB/usb.sh"
source "$P5_LIB/jailbreak.sh"
source "$P5_LIB/kernel.sh"
source "$P5_LIB/modem.sh"
P5_BOOTARGS='rd=md0 -v nand-enable-reformat=1 amfi=0xff amfi_get_out_of_my_way=1 cs_enforcement_disable=1 pio-error=0'
P5_FLASH='{"FlashNOR":false,"UpdateBaseband":false,"FormatForLwVM":true,"CreateFilesystemPartitions":true,"SystemImage":true}'
p5_hfs_extract() {
    local bins=$1 image=$2 remote=$3 dest=$4
    mkdir -p "$(dirname -- "$dest")"
    p5_hfs_run 180 "$bins" "$image" extract "/${remote#/}" "$dest" || return $?
    [ -s "$dest" ] || { rm -f -- "$dest"; p5_fail "HFS extraction failed: $remote"; return 2; }
}
p5_hfs_add() {
    local bins=$1 image=$2 remote=${3#/} source=$4 mode=$5 part parent='' parts=()
    IFS=/ read -r -a parts <<< "$remote"
    for ((part=0;part<${#parts[@]}-1;part++)); do parent="${parent:+$parent/}${parts[$part]}"; p5_hfs_run 180 "$bins" "$image" mkdir "$parent" || return $?; done
    p5_hfs_run 180 "$bins" "$image" add "$source" "$remote" || return $?
    printf -v mode '%o' "$mode"; p5_hfs_run 180 "$bins" "$image" chmod "$mode" "$remote" || return $?
    p5_hfs_run 180 "$bins" "$image" chown 0:0 "$remote" || return $?
    p5_temp || return $?; p5_hfs_extract "$bins" "$image" "$remote" "$P5_TMP/hfs-readback" || return $?
    cmp -s "$source" "$P5_TMP/hfs-readback" || { p5_fail "HFS readback differs: $remote"; return 2; }
}
p5_check_components() {
    local kernel=$1 tree=$2 target=$3
    p5_temp; p5_unpack_kernel "$kernel" "$P5_TMP/check-kernel.macho" || return $?
    [ "$(p5_native hex-range "$P5_TMP/check-kernel.macho" 0 4)" = cefaedfe ] && LC_ALL=C grep -aFq 'Darwin Kernel Version 13.' "$P5_TMP/check-kernel.macho" || { p5_fail 'Expected an iOS 6 ARM kernel'; return 2; }
    p5_tree_identity "$tree" "$(p5_target "$target"|jq -r .ProductType)"
}
p5_reset_session() {
    local out=$1 retry=$2 components=$3 allowed path rel sources key source
    [ ! -L "$out" ] || { p5_fail 'Session output is a symlink'; return 2; }
    [ -e "$out" ] || return 0
    [ "$retry" = yes ] && [ -d "$out" ] && [ ! -e "$out/restore.json" ] || { p5_fail "Session exists: $out"; return 2; }
    for key in bundle rootfs-hfs ramdisk-hfs ramdisk-template ibec-raw baseband-firmware baseband-source wifi-firmware-dir; do
        source=$(p5_get "$key"); [ -n "$source" ] || continue
        case "$(p5_abs "$source")" in "$out"|"$out"/*) p5_fail 'Source is inside incomplete output'; return 2 ;; esac
    done
    allowed=$(printf '%s' "$components"|jq '[.[]]+["RootFS.hfs","RestoreRamDisk.hfs","Restore.plist","Restore.ipsw","restore.json.tmp","Firmware/Baseband/Mav7personalized.zip","Firmware/Baseband/personalization.json","Firmware/Baseband/Baseband.bbfw","Firmware/Baseband/BuildManifest.plist","Firmware/Baseband/identity.plist","Firmware/Baseband/source.json",(.devicetree|split("/")|.[0:-1]|join("/"))+"/manifest"]')
    while IFS= read -r -d '' path; do
        rel=${path#"$out/"}
        [ ! -L "$path" ] || { p5_fail "Unknown symlink retained: $path"; return 2; }
        if [ -d "$path" ]; then printf '%s' "$allowed"|jq -e --arg rel "$rel/" 'any(startswith($rel))' >/dev/null || return 2;
        else printf '%s' "$allowed"|jq -e --arg rel "$rel" 'index($rel)' >/dev/null || { p5_fail "Unknown file retained: $path"; return 2; }; fi
    done < <(find "$out" -mindepth 1 -print0)
    rm -rf -- "$out"
}
p5_restore_prepare() {
    p5_required bundle rootfs-hfs ramdisk-hfs ramdisk-template ibec-raw out
    local bins=$1 bundle out original_root original_ram template ibec report target model board short components wifi_dir bb native ecid native_report=null native_flow=null bb_receipt=null activation=null jailbreak=null version root temp system size ramdisk options restored asr layout dmg_report wifi='[]' wifi_hashes='{}' wifi_compat=null path row id key source rel sha mode all_flash bb_files='[]' receipts='{}' artifact_paths
    bundle=$(p5_abs "$(p5_get bundle)"); out=$(p5_abs "$(p5_get out)")
    original_root=$(p5_abs "$(p5_get rootfs-hfs)"); original_ram=$(p5_abs "$(p5_get ramdisk-hfs)"); template=$(p5_get ramdisk-template); ibec=$(p5_get ibec-raw)
    wifi_dir=$(p5_get wifi-firmware-dir); bb=$(p5_get baseband-firmware); native=$(p5_get baseband-source); ecid=$(p5_get baseband-ecid)
    p5_require_tools "$bins" hfsplus xpwntool iBoot32Patcher; source=$(p5_get dmg-tool "$bins/dmg"); [ -x "$source" ] || { p5_fail 'Missing DMG builder'; return 2; }
    report=$(p5_verify_bundle "$bundle"); target=$(printf '%s' "$report"|jq .target); model=$(printf '%s' "$target"|jq -r .ProductType); board=$(printf '%s' "$target"|jq -r '.HardwareModel|ascii_downcase'); short=${board:0:3}; components=$(p5_components "$model"); all_flash=$(printf '%s' "$components"|jq -r '.devicetree|split("/")|.[0:-1]|join("/")')
    printf '%s' "$report"|jq -e '.kernel_layout==7' >/dev/null || { p5_fail 'Rebuild bundle with the BMA library declaration required by the gyro dependency'; return 2; }
    printf '%s' "$report"|jq -e --arg policy "$(p5_get jailbreak yes)" '(.jailbreak_kernel.enabled//false)==($policy=="yes") and ($policy!="yes" or .jailbreak_kernel.revision==1)' >/dev/null || { p5_fail 'Rebuild bundle with matching --jailbreak policy (iOS 6 kernel patch revision 1)'; return 2; }
    if printf '%s' "$report"|jq -e '.files|any(.id=="kernel-wifi")' >/dev/null; then
        [ -n "$wifi_dir" ] || { p5_fail 'Candidate kernel requires matching Wi-Fi donor firmware'; return 2; }
        wifi=$(p5_wifi_files "$wifi_dir" "$model"|jq -s .); wifi_hashes=$(printf '%s' "$wifi"|jq 'map({key:.path,value:.sha256})|from_entries')
    else [ -z "$wifi_dir" ] || { p5_fail 'Wi-Fi firmware requires candidate kernel'; return 2; }; fi
    if printf '%s' "$report"|jq -e '.files|any(.id=="commcenter-runtime")' >/dev/null; then
        [ -n "$bb$native" ] || { p5_fail 'CommCenter requires modem resources'; return 2; }
        if [ -n "$native" ]; then [ -n "$ecid" ] || return 2; native_report=$(p5_native_source "$native" "$model" "$((ecid))"); fi
        if [ -n "$bb" ]; then
            p5_validate_baseband "$bb"
            if [ -f "$(dirname -- "$bb")/personalization.json" ]; then [ -n "$ecid" ] || return 2; bb_receipt=$(p5_baseband_receipt "$bb" "$model" "$ecid"); fi
        fi
    else [ -z "$bb$native" ] || { p5_fail 'Modem resources require CommCenter runtime'; return 2; }; fi
    size=$(($(p5_size "$original_root")+128*1048576)); ramdisk=$(($(p5_size "$original_ram")+8*1048576)); [ "$ramdisk" -ge 41943040 ] || ramdisk=41943040
    mkdir -p "$(dirname -- "$out")"
    local free; free=$(df -Pk "$(dirname -- "$out")"|awk 'NR==2{print $4}'); [ "$((free*1024))" -ge "$((3*size+3*ramdisk+256*1048576))" ] || { p5_fail 'Insufficient space for HFS, DMG and IPSW copies; choose --work on a larger disk'; return 2; }
    p5_reset_session "$out" "$(p5_get retry-incomplete no)" "$components"; mkdir "$out"
    p5_temp; temp="$P5_TMP/restore-prepare"; root="$temp/root"; mkdir -p "$root"
    p5_log 'Read original RootFS binaries and configuration'
    # Mandatory originals include every consumed source binary. New runtime paths are optional.
    printf '%s' "$report"|jq -r '.files[]|select(.path|startswith("rootfs/"))|.original_inputs[]|select(startswith("n41-") or startswith("n42-"))'|LC_ALL=C sort -u > "$temp/original-ids"
    while IFS= read -r id; do p5_input_path "$id"; done < "$temp/original-ids" > "$temp/required"
    printf '%s\n' System/Library/CoreServices/SystemVersion.plist System/Library/CoreServices/SpringBoard.app/SpringBoard private/etc/fstab >> "$temp/required"
    LC_ALL=C sort -u "$temp/required" > "$temp/required.sorted"
    while IFS= read -r path; do [ -n "$path" ] || continue; p5_hfs_extract "$bins" "$original_root" "$path" "$root/${path#/}"; done < "$temp/required.sorted"
    for name in mediaserverd SpringBoard locationd CommCenter BTServer BlueTool; do
        path="System/Library/LaunchDaemons/com.apple.$name.plist"; p5_hfs_extract "$bins" "$original_root" "$path" "$root/$path"
    done
    for name in N42AP.plist N41AP.plist; do path="System/Library/CoreServices/SpringBoard.app/$name"; p5_hfs_extract "$bins" "$original_root" "$path" "$root/$path" 2>/dev/null || :; done
    version=$(p5_plist "$root/System/Library/CoreServices/SystemVersion.plist")
    jq -ne --argjson version "$version" --argjson target "$target" '$version.ProductVersion==$target.ProductVersion and $version.ProductBuildVersion==$target.ProductBuildVersion' >/dev/null || { p5_fail 'RootFS version differs'; return 2; }
    case "$(p5_get activation hacktivate)" in
        hacktivate) p5_hfs_extract "$bins" "$original_root" usr/libexec/lockdownd "$temp/lockdownd.original"
            activation=$(p5_apply_fixed "$temp/lockdownd.original" "$(p5_spec activation "$model")" '' "$temp/lockdownd")
            activation=$(printf '%s' "$activation"|jq --arg version "$(printf '%s' "$version"|jq -r .ProductVersion)" '.+{version:$version,path:"usr/libexec/lockdownd"}') ;;
        none) ;; *) p5_fail 'Unknown activation policy'; return 2 ;;
    esac
    case "$(p5_get jailbreak yes)" in yes) jailbreak=$(p5_bootstrap "$temp/jailbreak.tar"|jq --argjson kernel "$(printf '%s' "$report"|jq .jailbreak_kernel)" '.+{kernel:$kernel}') ;; no) ;; *) return 2 ;; esac
    p5_rootfs_plan "$bundle" "$root" "$temp/configs" "$temp/plan.json" "$bb" "$native" "$(p5_get jailbreak yes)" > /dev/null
    p5_log 'Copy and grow RootFS HFS image'
    system="$out/RootFS.hfs"; layout=$(p5_native hfs-copy "$original_root" "$system"); size=$((( $(p5_size "$system")+128*1048576+4095)/4096*4096))
    p5_hfs_run 180 "$bins" "$system" grow "$size"
    local index=0 total; total=$(jq 'length' "$temp/plan.json")
    while IFS= read -r row; do
        index=$((index+1)); path=$(printf '%s' "$row"|jq -r .path)
        p5_log "RootFS [$index/$total] $path"
        p5_hfs_add "$bins" "$system" "$path" "$(printf '%s' "$row"|jq -r .source)" "$(printf '%s' "$row"|jq -r .mode)"
    done < <(jq -c '.[]' "$temp/plan.json")
    if [ "$jailbreak" != null ]; then
        p5_log 'Install jailbreak bootstrap and verify essential files'
        p5_hfs_run 600 "$bins" "$system" untar "$temp/jailbreak.tar"
        p5_hfs_add "$bins" "$system" usr/libexec/project5c-jailbreak-initialize "$P5_ROOT/resources/jailbreak/initialize.sh" 493
        p5_config jailbreak /dev/null bootstrap "$temp/jailbreak.plist"; p5_hfs_add "$bins" "$system" System/Library/LaunchDaemons/org.project5c.jailbreak.plist "$temp/jailbreak.plist" 420
        while IFS=$'\t' read -r rel sha; do p5_hfs_extract "$bins" "$system" "$rel" "$temp/jb-readback"; [ "$(p5_sha "$temp/jb-readback")" = "$sha" ] || return 2; done < <(printf '%s' "$jailbreak"|jq -r '.essential_sha256|to_entries[]|[.key,.value]|@tsv')
    fi
    p5_log 'Install activation policy, Wi-Fi firmware and boot components'
    [ "$activation" = null ] || p5_hfs_add "$bins" "$system" usr/libexec/lockdownd "$temp/lockdownd" 493
    while IFS=$'\t' read -r path source; do p5_hfs_add "$bins" "$system" "$path" "$source" 420; done < <(printf '%s' "$wifi"|jq -r '.[]|[.path,.source]|@tsv')
    for key in kernel devicetree ibss ibec; do
        case "$key" in kernel) source=kernelcache.img3 ;; devicetree) source=DeviceTree.img3 ;; ibss) source=iBSS.dfu ;; ibec) source=iBEC.dfu ;; esac
        path=$(printf '%s' "$components"|jq -r --arg key "$key" '.[$key]'); mkdir -p "$out/$(dirname -- "$path")"; cp -- "$bundle/boot/$source" "$out/$path"
    done
    p5_log 'Prepare restore iBEC and install RootFS kernel'
    LC_ALL=C grep -aFq 'iBoot-' "$ibec" && LC_ALL=C grep -aFq "iBEC for $board" "$ibec" || { p5_fail 'Restore iBEC donor model differs'; return 2; }
    local status=0
    p5_run_timeout 60 "$bins" iBoot32Patcher "$ibec" "$temp/restore-iBEC.bin" --rsa --debug -b "$P5_BOOTARGS" > "$temp/ibec.log" 2>&1 || status=$?
    [ "$status" -le 1 ] && grep -q 'main: Quitting' "$temp/ibec.log" && LC_ALL=C grep -aFq "$P5_BOOTARGS" "$temp/restore-iBEC.bin" || { p5_fail 'Restore iBEC patch failed'; return 2; }
    p5_patch_pmgr_boot iBEC "$temp/restore-iBEC.bin" "$temp/restore-iBEC.pmgr.bin" >/dev/null || return $?
    mv -- "$temp/restore-iBEC.pmgr.bin" "$temp/restore-iBEC.bin"
    path=$(printf '%s' "$components"|jq -r .ibec); p5_run_timeout 180 "$bins" xpwntool "$temp/restore-iBEC.bin" "$out/$path" -t "$bundle/boot/iBEC.dfu" >&2
    path=$(printf '%s' "$components"|jq -r .kernel); p5_hfs_add "$bins" "$system" System/Library/Caches/com.apple.kernelcaches/kernelcache "$out/$path" 420
    p5_log 'Build explicit-zero RootFS DMG'
    p5_run_timeout 1800 "$bins" "$(p5_get dmg-tool "$bins/dmg")" build "$system" "$out/RootFS.dmg" >&2; dmg_report=$(p5_native dmg-check "$out/RootFS.dmg")
    p5_log 'Prepare restore ramdisk: Wi-Fi, ASR, restored and options'
    ramdisk="$out/RestoreRamDisk.hfs"; p5_native hfs-copy "$original_ram" "$ramdisk" >/dev/null
    local ram_size; ram_size=$(($(p5_size "$ramdisk")+8*1048576)); [ "$ram_size" -ge 41943040 ] || ram_size=41943040; p5_hfs_run 180 "$bins" "$ramdisk" grow "$ram_size"
    while IFS=$'\t' read -r path source; do p5_hfs_add "$bins" "$ramdisk" "$path" "$source" 420; done < <(printf '%s' "$wifi"|jq -r '.[]|[.path,.source]|@tsv')
    p5_hfs_extract "$bins" "$ramdisk" usr/sbin/asr "$temp/asr.original"; asr=$(p5_patch_ramdisk_binary asr "$temp/asr.original" "$temp/asr"); p5_hfs_add "$bins" "$ramdisk" usr/sbin/asr "$temp/asr" 493
    p5_hfs_extract "$bins" "$ramdisk" usr/local/bin/restored_external "$temp/restored.original"
    LC_ALL=C grep -aFq FormatForLwVM "$temp/restored.original" || return 2
    if [ "$native_report" != null ]; then
        native_flow=$(p5_native_bb_ramdisk "$bins" "$ramdisk" "$temp/restored.original" "$temp/restored.compat") || return $?
        cp -- "$temp/restored.compat" "$temp/restored.original"
    fi
    restored=$(p5_patch_ramdisk_binary restored "$temp/restored.original" "$temp/restored"); p5_hfs_add "$bins" "$ramdisk" usr/local/bin/restored_external "$temp/restored" 493
    restored=$(printf '%s' "$restored"|jq --arg sha "$(p5_sha "$temp/restored")" '.+{sha256:$sha}')
    local partition; partition=$(((size+1048575)/1048576+256)); [ "$partition" -ge 2048 ] || partition=2048
    options=$(printf '%s' "$P5_FLASH"|jq --argjson partition "$partition" '.+{SystemPartitionSize:$partition}'); printf '%s' "$options"|p5_write_plist "$temp/options.plist"
    if [ "$native_flow" != null ]; then
        options=$(printf '%s' "$options"|p5_native_bb_restore_options)
        printf '%s' "$options"|p5_write_plist "$temp/options.plist"
    fi
    for name in options.plist "options.$short.plist"; do p5_hfs_add "$bins" "$ramdisk" "usr/local/share/restore/$name" "$temp/options.plist" 420; done
    p5_native img3-wrap "$template" "$ramdisk" "$out/RestoreRamDisk.dmg" plaintext; p5_native ramdisk-check "$out/RestoreRamDisk.dmg" >/dev/null
    jq -n --arg model "$model" --arg board "$board" --arg short "$short" --argjson target "$(p5_target "$model")" --argjson version "$version" --argjson components "$components" --argjson partition "$partition" --argjson native "$native_report" '{DeviceClass:"iPhone",DeviceMap:[{BDID:$target.board_id,CPID:35152,BoardConfig:$board,Platform:"s5l8950x",SCEP:16}],FirmwareDirectory:"Firmware",ProductType:$model,SupportedProductTypes:[$model],ProductVersion:$version.ProductVersion,ProductBuildVersion:$version.ProductBuildVersion,KernelCachesByTarget:{($short):{Release:$components.kernel}},RestoreRamDisks:{User:$components.ramdisk},SystemRestoreImages:{User:$components.rootfs},MinimumSystemPartition:{($components.rootfs):$partition}}|if $native!=null then .Project5CBasebandIdentity=($native.identity|.Manifest.BasebandFirmware.Info.Path="Firmware/Baseband/Baseband.bbfw") else . end'|p5_write_plist "$out/Restore.plist"
    printf 'DeviceTree.%s.img3\n' "$board" > "$out/$all_flash/manifest"
    if [ -n "$bb$native" ]; then
        mkdir -p "$out/Firmware/Baseband"
        if [ -n "$bb" ]; then cp -- "$bb" "$out/Firmware/Baseband/Mav7personalized.zip"; bb_files=$(printf '%s' "$bb_files"|jq '.+["Firmware/Baseband/Mav7personalized.zip"]'); fi
        if [ "$native_report" != null ]; then for name in Baseband.bbfw BuildManifest.plist identity.plist source.json; do cp -- "$native/$name" "$out/Firmware/Baseband/$name"; bb_files=$(printf '%s' "$bb_files"|jq --arg name "Firmware/Baseband/$name" '.+[$name]'); done; fi
        if [ "$bb_receipt" != null ]; then printf '%s\n' "$bb_receipt" > "$out/Firmware/Baseband/personalization.json"; bb_files=$(printf '%s' "$bb_files"|jq '.+["Firmware/Baseband/personalization.json"]'); fi
    fi
    artifact_paths=$(jq -n --argjson components "$components" --argjson bb "$bb_files" --arg manifest "$all_flash/manifest" '["Restore.plist",$manifest]+[$components[]]+$bb')
    local zip_args=(); while IFS= read -r path; do zip_args+=("$path"); done < <(printf '%s' "$artifact_paths"|jq -r '.[]')
    p5_log 'Package Restore.ipsw'
    (cd -- "$out"; zip -q -0 -X Restore.ipsw ${zip_args[@]+"${zip_args[@]}"})
    p5_log 'Record generated restore artifact checksums'
    while IFS= read -r path; do receipts=$(printf '%s' "$receipts"|jq --arg path "$path" --arg sha "$(p5_sha "$out/$path")" '.[$path]=$sha'); done < <(printf '%s' "$artifact_paths"|jq -r '.[],"Restore.ipsw"')
    jq -n --argjson activation "$activation" --argjson jailbreak "$jailbreak" --arg target "$(printf '%s' "$target"|jq -r .HardwareModel)" --argjson version "$version" --slurpfile plan "$temp/plan.json" --argjson layout "$layout" --argjson report "$report" --argjson asr "$asr" --argjson native_flow "$native_flow" --argjson restored "$restored" --argjson wifi "$wifi" --argjson hashes "$wifi_hashes" --argjson compat "$wifi_compat" --arg bb_sha "${bb:+$(p5_sha "$bb")}" --argjson native "$native_report" --arg ecid "$ecid" --arg native_sha "${native:+$(p5_sha "$native/source.json")}" --argjson bb_files "$bb_files" --argjson bb_receipt "$bb_receipt" --argjson dmg "$dmg_report" --argjson options "$options" --arg bootargs "$P5_BOOTARGS" --argjson components "$components" --argjson receipts "$receipts" '{schema:1,kernel_layout:$report.kernel_layout,pmgr:$report.pmgr,experimental:true,physical_restore_verified:false,activation:$activation,jailbreak:$jailbreak,target:$target,source_version:$version,rootfs_patch_files:[$plan[0][].path],source_hfs_layout:$layout,selected_artifacts:[$report.files[].id],asr:$asr,restored:$restored,wifi_firmware_files:[$wifi[].path],wifi_firmware_sha256:$hashes,wifi_ramdisk_firmware_sha256:$hashes,wifi_compatibility:$compat,baseband_firmware_sha256:(if $bb_sha=="" then null else $bb_sha end),baseband_ecid:(if $ecid=="" then null else ($ecid|if startswith("0x") then error("ECID must be normalized") else tonumber end) end),baseband_native:($native!=null),baseband_native_flow:$native_flow,baseband_source_sha256:(if $native_sha=="" then null else $native_sha end),baseband_version:$native.spec.version,baseband_files:$bb_files,baseband_personalization:$bb_receipt,bluetooth_launch_environment:(if $report.files|any(.id=="bluetooth") then {DYLD_INSERT_LIBRARIES:"",_MSSafeMode:"1"} else null end),system_dmg:$dmg,restore_options:$options,boot_args:$bootargs,components:$components,rootfs_contains_patched_kernel:true,nand_writes:false,integrity_receipts:$receipts}' > "$out/restore.json.tmp"
    mv -- "$out/restore.json.tmp" "$out/restore.json"; cat "$out/restore.json"
}
p5_restore_session() {
    local dir=$1 report target components name sha path native expected actual
    if [ "${P5_VERIFIED_SESSION:-}" = "$dir" ]; then cat "$dir/restore.json"; return; fi
    [ ! -e "$dir/.project5c-incomplete" ] || { p5_fail 'Restore session build did not finish'; return 2; }
    report=$(cat "$dir/restore.json") || return $?; target=$(printf '%s' "$report"|jq -r .target) || return $?; components=$(p5_components "$target") || return $?
    printf '%s' "$report"|jq -e '.pmgr=={revision:1,period_cell_bytes:4,boost_frequency_hz:1296000000}' >/dev/null || { p5_fail 'Rebuild restore session with PMGR handoff ABI revision 1'; return 2; }
    printf '%s' "$report"|jq -e --arg bootargs "$P5_BOOTARGS" --argjson components "$components" --argjson flash "$P5_FLASH" --argjson expected_flash "$(if printf '%s' "$report"|jq -e '.baseband_native_flow!=null' >/dev/null; then printf '%s' "$P5_FLASH"|p5_native_bb_restore_options; else printf '%s' "$P5_FLASH"; fi)" 'has("restored") and .boot_args==$bootargs and (.components==$components or .components==null) and (.restore_options|del(.SystemPartitionSize))==$expected_flash and (.restore_options.SystemPartitionSize>=2048) and (.baseband_files//[]|all(.=="Firmware/Baseband/Mav7personalized.zip" or .=="Firmware/Baseband/personalization.json" or .=="Firmware/Baseband/Baseband.bbfw" or .=="Firmware/Baseband/BuildManifest.plist" or .=="Firmware/Baseband/identity.plist" or .=="Firmware/Baseband/source.json"))' >/dev/null || { p5_fail 'Restore session layout/options differ'; return 2; }
    while IFS= read -r path; do
        name=$(p5_relative "$dir" "$path") || return $?; sha=$(printf '%s' "$report"|jq -er --arg path "$path" '.integrity_receipts[$path]') || return $?
        [ -f "$name" ] && [ "$(p5_sha "$name")" = "$sha" ] || { p5_fail "Generated restore component changed: $path"; return 2; }
    done < <(jq -n --argjson report "$report" --argjson components "$components" '[$components[]]+($report.baseband_files//[])+["Restore.ipsw"]|.[]' -r)
    p5_native ramdisk-check "$dir/RestoreRamDisk.dmg" >/dev/null || return $?
    if printf '%s' "$report"|jq -e '.baseband_files|index("Firmware/Baseband/Mav7personalized.zip")' >/dev/null; then
        p5_validate_baseband "$dir/Firmware/Baseband/Mav7personalized.zip" || return $?; [ "$(p5_sha "$dir/Firmware/Baseband/Mav7personalized.zip")" = "$(printf '%s' "$report"|jq -r .baseband_firmware_sha256)" ] || return 2
    fi
    if printf '%s' "$report"|jq -e .baseband_native >/dev/null; then
        native=$(p5_native_source "$dir/Firmware/Baseband" "$(p5_target "$target"|jq -r .ProductType)" "$(printf '%s' "$report"|jq -r .baseband_ecid)") || return $?
        [ "$(p5_sha "$dir/Firmware/Baseband/source.json")" = "$(printf '%s' "$report"|jq -r .baseband_source_sha256)" ] || return 2
        expected=$(printf '%s' "$native"|jq '.identity|.Manifest.BasebandFirmware.Info.Path="Firmware/Baseband/Baseband.bbfw"') || return $?; actual=$(p5_plist "$dir/Restore.plist"|jq .Project5CBasebandIdentity) || return $?
        jq -ne --argjson expected "$expected" --argjson actual "$actual" '$expected==$actual' >/dev/null || { p5_fail 'Native baseband restore identity changed'; return 2; }
        if printf '%s' "$report"|jq -e '.baseband_native_flow!=null' >/dev/null; then
            p5_native_bb_verify "$dir" "$report" "$(p5_get tools-dir "$P5_TOOLS")" || return $?
        fi
    fi
    local kernel tree; kernel=$(printf '%s' "$components"|jq -r .kernel); tree=$(printf '%s' "$components"|jq -r .devicetree)
    p5_check_components "$dir/$kernel" "$dir/$tree" "$target" || return $?
    if printf '%s' "$report"|jq -e '.selected_artifacts|index("kernel-wifi")' >/dev/null; then
        printf '%s' "$report"|jq -e '(.wifi_firmware_sha256|length)==4 and .wifi_ramdisk_firmware_sha256==.wifi_firmware_sha256 and (.wifi_firmware_files|sort)==(.wifi_firmware_sha256|keys|sort)' >/dev/null || return 2
    fi
    printf '%s\n' "$report"
}
p5_restore_boot() {
    local dir=$1 bins=$2 ecid=$3 execute=$4 report target components commands key cmd fields
    report=$(p5_restore_session "$dir") || return $?; target=$(printf '%s' "$report"|jq -r .target); components=$(p5_components "$target")
    commands=$(jq -n --arg dir "$dir" --arg bins "$bins" --arg bootargs "$P5_BOOTARGS" --argjson c "$components" '[[($bins+"/irecovery"),"-f",($dir+"/"+$c.ibec)],[($bins+"/irecovery"),"-c",("setenv boot-args "+$bootargs)],[($bins+"/irecovery"),"-f",($dir+"/"+$c.ramdisk)],[($bins+"/irecovery"),"-c","ramdisk"],[($bins+"/irecovery"),"-f",($dir+"/"+$c.devicetree)],[($bins+"/irecovery"),"-c","devicetree"],[($bins+"/irecovery"),"-f",($dir+"/"+$c.kernel)],[($bins+"/irecovery"),"-c","bootx"]]')
    if [ "$execute" = yes ]; then
        p5_prepare_ibss "$bins" "$ecid" "$target" "$dir/$(printf '%s' "$components"|jq -r .ibss)" || return $?
        while IFS= read -r row; do
            local args=(); while IFS= read -r key; do args+=("$key"); done < <(printf '%s' "$row"|jq -r '.[1:][]')
            p5_run_timeout 60 "$bins" irecovery ${args[@]+"${args[@]}"} >&2 || return $?; sleep 2 || return $?
            if [ "${args[0]}" = -f ] && [ "${args[1]}" = "$dir/$(printf '%s' "$components"|jq -r .ibec)" ]; then fields=$(p5_recovery_fields "$bins") || return $?; p5_check_recovery "$fields" "$ecid" "$target" || return $?; fi
        done < <(printf '%s' "$commands"|jq -c '.[]')
    else printf '%s' "$commands"|jq -r '.[]|@sh' >&2; fi
    jq -n --arg execute "$execute" --arg bins "$bins" --argjson commands "$commands" '{preview:($execute!="yes"),nand_writes:false,tools_directory:$bins,commands:$commands}'
}
p5_restore_host_check() {
    local host=$1 native=${2:-false} version
    [ -x "$host" ] || { p5_fail 'Restore host is missing'; return 2; }
    version=$(p5_run_timeout 15 "$(dirname -- "$host")" "$host" --version) || return $?
    if [ "$native" = true ]; then
        [[ "$version" = *native6-5c-bb-native-v2* ]] || { p5_fail 'Rebuild the native BasebandData host with nonce-bound ticket caching (v2)'; return 2; }
    else
        [[ "$version" = *native6-5c-no-baseband* || "$version" = *native6-5c-bb-native-v[12]* ]] || { p5_fail 'Use a Project5C patched restore host'; return 2; }
    fi
}
p5_restore_archive() {
    local dir=$1 name previous=no history="$1/restore-history" archive
    # Preserve both complete and interrupted attempts before reusing a session.
    for name in restore.log restore-debug.log result.json; do
        [ ! -L "$dir/$name" ] || { p5_fail "Restore output is a symlink: $dir/$name"; return 2; }
        [ -e "$dir/$name" ] || continue
        [ -f "$dir/$name" ] || { p5_fail "Restore output is not a regular file: $dir/$name"; return 2; }
        previous=yes
    done
    [ "$previous" = yes ] || return 0
    [ ! -L "$history" ] && { [ ! -e "$history" ] || [ -d "$history" ]; } || { p5_fail "Invalid restore history directory: $history"; return 2; }
    mkdir -p "$history" || { p5_fail "Cannot create restore history: $history"; return 2; }
    archive=$(mktemp -d "$history/attempt-$(date -u '+%Y%m%dT%H%M%SZ').XXXXXX") || { p5_fail "Cannot create restore archive in $history"; return 2; }
    for name in restore.log restore-debug.log result.json; do
        [ ! -e "$dir/$name" ] || mv -- "$dir/$name" "$archive/$name" || { p5_fail "Cannot archive $dir/$name in $archive"; return 2; }
    done
    p5_log "Previous restore output preserved in $archive"
}
p5_restore_ecid() {
    printf '%s' "$1"|jq -e --argjson ecid "$(($2))" '.baseband_ecid==null or .baseband_ecid==$ecid' >/dev/null || { p5_fail 'Modem resource ECID differs'; return 2; }
}
p5_restore_flash() {
    local dir=$1 ecid=$2 execute=$3 erase=$4 host=$5 report target command probe code finished=false native=false bb_done=false evidence=''
    report=$(p5_restore_session "$dir") || return $?; target=$(printf '%s' "$report"|jq -r .target)
    printf '%s' "$report"|jq -e '.diagnostic_only!=true' >/dev/null || { p5_fail 'Diagnostic session cannot start an OS restore'; return 2; }
    p5_restore_ecid "$report" "$ecid" || return $?
    native=$(printf '%s' "$report"|jq '.baseband_native==true')
    if [ "$native" = true ]; then p5_native_bb_verify "$dir" "$report" "$(p5_get tools-dir "$P5_TOOLS")" yes || return $?; fi
    local hex; printf -v hex '0x%x' "$((ecid))"
    command=$(jq -n --arg host "$host" --arg hex "$hex" --arg dir "$dir" '[$host,"-c","-e","-R","-x","-y","-i",$hex,"--cache-path",($dir+"/cache"),($dir+"/Restore.ipsw")]')
    if [ "$native" = true ]; then command=$(printf '%s' "$command"|jq '.[0:-1]+["--project5c-baseband",.[-1]]'); fi
    if [ "$(p5_get restore-debug no)" = yes ]; then command=$(printf '%s' "$command"|jq --arg log "$dir/restore-debug.log" '.[0:-1]+["-d",("--logfile="+$log),.[-1]]'); fi
    if [ "$execute" != yes ]; then
        printf '%s' "$command"|jq -r '@sh' >&2
        jq -n --argjson command "$command" --argjson native "$native" '{preview:true,erases_system_and_data:true,preserve_nor:true,update_baseband:$native,ramdisk_count:1,baseband_flow:(if $native then "idevicerestore-BasebandData" else null end),command:$command}'; return
    fi
    [ "$erase" = yes ] || { p5_fail 'Actual restore requires --execute --erase'; return 2; }
    p5_restore_host_check "$host" "$native" || return $?; p5_native dmg-check "$dir/RootFS.dmg" >/dev/null || return $?; probe=$(p5_native restored-probe "$((ecid))" "$target") || return $?
    p5_restore_archive "$dir" || return $?
    if [ "$native" = true ]; then evidence=$(mktemp -d "$dir/baseband-attempt-XXXXXX") || return $?; fi
    local args=(); while IFS= read -r value; do args+=("$value"); done < <(printf '%s' "$command"|jq -r '.[1:][]')
    set +e
    (unset PROJECT5C_BB_SAVE; [ "$native" != true ] || export PROJECT5C_BB_SAVE="$evidence/native"; p5_tool_env "$(dirname -- "$host")"; if command -v stdbuf >/dev/null; then stdbuf -oL -eL "$host" ${args[@]+"${args[@]}"}; else "$host" ${args[@]+"${args[@]}"}; fi) 2>&1 | tee "$dir/restore.log" >&2
    code=${PIPESTATUS[0]}; set -e
    if [ "$code" = 0 ] && grep -q 'Status: Restore Finished' "$dir/restore.log" && ! grep -q 'Not sending NORData' "$dir/restore.log"; then finished=true; fi
    if [ "$native" = true ] && [ "$finished" = true ] && grep -q 'Updating Baseband completed' "$dir/restore.log"; then bb_done=true; fi
    jq -n --argjson code "$code" --argjson finished "$finished" --argjson probe "$probe" --argjson native "$native" --argjson bb_done "$bb_done" --arg evidence "$evidence" '{returncode:$code,restore_finished:$finished,device_probe:$probe,physical_restore_verified:$finished,normal_boot_verified:false,activation_verified:false,tethered_boot_required:true,baseband_update_requested:$native,physical_baseband_update_verified:$bb_done,evidence_directory:$evidence}' > "$dir/result.json"
    [ "$native" != true ] || [ "$bb_done" = true ] || { p5_fail 'Native baseband did not complete; inspect restore.log and evidence'; return 2; }
    [ "$finished" = true ] || { p5_fail 'Restore did not report final success; inspect restore.log and result.json'; return 2; }
    cat "$dir/result.json"
}
p5_restore_install() {
    local dir=$1 bins=$2 ecid=$3 execute=$4 erase=$5 host=$6 seconds=$7 boot flash report target start now
    [ "$seconds" -ge 1 ] && [ "$seconds" -le 300 ] || return 2
    if [ "$execute" != yes ]; then
        p5_restore_session "$dir" >/dev/null || return $?
        P5_VERIFIED_SESSION=$dir
        boot=$(p5_restore_boot "$dir" "$bins" "$ecid" no) || return $?; flash=$(p5_restore_flash "$dir" "$ecid" no "$erase" "$host") || return $?
        jq -n --argjson boot "$boot" --argjson flash "$flash" '{preview:true,erases_system_and_data:true,boot:$boot,flash:$flash,after_restore:"Enter physical DFU, then run tool.sh boot with the matching workspace."}'; return
    fi
    [ "$erase" = yes ] || { p5_fail '--execute --erase is required before USB operations'; return 2; }
    report=$(p5_restore_session "$dir") || return $?; target=$(printf '%s' "$report"|jq -r .target)
    P5_VERIFIED_SESSION=$dir
    p5_restore_ecid "$report" "$ecid" || return $?
    p5_require_boot "$bins" || return $?; p5_restore_host_check "$host" "$(printf '%s' "$report"|jq '.baseband_native==true')" || return $?; p5_native dmg-check "$dir/RootFS.dmg" >/dev/null || return $?
    if printf '%s' "$report"|jq -e '.baseband_native==true' >/dev/null; then p5_native_bb_verify "$dir" "$report" "$bins" yes || return $?; fi
    p5_restore_archive "$dir" || return $?
    p5_restore_boot "$dir" "$bins" "$ecid" yes >/dev/null || return $?
    start=$(date +%s); p5_log "Wait for matching restored (maximum $seconds seconds)"
    while ! p5_native restored-probe "$((ecid))" "$target" >/dev/null 2>&1; do now=$(date +%s); [ "$((now-start))" -lt "$seconds" ] || { p5_fail 'Restore environment did not become ready; no flash started'; return 2; }; sleep 1; done
    p5_restore_flash "$dir" "$ecid" yes yes "$host"|jq '.+{after_restore:"Enter physical DFU, then run tool.sh boot with the matching workspace."}'
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail; COMMAND=${1:-help}; [ "$#" -eq 0 ] || shift; p5_args "$@"
    BINS=$(p5_get tools-dir "$P5_TOOLS"); if [ -n "$(p5_get kit)" ]; then BINS="$(p5_get kit)/bin/linux/$P5_ARCH"; fi
    BINS=$(p5_abs "$BINS")
    SESSION=$(p5_get session); [ -z "$SESSION" ] || SESSION=$(p5_abs "$SESSION")
    ECID=$(p5_get ecid 0); EXECUTE=$(p5_get execute no); ERASE=$(p5_get erase no); HOST=$(p5_get idevicerestore); [ -z "$HOST" ] || HOST=$(p5_abs "$HOST")
    if [ "$COMMAND" = prepare ] && [ -n "$(p5_get out)" ]; then p5_output_temp "$(p5_get out)"; else p5_temp; fi
    RESULT="$P5_TMP/result.json"
    case "$COMMAND" in help|--help) printf 'Usage: restore.sh prepare|verify|boot|flash|install [options]\n'; exit 0 ;; esac
    if [ "$EXECUTE" = yes ]; then [ "$((ECID))" -gt 0 ] || exit 2; p5_device_lock "$(p5_get lock "$HOME/.cache/project5c-native6-device.lock")"; fi
    case "$COMMAND" in
        prepare) if [ -n "$(p5_get baseband-ecid)" ]; then P5_ARG_baseband_ecid=$((P5_ARG_baseband_ecid)); fi; p5_restore_prepare "$BINS" > "$RESULT" ;;
        verify) p5_required session; REPORT=$(p5_restore_session "$SESSION"); jq -n --arg target "$(printf '%s' "$REPORT"|jq -r .target)" '{passed:true,target:$target,device_accessed:false}' > "$RESULT" ;;
        probe) p5_required ecid; p5_native restored-probe "$((ECID))" "$(p5_target "$(p5_get target iPhone5,4)"|jq -r .HardwareModel)" > "$RESULT" ;;
        boot) p5_required session ecid; p5_restore_boot "$SESSION" "$BINS" "$ECID" "$EXECUTE" > "$RESULT" ;;
        flash) p5_required session ecid idevicerestore; p5_restore_flash "$SESSION" "$ECID" "$EXECUTE" "$ERASE" "$HOST" > "$RESULT" ;;
        install) p5_required session ecid idevicerestore; p5_restore_install "$SESSION" "$BINS" "$ECID" "$EXECUTE" "$ERASE" "$HOST" "$(p5_get wait-seconds 90)" > "$RESULT" ;;
        *) p5_fail 'Unknown restore operation'; exit 2 ;;
    esac
    p5_finish "$RESULT" "$COMMAND complete"
fi
