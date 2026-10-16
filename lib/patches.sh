#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/firmware.sh"
source "$P5_LIB/kernel.sh"
# Recipes contain only installation policy. Exact binary inputs live in files.tsv.
p5_profile() {
    case "$1" in base|native6-validated) printf 'base\n' ;; wifi|native6-wifi-candidate) printf 'wifi\n' ;; *) p5_fail "Unknown profile: $1"; return 2 ;; esac
}
p5_spec() {
    local id=$1 model=$2 kind=bsdiff input='' destination='' mode=420 payload='' core='' template='' header='' flags='[]' board
    board=$(p5_target "$model"|jq -r '.HardwareModel|ascii_downcase|.[0:3]') || return $?
    case "$id" in
        kernel-validated) id=kernel-base ;; kernel-wifi-candidate) id=kernel-wifi ;;
        kernel-img3-validated) id=kernel-img3-base ;; kernel-img3-wifi-candidate) id=kernel-img3-wifi ;;
    esac
    case "$id" in
        kernel-base|kernel-wifi) kind=kernel; input=n42-kernel.macho; destination=boot/kernelcache.macho ;;
        kernel-img3-base|kernel-img3-wifi)
            kind=container; core=${id/kernel-img3/kernel}; destination=boot/kernelcache.img3
            template=img3/kernel.img3; header=img3/kernel.lzss ;;
        devicetree) input=n42-devicetree.dtb; destination=boot/DeviceTree.dtb ;;
        devicetree-img3) kind=container; core=devicetree; destination=boot/DeviceTree.img3; template=img3/devicetree.img3 ;;
        ibss|ibec)
            if [ "$id" = ibss ]; then destination=boot/iBSS.dfu; input=n49-ibss.bin
            else destination=boot/iBEC.dfu; input=n49-ibec.bin; fi
            if [ "$board" = n48 ]; then
                kind=boot-feature; input="${destination#boot/}"; input="${input%.dfu}.n48.dfu"
                flags='["--rsa"]'
                if [ "$id" = ibec ]; then flags='["--rsa","--debug","--ticket","-b","rd=disk0s1s1 -v debug=0x2014e wdt=-1 pio-error=0 amfi=0xff cs_enforcement_disable=1"]'; fi
            fi ;;
        touch-firmware)
            kind=copy; input=n49-mtprops; [ "$board" != n48 ] || input=N48.mtprops
            destination="rootfs/usr/share/firmware/multitouch/$(printf '%s' "$board"|tr '[:lower:]' '[:upper:]').mtprops" ;;
        sensors-cache) input=n42-cache; destination=rootfs/System/Library/Caches/com.apple.dyld/dyld_shared_cache_armv7s ;;
        media-cache) kind=media-h4isp; core=sensors-cache; destination=rootfs/System/Library/Caches/com.apple.dyld/dyld_shared_cache_armv7s ;;
        virtual-audio) kind=media-audio; input=n42-virtualaudio; destination=rootfs/Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin/VirtualAudio; mode=493 ;;
        locationd-heading) input=n42-locationd; destination=rootfs/usr/libexec/locationd; mode=493 ;;
        bluetooth) input=n42-bluetool; destination=rootfs/usr/sbin/BlueTool; mode=493 ;;
        camera-isp) input=n49-isp.bin; destination=rootfs/usr/local/share/firmware/isp/h4_isp_fw.bin ;;
        camera-setfile) kind=copy; input=n49-setfile.dat; destination=rootfs/usr/local/share/firmware/isp/7652_01XX.dat ;;
        autolock-runtime) kind=payload; payload=sleep.dylib; destination=rootfs/usr/local/lib/native6-autolock.dylib; mode=493 ;;
        commcenter-runtime) input=n42-commcenter; destination="rootfs/usr/local/libexec/project5c/CommCenter.$board-runtime"; mode=493 ;;
        commcenter-bridge) kind=payload; payload="modem-$board.dylib"; destination=rootfs/usr/local/lib/project5c-commcenter-hsic.dylib; mode=493 ;;
        gps-runtime)
            [ "$board" = n49 ] || { p5_fail 'GPS requires N49'; return 2; }
            kind=payload; payload=gps.dylib; destination=rootfs/usr/local/lib/project5c-locationd-gps.dylib; mode=493 ;;
        activation) ;;
        *) p5_fail "Unknown patch: $id"; return 2 ;;
    esac
    jq -nc --arg id "$id" --arg model "$model" --arg kind "$kind" --arg input "$input" --arg destination "$destination" --argjson mode "$mode" --arg payload "$payload" --arg core "$core" --arg template "$template" --arg header "$header" --argjson flags "$flags" \
      '{id:$id,model:$model,kind:$kind,mode:$mode,flags:$flags}|if $input!="" then .input=$input else . end|if $destination!="" then .destination=$destination else . end|if $payload!="" then .payload=$payload else . end|if $core!="" then .core=$core else . end|if $template!="" then .template_file=$template else . end|if $header!="" then .compression_header_file=$header else . end'
}
p5_select() {
    local profile extras=$2 only=$3 model=$4 ids id selected=()
    profile=$(p5_profile "$1") || return $?
    p5_target "$model" >/dev/null || return $?
    if [ -n "$only" ]; then IFS=, read -r -a selected <<< "$only"
    else
        selected=("kernel-$profile" "kernel-img3-$profile" touch-firmware devicetree devicetree-img3 ibss ibec media-cache locationd-heading bluetooth camera-isp camera-setfile virtual-audio autolock-runtime)
        case ",$extras," in *,gps,*) selected+=(gps-runtime) ;; esac
        case ",$extras," in *,baseband,*) selected+=(commcenter-runtime commcenter-bridge) ;; esac
    fi
    for id in "${selected[@]}"; do p5_spec "$id" "$model" >/dev/null || return $?; done
    ids=$(printf '%s\n' "${selected[@]}" | jq -Rsc 'split("\n")|map(select(length>0))|reduce .[] as $id ([];if index($id) then . else .+[$id] end)')
    printf '%s' "$ids"|jq -e 'if index("media-cache") then index("camera-isp") and index("camera-setfile") and (index("sensors-cache")|not) else true end' >/dev/null || { p5_fail 'media-cache requires camera-isp and camera-setfile; select it instead of sensors-cache'; return 2; }
    printf '%s\n' "$ids"
}
p5_input_path() {
    case "$1" in
        n4[12]-cache) printf '/System/Library/Caches/com.apple.dyld/dyld_shared_cache_armv7s\n' ;;
        n4[12]-virtualaudio) printf '/Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin/VirtualAudio\n' ;;
        n4[12]-locationd) printf '/usr/libexec/locationd\n' ;;
        n4[12]-commcenter) printf '/System/Library/Frameworks/CoreTelephony.framework/Support/CommCenter\n' ;;
        n4[12]-bluetool) printf '/usr/sbin/BlueTool\n' ;;
    esac
}
p5_apply_fixed() {
    local input=$1 info=$2 profile=$3 output=$4 row patch sha size id model
    id=$(printf '%s' "$info"|jq -r .id); model=$(printf '%s' "$info"|jq -r .model)
    sha=$(p5_sha "$input") || return $?; size=$(p5_size "$input") || return $?
    row=$(awk -F '\t' -v id="$id" -v model="$model" -v profile="$profile" -v sha="$sha" -v size="$size" \
      '$1==id && ($2=="*" || $2==model) && ($3=="*" || $3==profile) && $4==size && $5==sha {print; n++} END {if(n!=1)exit 2}' "$P5_ROOT/patches/files.tsv") || { p5_fail "Unsupported original for $id ($model/$profile)"; return 2; }
    local input_size input_sha patch_path output_size output_sha
    IFS=$'\t' read -r id model profile input_size input_sha patch_path output_size output_sha <<< "$row"
    patch=$(p5_relative "$P5_ROOT/patches" "$patch_path") || return $?
    p5_native apply "$input" "$patch" "$output" || return $?
    p5_check_file "$output" "$output_size" "$output_sha" || return $?
    jq -nc --arg patch "$patch_path" --arg source "$sha" --arg output "$output_sha" '{format:"BSDIFF40",patch:$patch,source_sha256:$source,output_sha256:$output}'
}
p5_source_identity() {
    local inputs=$1 prefix= tree= count=0 model board version props
    for prefix in n41 n42; do if [ -f "$inputs/$prefix-devicetree.dtb" ]; then tree="$inputs/$prefix-devicetree.dtb"; count=$((count+1)); fi; done
    if [ "$count" -eq 0 ]; then printf 'null\n'; return; fi
    [ "$count" -eq 1 ] || { p5_fail 'Mixed source DeviceTrees'; return 2; }
    prefix=${tree##*/}; prefix=${prefix:0:3}
    props=$(p5_native tree-json "$tree" | jq '.properties|map({key:.name,value:.value})|from_entries')
    case "$(printf '%s' "$props"|jq -r .model)" in 6950686f6e65352c3100) model=iPhone5,1; board=n41ap ;; 6950686f6e65352c3200) model=iPhone5,2; board=n42ap ;; *) p5_fail 'Unsupported source DeviceTree'; return 2 ;; esac
    [ "$prefix" != n41 ] || [ "$board" = n41ap ] || return 2
    local bh; bh=$(printf '%s\0' "$(printf '%s' "$board"|tr '[:lower:]' '[:upper:]')"|od -An -v -tx1|tr -d '[:space:]')
    printf '%s' "$props"|jq -e --arg board "$bh" '.compatible|contains($board)' >/dev/null || return 2
    version=$(p5_plist "$inputs/SystemVersion.plist")
    printf '%s\n' "$version" | jq -e '(.ProductVersion=="6.1.3" and .ProductBuildVersion=="10B329") or (.ProductVersion=="6.1.4" and .ProductBuildVersion=="10B350")' >/dev/null || return 2
    printf '%s\n' "$version" | jq --arg board "$board" --arg product "$model" --arg prefix "$prefix" '{board:$board,product:$product,version:.ProductVersion,build:.ProductBuildVersion,input_prefix:$prefix}'
}
p5_build_input() {
    local name=$1 ident=$2 source
    if [[ "$name" = n42-* ]] && [ "$P5_SOURCE" != null ]; then name="$(printf '%s' "$P5_SOURCE"|jq -r .input_prefix)${name:3}"; fi
    source=$(p5_relative "$P5_INPUTS" "$name")
    if [[ "$name" != n41-* && "$name" != n42-* ]] && [ -n "$P5_DONOR" ] && [ -f "$P5_DONOR/$name" ]; then source=$(p5_relative "$P5_DONOR" "$name"); fi
    [ -s "$source" ] || { p5_fail "Missing input: $name"; return 2; }
    p5_json_update "$P5_STAGE/receipts.json" --arg name "$name" --argjson receipt "$(p5_receipt "$source")" '.[$name]=$receipt' || return $?
    printf '%s\n' "$name" >> "$P5_STAGE/$ident.inputs" || return $?
    printf '%s\n' "$source"
}
p5_boot_patch() {
    local source=$1 output=$2 spec=$3 ident=$4 kind iv key material raw patched flags status=0
    kind=iBSS; [ "$ident" != ibec ] || kind=iBEC
    material="$P5_STAGE/donor-keys.json"
    if [ ! -f "$material" ]; then
        if [ -n "$P5_KEYS" ]; then jq '.donor//.' "$P5_KEYS" > "$material";
        else bash "$P5_LIB/keys.sh" --model iPhone5,3 --version 7.0.1 --build 11A470a --components iBSS,iBEC > "$material" || return $?; fi
    fi
    iv=$(jq -er --arg kind "$kind" '.[$kind].iv' "$material") || return $?; key=$(jq -er --arg kind "$kind" '.[$kind].key' "$material") || return $?
    raw="$P5_STAGE/$ident.raw"; patched="$P5_STAGE/$ident.patched"
    p5_native img3-data "$source" "$raw" "$iv" "$key" || return $?
    LC_ALL=C grep -aFq "$kind for n48ap" "$raw" || { p5_fail 'Wrong boot donor'; return 2; }
    local patch_flags=(); while IFS= read -r flags; do patch_flags+=("$flags"); done < <(printf '%s\n' "$spec"|jq -r '.flags[]')
    p5_run_timeout 60 "$P5_BINS" iBoot32Patcher "$raw" "$patched" ${patch_flags[@]+"${patch_flags[@]}"} > "$P5_STAGE/$ident.log" 2>&1 || status=$?
    [ "$status" -le 1 ] && [ -f "$patched" ] && grep -q 'main: Quitting' "$P5_STAGE/$ident.log" || { p5_fail 'Boot patcher failed'; return 2; }
    [ "$(p5_size "$raw")" = "$(p5_size "$patched")" ] && ! cmp -s "$raw" "$patched" || return 2
    if [ "$kind" = iBEC ]; then LC_ALL=C grep -aFq 'rd=disk0s1s1 -v debug=0x2014e wdt=-1 pio-error=0 amfi=0xff cs_enforcement_disable=1' "$patched" || return 2; fi
    p5_run_timeout 60 "$P5_BINS" xpwntool "$patched" "$output" -t "$source" -iv "$iv" -k "$key" > "$P5_STAGE/encrypt.log" 2>&1 || return $?
    p5_native img3-data "$output" "$raw.check" "$iv" "$key" || return $?; cmp -s "$patched" "$raw.check" || { p5_fail 'Boot encrypted round trip differs'; return 2; }
    printf '{"model":"N48AP","encrypted_round_trip":true}\n'
}
p5_build_one() {
    local ident=$1 spec kind input= source= out="$P5_STAGE/cache/$1" name core template header value wanted
    [ ! -f "$out" ] || return 0
    [ ! -e "$P5_STAGE/$ident.busy" ] || { p5_fail 'Recipe dependency cycle'; return 2; }; touch "$P5_STAGE/$ident.busy"; : > "$P5_STAGE/$ident.inputs"
    spec=$(p5_spec "$ident" "$P5_MODEL"); kind=$(printf '%s' "$spec"|jq -r .kind); input=$(printf '%s' "$spec"|jq -r '.input//empty')
    p5_log "Patch $ident: $kind"
    if [ -n "$input" ]; then source=$(p5_build_input "$input" "$ident"); fi
    case "$kind" in
        kernel) p5_kernel_build "$source" "$out" "$P5_MODEL" "$P5_PROFILE" "$P5_JAILBREAK" ;;
        bsdiff) p5_apply_fixed "$source" "$spec" "$P5_PROFILE" "$out" >/dev/null ;;
        copy) cp -- "$source" "$out" ;;
        media-audio)
            p5_native media-audio "$source" "$out.unsigned" >/dev/null
            p5_native signature "$out.unsigned" "$out" >/dev/null
            p5_native signature "$out" >/dev/null; rm -- "$out.unsigned"
            ;;
        media-h4isp)
            core=$(printf '%s' "$spec"|jq -r .core); p5_build_one "$core"
            cat "$P5_STAGE/$core.inputs" >> "$P5_STAGE/$ident.inputs"
            name=$(p5_build_input n49-setfile.dat "$ident")
            p5_native media-h4isp "$P5_STAGE/cache/$core" "$name" "$out.unsigned" >/dev/null
            p5_native signature "$out.unsigned" "$out" >/dev/null
            p5_native signature "$out" >/dev/null; rm -- "$out.unsigned"
            ;;
        boot-feature) p5_boot_patch "$source" "$out" "$spec" "$ident" >/dev/null ;;
        container)
            core=$(printf '%s' "$spec"|jq -r .core); p5_build_one "$core"; cat "$P5_STAGE/$core.inputs" >> "$P5_STAGE/$ident.inputs"
            if [[ "$core" = kernel-* ]]; then
                header=$(p5_relative "$P5_ROOT/resources" "$(printf '%s' "$spec"|jq -r .compression_header_file)")
                p5_native lzss-pack "$P5_STAGE/cache/$core" "$header" "$out.complzss"; source="$out.complzss"
            else source="$P5_STAGE/cache/$core"; fi
            template=$(p5_relative "$P5_ROOT/resources" "$(printf '%s' "$spec"|jq -r .template_file)")
            p5_native img3-wrap "$template" "$source" "$out"
            ;;
        feature-runtime|payload) name=$(p5_relative "$P5_ROOT/resources" "$(printf '%s' "$spec"|jq -r .payload)"); cp -- "$name" "$out" ;;
        *) p5_fail "Unsupported recipe: $kind"; return 2 ;;
    esac
    rm -- "$P5_STAGE/$ident.busy"
}
p5_build() {
    local inputs=$1 dest=$2 profile=$3 extras=$4 only=$5 model=$6 bins=$7 donor=$8 keys=$9 jailbreak=${10:-yes} id path mode receipts target
    case "$jailbreak" in yes|no) ;; *) p5_fail 'Invalid jailbreak policy'; return 2 ;; esac
    P5_JAILBREAK=$jailbreak
    P5_INPUTS=$(p5_abs "$inputs"); P5_MODEL=$model; P5_PROFILE=$(p5_profile "$profile"); P5_DONOR=$donor; P5_BINS=$bins; P5_KEYS=$keys
    P5_SOURCE=$(p5_source_identity "$P5_INPUTS"); P5_ACTIVE=$(p5_select "$profile" "$extras" "$only" "$model")
    p5_temp; P5_STAGE="$P5_TMP/build"; mkdir -p "$P5_STAGE/cache" "$P5_STAGE/bundle"; printf '{}\n' > "$P5_STAGE/receipts.json"
    [ ! -e "$dest" ] || { p5_fail "Build destination exists: $dest"; return 2; }
    while IFS= read -r id; do p5_build_one "$id"; done < <(printf '%s' "$P5_ACTIVE"|jq -r '.[]')
    target=$(p5_target "$model" | jq 'del(.board_id)')
    if [ -f "$P5_INPUTS/SystemVersion.plist" ]; then target=$(jq -n --argjson target "$target" --argjson version "$(p5_plist "$P5_INPUTS/SystemVersion.plist")" '$target+($version|{ProductVersion,ProductBuildVersion})'); fi
    jq -n --arg jailbreak "$jailbreak" --argjson active "$P5_ACTIVE" --argjson target "$target" --arg profile "$profile" --arg extras "$extras" --argjson source "$P5_SOURCE" --slurpfile receipts "$P5_STAGE/receipts.json" '{schema:1,kernel_layout:6,jailbreak_kernel:{enabled:($jailbreak=="yes"),revision:1},profile:$profile,extras:($extras|split(",")|map(select(length>0))),selected:$active,target:$target,files:[],input_receipts:$receipts[0],source_firmware:$source}' > "$P5_STAGE/bundle/build.json"
    while IFS= read -r id; do
        local spec; spec=$(p5_spec "$id" "$model"); path=$(printf '%s' "$spec"|jq -r .destination); mode=$(printf '%s' "$spec"|jq -r .mode)
        local output; output=$(p5_relative "$P5_STAGE/bundle" "$path"); mkdir -p "$(dirname -- "$output")"; cp -- "$P5_STAGE/cache/$id" "$output"; printf -v mode '%o' "$mode"; chmod "$mode" "$output"
        local originals; originals=$(LC_ALL=C sort -u "$P5_STAGE/$id.inputs"|jq -Rsc 'split("\n")|map(select(length>0))')
        p5_json_update "$P5_STAGE/bundle/build.json" --arg id "$id" --arg path "$path" --argjson mode "$((8#$mode))" --argjson receipt "$(p5_receipt "$output")" --argjson originals "$originals" '.files+=[{id:$id,path:$path,mode:$mode,original_inputs:$originals}+$receipt]'
    done < <(printf '%s' "$P5_ACTIVE"|jq -r '.[]')
    mkdir -p "$(dirname -- "$dest")"; mv -- "$P5_STAGE/bundle" "$dest"; cat "$dest/build.json"
}
p5_verify_bundle() {
    local bundle=$1 boot_only=${2:-no} report id path sha size model expected count=0
    report="$bundle/build.json"
    jq -e '(.files|length)>0 and ([.files[].id]|length)==([.files[].id]|unique|length)' "$report" >/dev/null || return 2
    model=$(jq -r '.target.ProductType' "$report"); p5_target "$model" >/dev/null || return $?
    while IFS=$'\t' read -r id path sha size; do
        if [ "$boot_only" = yes ]; then
            case "$id" in ibss|ibec|devicetree-img3|kernel-img3-*) ;; *) continue ;; esac
        fi
        expected=$(p5_spec "$id" "$model"|jq -r .destination) || return $?
        [ "$path" = "$expected" ] || { p5_fail "Unexpected bundle path: $path"; return 2; }
        path=$(p5_relative "$bundle" "$path") || return $?
        p5_check_file "$path" "$size" "$sha" || return $?; count=$((count+1))
    done < <(jq -r '.files[]|[.id,.path,.sha256,.size]|@tsv' "$report")
    if [ "$boot_only" = yes ]; then [ "$count" = 4 ] || { p5_fail 'Boot bundle incomplete'; return 2; }; fi
    cat "$report"
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    command=${1:-help}; [ "$#" -eq 0 ] || shift; p5_args "$@"
    model=$(p5_get model iPhone5,4); profile=$(p5_profile "$(p5_get profile wifi)"); extras=$(p5_normalize_extras "$(p5_get extras)"); only=$(p5_get only)
    if [ "$command" = build ] && [ -n "$(p5_get out)" ]; then p5_output_temp "$(p5_get out)"; else p5_temp; fi
    result="$P5_TMP/result.json"
    case "$command" in
        help|--help) printf 'Usage: patches.sh build|verify|ramboot [options]\nBuild: --model MODEL --profile base|wifi --inputs DIR --out DIR [--jailbreak yes|no]\n'; exit 0 ;;
        build) p5_required inputs out
            p5_build "$(p5_get inputs)" "$(p5_get out)" "$profile" "$extras" "$only" "$model" "$(p5_get tools-dir "$P5_TOOLS")" "$(p5_get donor-inputs)" "$(p5_get keys)" "$(p5_get jailbreak yes)" > "$result" ;;
        verify) p5_required bundle; p5_verify_bundle "$(p5_get bundle)" "$(p5_get boot-only no)" > "$result" ;;
        ramboot) source "$P5_LIB/usb.sh"; p5_required bundle ecid; p5_ramboot "$(p5_get bundle)" "$(p5_get tools-dir "$P5_TOOLS")" "$(p5_get ecid)" "$(p5_get execute no)" > "$result" ;;
        *) p5_fail "Unknown operation: $command"; exit 2 ;;
    esac
    p5_finish "$result" "$command complete"
fi
