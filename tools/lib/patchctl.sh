#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/firmware.sh"
P5_CATALOG="$P5_ROOT/patches/catalog.json"
p5_read_spec() {
    jq -e --arg key "$1" --arg model "$2" '
      (.specs[$key]//error("Unknown patch recipe: "+$key))
      | . + (.models[$model]//{}) | del(.models)' "$P5_CATALOG"
}
p5_spec() {
    local key
    key=$(jq -er --arg model "$2" --arg id "$1" '.catalogs[$model].recipes[$id]//.catalogs[$model].checks[$id]' "$P5_CATALOG") || return $?
    p5_read_spec "$key" "$2" | jq --arg id "$1" '.+{id:$id}'
}
p5_select() {
    jq -c --arg profile "$1" --arg extras "$2" --arg only "$3" --arg model "$4" '
      . as $c|if $only!="" then $only|split(",") else (.PROFILES[$profile]//error("Unknown profile"))+([$extras|split(",")[]|select(length>0)|$c.EXTRAS[.]//error("Unknown extra")]|add//[]) end
      |reduce .[] as $id ([];if index($id) then . else .+[$id] end)
      |if length>0 and all(.[];$c.catalogs[$model].recipes[.]!=null) then . else error("Patch unavailable for target model") end' "$P5_CATALOG"
}
p5_apply_fixed() {
    local input=$1 info=$2 profile=$3 output=$4 row patch sha size
    sha=$(p5_sha "$input") || return $?; size=$(p5_size "$input") || return $?
    row=$(printf '%s\n' "$info" | jq -ce --arg sha "$sha" --argjson size "$size" --arg profile "$profile" '[.variants[]|select(.source.sha256==$sha and .source.size==$size and ((.profiles//[]|length)==0 or (.profiles|index($profile))))]|if length==1 then .[0] else error("No unique fixed patch for input/profile") end') || return $?
    patch=$(p5_relative "$P5_ROOT/patches" "$(printf '%s\n' "$row" | jq -r .patch)") || return $?
    # Git owns patch assets. Validate firmware preimages and results at runtime.
    p5_native apply "$input" "$patch" "$output" || return $?
    p5_check_file "$output" "$(printf '%s\n' "$row"|jq -r .output.size)" "$(printf '%s\n' "$row"|jq -r .output.sha256)" || return $?
    printf '%s\n' "$row" | jq '{format:"BSDIFF40",patch:.patch,source_sha256:.source.sha256,output_sha256:.output.sha256}'
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
        else bash "$P5_LIB/firmwarekeys.sh" --model iPhone5,3 --version 7.0.1 --build 11A470a --components iBSS,iBEC > "$material" || return $?; fi
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
    local ident=$1 spec kind input= source= out="$P5_STAGE/cache/$1" evidence='{}' name core template header value wanted
    [ ! -f "$out" ] || return 0
    [ ! -e "$P5_STAGE/$ident.busy" ] || { p5_fail 'Recipe dependency cycle'; return 2; }; touch "$P5_STAGE/$ident.busy"; : > "$P5_STAGE/$ident.inputs"
    spec=$(p5_spec "$ident" "$P5_MODEL"); kind=$(printf '%s' "$spec"|jq -r .kind); input=$(printf '%s' "$spec"|jq -r '.input//empty')
    p5_log "Patch $ident: $kind"
    if [ -n "$input" ]; then source=$(p5_build_input "$input" "$ident"); fi
    case "$kind" in
        bsdiff)
            name=$(printf '%s' "$spec"|jq -r '.donor_input//empty')
            if [ -n "$name" ]; then name=$(p5_build_input "$name" "$ident"); p5_tree_identity "$name" "$P5_MODEL"; fi
            evidence=$(p5_apply_fixed "$source" "$spec" "$P5_PROFILE" "$out")
            if [ "$(printf '%s' "$spec"|jq -r '.resign//false')" = true ]; then p5_native signature "$out" >/dev/null; fi ;;
        copy)
            wanted=$(printf '%s' "$spec"|jq -r '.input_size//.size'); [ "$(p5_size "$source")" = "$wanted" ] || { p5_fail "Donor extent differs: $input"; return 2; }
            wanted=$(printf '%s' "$spec"|jq -r '.sha256//empty'); if [ -n "$wanted" ]; then [ "$(p5_sha "$source")" = "$wanted" ] || return 2; fi
            while IFS= read -r value; do p5_native locate "$source" "$value" >/dev/null; done < <(printf '%s' "$spec"|jq -r '.features[]?')
            if [ "$(printf '%s' "$spec"|jq -r '.match.plist//false')" = true ]; then p5_plist "$source" | jq -e 'type=="object"' >/dev/null; fi
            cp -- "$source" "$out"
            core=$(printf '%s' "$spec"|jq -r '.kernel_dependency//empty|if type=="array" then .[] else . end'|head -1)
            if [ -n "$core" ]; then
                if printf '%s' "$P5_ACTIVE"|jq -e 'index("kernel-wifi-candidate")' >/dev/null; then core=kernel-wifi-candidate; fi
                p5_build_one "$core"; cat "$P5_STAGE/$core.inputs" >> "$P5_STAGE/$ident.inputs"
                p5_prelink_check "$P5_STAGE/cache/$core" "$(p5_spec "$(printf '%s' "$spec"|jq -r .kernel_check)" "$P5_MODEL")"
            fi ;;
        boot-feature) evidence=$(p5_boot_patch "$source" "$out" "$spec" "$ident") ;;
        container)
            core=$(printf '%s' "$spec"|jq -r .core); p5_build_one "$core"; cat "$P5_STAGE/$core.inputs" >> "$P5_STAGE/$ident.inputs"
            if [[ "$core" = kernel-* ]]; then
                header=$(p5_relative "$P5_ROOT/patches" "$(printf '%s' "$spec"|jq -r .compression_header_file)")
                p5_native lzss-pack "$P5_STAGE/cache/$core" "$header" "$out.complzss"; source="$out.complzss"
            else source="$P5_STAGE/cache/$core"; fi
            template=$(p5_relative "$P5_ROOT/patches" "$(printf '%s' "$spec"|jq -r .template_file)")
            p5_native img3-wrap "$template" "$source" "$out"
            evidence=$(jq -n --arg core "$core" '{derived_from:$core}') ;;
        feature-runtime|payload) name=$(p5_relative "$P5_ROOT/patches" "$(printf '%s' "$spec"|jq -r .payload)"); cp -- "$name" "$out" ;;
        *) p5_fail "Unsupported recipe: $kind"; return 2 ;;
    esac
    printf '%s\n' "$evidence" > "$P5_STAGE/$ident.evidence"
    rm -- "$P5_STAGE/$ident.busy"
}
p5_build() {
    local inputs=$1 dest=$2 profile=$3 extras=$4 only=$5 model=$6 bins=$7 donor=$8 keys=$9 doctor=${10:-no} id path mode receipts target
    P5_INPUTS=$(p5_abs "$inputs"); P5_MODEL=$model; P5_PROFILE=$profile; P5_DONOR=$donor; P5_BINS=$bins; P5_KEYS=$keys
    P5_SOURCE=$(p5_source_identity "$P5_INPUTS"); P5_ACTIVE=$(p5_select "$profile" "$extras" "$only" "$model")
    p5_temp; P5_STAGE="$P5_TMP/build"; mkdir -p "$P5_STAGE/cache" "$P5_STAGE/bundle"; printf '{}\n' > "$P5_STAGE/receipts.json"
    [ ! -e "$dest" ] || [ "$doctor" = yes ] || { p5_fail "Build destination exists: $dest"; return 2; }
    while IFS= read -r id; do p5_build_one "$id"; done < <(printf '%s' "$P5_ACTIVE"|jq -r '.[]')
    target=$(p5_target "$model" | jq 'del(.board_id)')
    if [ -f "$P5_INPUTS/SystemVersion.plist" ]; then target=$(jq -n --argjson target "$target" --argjson version "$(p5_plist "$P5_INPUTS/SystemVersion.plist")" '$target+($version|{ProductVersion,ProductBuildVersion})'); fi
    jq -n --argjson active "$P5_ACTIVE" --argjson target "$target" --arg profile "$profile" --arg extras "$extras" --argjson source "$P5_SOURCE" --slurpfile receipts "$P5_STAGE/receipts.json" '{schema:1,matching:"binary-features",profile:$profile,extras:($extras|split(",")|map(select(length>0))),selected:$active,target:$target,files:[],input_receipts:$receipts[0],feature_evidence:{},source_firmware:$source,device_operations:false,physical_validation:false}' > "$P5_STAGE/bundle/build.json"
    while IFS= read -r id; do
        local spec; spec=$(p5_spec "$id" "$model"); path=$(printf '%s' "$spec"|jq -r .destination); mode=$(printf '%s' "$spec"|jq -r .mode)
        local output; output=$(p5_relative "$P5_STAGE/bundle" "$path"); mkdir -p "$(dirname -- "$output")"; cp -- "$P5_STAGE/cache/$id" "$output"; printf -v mode '%o' "$mode"; chmod "$mode" "$output"
        local originals evidence; originals=$(LC_ALL=C sort -u "$P5_STAGE/$id.inputs"|jq -Rsc 'split("\n")|map(select(length>0))'); evidence=$(cat "$P5_STAGE/$id.evidence")
        p5_json_update "$P5_STAGE/bundle/build.json" --arg id "$id" --arg path "$path" --argjson mode "$((8#$mode))" --argjson receipt "$(p5_receipt "$output")" --argjson originals "$originals" --argjson evidence "$evidence" '.files+=[{id:$id,path:$path,mode:$mode,original_inputs:$originals}+$receipt]|.feature_evidence[$id]=$evidence'
    done < <(printf '%s' "$P5_ACTIVE"|jq -r '.[]')
    if printf '%s' "$P5_ACTIVE"|jq -e 'index("kernel-wifi-candidate") and index("devicetree")' >/dev/null; then
        local wifi; wifi=$(p5_wifi_check "$P5_STAGE/cache/kernel-wifi-candidate" "$P5_STAGE/cache/devicetree" "$model")
        p5_json_update "$P5_STAGE/bundle/build.json" --argjson wifi "$wifi" '.wifi_compatibility=$wifi'
    fi
    if [ "$doctor" = yes ]; then jq '.+{passed:true,recipes:(.files|length),external_inputs:(.input_receipts|length)}' "$P5_STAGE/bundle/build.json"; return; fi
    mkdir -p "$(dirname -- "$dest")"; mv -- "$P5_STAGE/bundle" "$dest"; cat "$dest/build.json"
}
p5_verify_bundle() {
    local bundle=$1 boot_only=${2:-no} report id path sha size model selected expected count=0
    report="$bundle/build.json"; jq -e '.matching=="binary-features" and (.files|length>0) and ([.files[].id]|length)==([.files[].id]|unique|length)' "$report" >/dev/null || return 2
    model=$(jq -r '.target.ProductType' "$report"); local board; board=$(p5_target "$model"|jq -r .HardwareModel) || return $?
    [ "$(jq -r .target.HardwareModel "$report")" = "$board" ] || return 2
    if [ "$boot_only" = no ]; then jq -e '(.selected|sort)==([.files[].id]|sort)' "$report" >/dev/null || return 2; fi
    while IFS=$'\t' read -r id path sha size; do
        if [ "$boot_only" = yes ]; then case "$id" in ibss|ibec|devicetree-img3|kernel-img3-validated|kernel-img3-wifi-candidate) ;; *) continue ;; esac; fi
        expected=$(p5_spec "$id" "$model"|jq -r .destination) || return $?; [ "$path" = "$expected" ] || { p5_fail 'Artifact path differs from recipe'; return 2; }
        path=$(p5_relative "$bundle" "$path") || return $?; p5_check_file "$path" "$size" "$sha" || return $?; count=$((count+1))
    done < <(jq -r '.files[]|[.id,.path,.sha256,.size]|@tsv' "$report")
    if [ "$boot_only" = yes ]; then [ "$count" = 4 ] || { p5_fail 'Boot bundle incomplete'; return 2; }; fi
    if jq -e '.files|any(.id=="kernel-wifi-candidate" or .id=="kernel-img3-wifi-candidate")' "$report" >/dev/null; then
        if [ "$boot_only" = yes ]; then p5_wifi_check "$bundle/boot/kernelcache.img3" "$bundle/boot/DeviceTree.img3" "$model" >/dev/null || return $?;
        else p5_wifi_check "$bundle/boot/kernelcache.macho" "$bundle/boot/DeviceTree.dtb" "$model" >/dev/null || return $?; fi
    fi
    cat "$report"
}
p5_catalog_check() {
    local model id spec path size sha
    for model in iPhone5,3 iPhone5,4; do
        while IFS= read -r id; do
            spec=$(p5_spec "$id" "$model")
            while IFS=$'\t' read -r path size sha; do path=$(p5_relative "$P5_ROOT/patches" "$path"); p5_check_file "$path" "$size" "$sha"; done < <(printf '%s' "$spec"|jq -r '.variants[]?|[.patch,.delta.size,.delta.sha256]|@tsv')
        done < <(jq -r --arg model "$model" '.catalogs[$model].recipes|keys[]' "$P5_CATALOG")
    done
    printf '{"passed":true,"models":["iPhone5,3","iPhone5,4"]}\n'
}
p5_input_ids() {
    local ident=$1 model=$2 active=$3 spec core
    spec=$(p5_spec "$ident" "$model"); printf '%s' "$spec"|jq -r '.input//empty,.donor_input//empty'
    core=$(printf '%s' "$spec"|jq -r '.core//empty')
    [ -z "$core" ] || p5_input_ids "$core" "$model" "$active"
    core=$(printf '%s' "$spec"|jq -r '.kernel_dependency//empty|if type=="array" then .[0] else . end')
    if [ -n "$core" ]; then
        if printf '%s' "$active"|jq -e 'index("kernel-wifi-candidate")' >/dev/null; then core=kernel-wifi-candidate; fi
        p5_input_ids "$core" "$model" "$active"
    fi
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    command=${1:-help}; [ "$#" -eq 0 ] || shift; p5_args "$@"
    model=$(p5_get model iPhone5,4); profile=$(p5_get profile native6-validated); extras=$(p5_normalize_extras "$(p5_get extras)"); only=$(p5_get only)
    if [ "$command" = build ] && [ -n "$(p5_get out)" ]; then p5_output_temp "$(p5_get out)"; else p5_temp; fi
    result="$P5_TMP/result.json"
    case "$command" in
        help|--help) printf 'Usage: patchctl.sh check|list|inputs|build|doctor|verify|ramboot [options]\n'; exit 0 ;;
        check) p5_catalog_check > "$result" ;;
        list) jq -n --arg model "$model" --argjson selected "$(p5_select "$profile" "$extras" "$only" "$model")" '{model:$model,selected:$selected}' > "$result" ;;
        inputs) selected=$(p5_select "$profile" "$extras" "$only" "$model"); while IFS= read -r id; do p5_input_ids "$id" "$model" "$selected"; done < <(printf '%s' "$selected"|jq -r '.[]') | LC_ALL=C sort -u | jq -Rsc 'split("\n")|map(select(length>0))' > "$result" ;;
        build|doctor) p5_required inputs; [ "$command" != build ] || p5_required out
            doctor=no; [ "$command" != doctor ] || doctor=yes
            p5_build "$(p5_get inputs)" "$(p5_get out)" "$profile" "$extras" "$only" "$model" "$(p5_get tools-dir "$P5_TOOLS")" "$(p5_get donor-inputs)" "$(p5_get keys)" "$doctor" > "$result" ;;
        verify) p5_required bundle; p5_verify_bundle "$(p5_get bundle)" "$(p5_get boot-only no)" > "$result" ;;
        ramboot) source "$P5_LIB/hosttools.sh"; p5_required bundle ecid; p5_ramboot "$(p5_get bundle)" "$(p5_get tools-dir "$P5_TOOLS")" "$(p5_get ecid)" "$(p5_get execute no)" > "$result" ;;
        *) p5_fail "Unknown operation: $command"; exit 2 ;;
    esac
    if [ "$command" = list ] || [ "$command" = inputs ]; then cat "$result"; else p5_finish "$result" "$command complete"; fi
fi
