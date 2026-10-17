#!/usr/bin/env bash
source "$(dirname -- "${BASH_SOURCE[0]}")/http.sh"
P5_TSS_URL='https://gs.apple.com/TSS/controller?action=2'
p5_apple_url() {
    local url=$1 host
    case "$url" in http://appldnld.apple.com/*) url="https://secure-appldnld.apple.com/${url#http://appldnld.apple.com/}" ;; esac
    case "$url" in https://*) ;; *) p5_fail 'Firmware URL must use Apple HTTPS'; return 2 ;; esac
    host=${url#https://}; host=${host%%/*}
    case "$host" in apple.com|*.apple.com) ;; *) p5_fail 'Firmware URL must use Apple HTTPS'; return 2 ;; esac
    case "$host" in *[@:#?]*) return 2 ;; esac
    printf '%s\n' "$url"
}
p5_baseband_latest() {
    local model=$1 spec url
    p5_temp
    p5_http_fetch metadata 'Query signed Apple firmware metadata' "https://api.ipsw.me/v4/device/$model?type=ipsw" "$P5_TMP/latest.json" 0 --max-filesize 2097152 >/dev/null || return $?
    spec=$(jq -ce --arg model "$model" 'select(.identifier==$model)|[.firmwares[]|select(.signed==true and .identifier==$model)]|max_by(.version|split(".")|map(tonumber))|select(.buildid|test("^[A-Za-z0-9]+$"))|select(.filesize>0 and .filesize<17179869184)' "$P5_TMP/latest.json") || return $?
    [ -n "$spec" ] || { p5_fail 'No signed firmware found'; return 2; }
    url=$(p5_apple_url "$(printf '%s' "$spec"|jq -r .url)") || return $?
    printf '%s' "$spec"|jq --arg url "$url" '.url=$url'
}
p5_baseband_identity() {
    local manifest=$1 spec=$2 model=$3 target
    target=$(p5_target "$model")
    p5_plist "$manifest" | jq -L "$P5_LIB" -ce --argjson spec "$spec" --arg model "$model" --argjson target "$target" '
      include "identity";
      select((.SupportedProductTypes|index($model)) and .ProductVersion==$spec.version and .ProductBuildVersion==$spec.buildid)
      |[.BuildIdentities[]|select((.Info.DeviceClass|ascii_downcase)==($target.HardwareModel|ascii_downcase) and .Info.RestoreBehavior=="Erase")]
      |if length==1 then .[0] else error("No unique model erase identity") end
      |select((.ApBoardID|asnum)==$target.board_id and (.ApChipID|asnum)==35152 and (.BbChipID|asnum)==7282913)
      |select(.Manifest.BasebandFirmware.Info.Path|test("^Firmware/Mav7Mav8-[^/]+\\.bbfw$"))' || { p5_fail 'Unsupported baseband manifest identity'; return 2; }
}
p5_baseband_fetch() (
    local spec=$1 model=$2 cache=$3 dest stage='' name row url
    trap '[ -z "$stage" ] || rm -rf -- "$stage"' EXIT
    dest="$cache/$model-$(printf '%s' "$spec"|jq -r .buildid)"; mkdir -p "$cache"
    if [ -d "$dest" ]; then
        jq -e --argjson spec "$spec" '.spec==$spec and (.files|keys)==["Baseband.bbfw","BuildManifest.plist"]' "$dest/download.json" >/dev/null || return $?
        while IFS=$'\t' read -r name sha; do [ "$(p5_sha "$dest/$name")" = "$sha" ] || { p5_fail 'Cached baseband changed'; return 2; }; done < <(jq -r '.files|to_entries[]|[.key,.value]|@tsv' "$dest/download.json")
        p5_baseband_identity "$dest/BuildManifest.plist" "$spec" "$model" >/dev/null || return $?
        p5_log "Use cached Apple baseband $(printf '%s' "$spec"|jq -r '.version+" / "+.buildid')"
    else
        stage=$(mktemp -d "$cache/.baseband.XXXXXX") || return $?
        url=$(p5_apple_url "$(printf '%s' "$spec"|jq -r .url)") || return $?
        p5_log "Fetch Apple baseband $(printf '%s' "$spec"|jq -r '.version+" / "+.buildid')"
        p5_remote_member "$url" BuildManifest.plist "$stage/BuildManifest.plist" || return $?
        row=$(p5_baseband_identity "$stage/BuildManifest.plist" "$spec" "$model") || return $?
        p5_remote_member "$url" "$(printf '%s' "$row"|jq -r .Manifest.BasebandFirmware.Info.Path)" "$stage/Baseband.bbfw" || return $?
        if [ "$(printf '%s' "$spec"|jq -r .buildid)" = 14G60 ]; then
            [ "$(p5_sha "$stage/Baseband.bbfw")" = 36fecf09057f5d618a3ccf3466c9e93985c6ebaa8fb42adce921d660784175b6 ] || { rm -rf -- "$stage"; p5_fail '14G60 baseband differs'; return 2; }
        fi
        jq -n --argjson spec "$spec" --arg manifest "$(p5_sha "$stage/BuildManifest.plist")" --arg firmware "$(p5_sha "$stage/Baseband.bbfw")" '{spec:$spec,files:{"BuildManifest.plist":$manifest,"Baseband.bbfw":$firmware}}' > "$stage/download.json" || return $?
        [ ! -e "$dest" ] || { p5_fail 'Baseband cache was created concurrently'; return 2; }; mv -- "$stage" "$dest" || return $?
    fi
    printf '%s\n' "$dest"
)
p5_validate_baseband() {
    local file=$1 names name
    names=$(p5_zip_list "$file"|jq -Rsc 'split("\n")|map(select(length>0))')
    printf '%s' "$names"|jq -e 'index("bbticket.der") and any(endswith(".mbn"))' >/dev/null || { p5_fail 'Expected personalized ZIP with BBTicket and MBN components'; return 2; }
    p5_temp
    p5_zip_check "$file" || return $?
    p5_zip_member "$file" bbticket.der "$P5_TMP/bbticket.der" || return $?
    [ -s "$P5_TMP/bbticket.der" ] || { p5_fail 'Baseband ZIP lacks ticket'; return 2; }
}
p5_baseband_receipt() {
    local file=$1 model=$2 ecid=$3
    jq -e --arg model "$model" --argjson ecid "$((ecid))" --arg sha "$(p5_sha "$file")" '.model==$model and .ecid==$ecid and .package_sha256==$sha' "$(dirname -- "$file")/personalization.json" >/dev/null || { p5_fail 'Personalized baseband device/hash differs'; return 2; }
    p5_validate_baseband "$file" || return $?; cat "$(dirname -- "$file")/personalization.json"
}
p5_native_source() {
    local dir=$1 model=$2 ecid=${3:-} report row saved name sha
    report=$(cat "$dir/source.json")
    printf '%s' "$report"|jq -e --arg model "$model" --arg ecid "$ecid" '.schema==1 and .signing=="idevicerestore-BasebandData" and (.files|keys)==["Baseband.bbfw","BuildManifest.plist","identity.plist"] and .model==$model and ($ecid=="" or .ecid==($ecid|tonumber))' >/dev/null || { p5_fail 'Native baseband source binding differs'; return 2; }
    while IFS=$'\t' read -r name sha; do [ "$(p5_sha "$dir/$name")" = "$sha" ] || { p5_fail "Native baseband source changed: $name"; return 2; }; done < <(printf '%s' "$report"|jq -r '.files|to_entries[]|[.key,.value]|@tsv')
    row=$(p5_baseband_identity "$dir/BuildManifest.plist" "$(printf '%s' "$report"|jq .spec)" "$model") || return $?; saved=$(p5_plist "$dir/identity.plist") || return $?
    jq -ne --argjson row "$row" --argjson saved "$saved" '$row==$saved' >/dev/null || { p5_fail 'Native identity differs from Apple manifest'; return 2; }
    printf '%s' "$report"|jq --argjson identity "$row" '.+{identity:$identity}'
}
p5_stage_native() (
    local model=$1 ecid=$2 dir=$3 cache=$4 spec resources row stage='' P5_TMP=''
    p5_temp || return $?
    trap 'rm -rf -- "$P5_TMP"; [ -z "$stage" ] || rm -rf -- "$stage"' EXIT
    if [ -d "$dir" ]; then p5_native_source "$dir" "$model" "$((ecid))" >/dev/null || return $?; printf '%s\n' "$dir"; return; fi
    [ "$((ecid))" -gt 0 ] || return 2
    spec=$(p5_baseband_latest "$model") || return $?; resources=$(p5_baseband_fetch "$spec" "$model" "$cache") || return $?; row=$(p5_baseband_identity "$resources/BuildManifest.plist" "$spec" "$model") || return $?
    mkdir -p "$(dirname -- "$dir")" || return $?; stage=$(mktemp -d "$(dirname -- "$dir")/.native-baseband.XXXXXX") || return $?
    cp -- "$resources/Baseband.bbfw" "$resources/BuildManifest.plist" "$stage/" || return $?
    printf '%s' "$row"|p5_write_plist "$stage/identity.plist" || return $?
    jq -n --arg model "$model" --argjson ecid "$((ecid))" --argjson spec "$spec" --arg bb "$(p5_sha "$stage/Baseband.bbfw")" --arg manifest "$(p5_sha "$stage/BuildManifest.plist")" --arg identity "$(p5_sha "$stage/identity.plist")" '{schema:1,model:$model,ecid:$ecid,spec:$spec,files:{"Baseband.bbfw":$bb,"BuildManifest.plist":$manifest,"identity.plist":$identity},signing:"idevicerestore-BasebandData"}' > "$stage/source.json" || return $?
    [ ! -e "$dir" ] || return 2; mv -- "$stage" "$dir" || return $?
    p5_native_source "$dir" "$model" "$((ecid))" >/dev/null || return $?; printf '%s\n' "$dir"
)
p5_query_parameters() {
    local query=$1 model=$2 ecid=$3
    printf '%s' "$query"|jq -ce --arg model "$model" --argjson ecid "$((ecid))" '
      select(.ProductType==$model and .UniqueChipID==$ecid and $ecid>0)|(.Baseband//.FirmwarePreflightInfo//.)
      |{BbChipID:(.ChipID//.BasebandChipID),BbSNUM:(.ChipSerialNo//.BasebandSerialNumber),BbGoldCertId:(.CertID//.BasebandCertId),BbNonce:(.Nonce//.BasebandNonce)}
      |select(.BbChipID==7282913 and (.BbSNUM["$data"]|type)=="string" and (.BbSNUM["$data"]|length)==8 and (.BbGoldCertId|type)=="number")
      |.BbGoldCertId=(.BbGoldCertId%4294967296+4294967296)%4294967296
      |if .BbNonce==null then del(.BbNonce) else select((.BbNonce["$data"]|type)=="string" and (.BbNonce["$data"]|length)==40 and .BbNonce["$data"]!=("00"*20)) end' || { p5_fail 'Incomplete model/ECID-bound Mav7 query'; return 2; }
}
p5_normal_query() {
    local model=$1 ecid=$2 bins=$3 udid query devices
    p5_temp
    devices=$(p5_normal_devices) || return $?
    while IFS= read -r udid; do
        [ -n "$udid" ] || continue
        p5_run_timeout 15 "$bins" ideviceinfo -u "$udid" -x > "$P5_TMP/normal-query.plist" || return $?
        query=$(p5_plist "$P5_TMP/normal-query.plist") || return $?
        if printf '%s' "$query"|jq -e --arg model "$model" --argjson ecid "$((ecid))" '.ProductType==$model and .UniqueChipID==$ecid' >/dev/null; then p5_query_parameters "$query" "$model" "$ecid" >/dev/null || return $?; printf '%s\n' "$query"; return; fi
    done < <(printf '%s\n' "$devices")
    p5_fail 'No matching normal-mode device with modem parameters'; return 2
}
p5_personalize() {
    local stock=$1 response=$2 dest=$3 dir name key blob ticket names
    p5_temp || return $?; dir=$(mktemp -d "$P5_TMP/signing.XXXXXX") || return $?
    ticket=$(printf '%s' "$response"|jq -er '.BBTicket["$data"]') || return $?; p5_hex_write "$ticket" "$dir/bbticket.der" || return $?
    [ "$(p5_size "$dir/bbticket.der")" -ge 500 ] && [ "${ticket:0:2}" = 30 ] || return 2
    names=$(p5_zip_list "$stock"|jq -Rsc 'split("\n")|map(select(length>0))') || return $?; printf '%s' "$names"|jq -e '[.[]|select(endswith(".mbn"))]|sort==["apps.mbn","dsp1.mbn","dsp2.mbn","dsp3.mbn","restoresbl1.mbn","rpm.mbn","sbl1.mbn","sbl2.mbn"]' >/dev/null || return 2
    for name in apps dsp1 dsp2 dsp3 rpm sbl1 sbl2 restoresbl1; do p5_zip_member "$stock" "$name.mbn" "$dir/$name.mbn" || return $?; done
    for key in SBL1-Blob RestoreSBL1-Blob; do
        name=sbl1; [ "$key" != RestoreSBL1-Blob ] || name=restoresbl1
        blob=$(printf '%s' "$response"|jq -er --arg key "$key" '.BasebandFirmware[$key]["$data"]') || return $?; p5_hex_write "$blob" "$dir/signature" || return $?
        p5_tail_stitch "$dir/$name.mbn" "$dir/signature" "$dir/$name.new" || return $?; mv -- "$dir/$name.new" "$dir/$name.mbn" || return $?
    done
    [ ! -e "$dest" ] || return 2
    (cd -- "$dir" && touch -t 201707151628.58 ./*.mbn bbticket.der && zip -q -X "$dest" ./*.mbn bbticket.der) || return $?
    p5_validate_baseband "$dest"
}
p5_prepare_baseband() (
    local model=$1 ecid=$2 bins=$3 mode=$4 dir=$5 cache=$6 query_path=$7 dest="$5/Mav7personalized.zip" spec resources row query params request response stage='' cert P5_TMP=''
    p5_temp || return $?
    trap 'rm -rf -- "$P5_TMP"; [ -z "$stage" ] || rm -rf -- "$stage"' EXIT
    if [ -f "$dest" ]; then p5_baseband_receipt "$dest" "$model" "$ecid" >/dev/null || return $?; printf '%s\n' "$dest"; return; fi
    spec=$(p5_baseband_latest "$model") || return $?; resources=$(p5_baseband_fetch "$spec" "$model" "$cache") || return $?; row=$(p5_baseband_identity "$resources/BuildManifest.plist" "$spec" "$model") || return $?
    if [ -n "$query_path" ]; then query=$(p5_plist "$query_path") || return $?; else [ "$mode" = Normal ] || { p5_fail 'Supply an exported query or use native source mode'; return 2; }; query=$(p5_normal_query "$model" "$ecid" "$bins") || return $?; fi
    params=$(p5_query_parameters "$query" "$model" "$ecid") || return $?
    request=$(jq -L "$P5_LIB" -n --argjson row "$row" --argjson params "$params" --argjson ecid "$((ecid))" --arg uuid "$(openssl rand -hex 16|tr '[:lower:]' '[:upper:]'|sed 's/^\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)/\1-\2-\3-\4-/')" 'include "identity";{"@HostPlatformInfo":"mac","@VersionInfo":"libauthinstall-973.0.1","@UUID":$uuid,"@BBTicket":true,ApECID:$ecid,UniqueBuildID:$row.UniqueBuildID,BasebandFirmware:($row.Manifest.BasebandFirmware|del(.Info))}+$params+($row|{ApChipID:(.ApChipID|asnum),ApBoardID:(.ApBoardID|asnum),ApSecurityDomain:(.ApSecurityDomain|asnum),BbProvisioningManifestKeyHash,BbActivationManifestKeyHash,BbCalibrationManifestKeyHash})') || return $?
    [ -n "$request" ] || return 2
    printf '%s' "$request"|p5_write_plist "$P5_TMP/tss-request.plist" || return $?
    cert="$P5_TMP/tss-ca.pem"; : > "$cert"
    for system_ca in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do if [ -f "$system_ca" ]; then cat "$system_ca" >> "$cert"; break; fi; done
    cat "$P5_ROOT/resources/AppleRootCA.pem" >> "$cert"
    p5_http_fetch tss 'Request Apple baseband ticket' "$P5_TSS_URL" "$P5_TMP/tss-response.txt" 0 --max-filesize 4194304 --cacert "$cert" --user-agent 'InetURL/1.0' -H 'Content-Type: text/xml; charset="utf-8"' --data-binary "@$P5_TMP/tss-request.plist" >/dev/null || return $?
    LC_ALL=C grep -aq '^STATUS=0&MESSAGE=SUCCESS&' "$P5_TMP/tss-response.txt" || { p5_fail 'Apple rejected baseband signing'; return 2; }
    sed '1s/^.*<?xml/<?xml/' "$P5_TMP/tss-response.txt" > "$P5_TMP/tss-response.plist" || return $?; response=$(p5_plist "$P5_TMP/tss-response.plist") || return $?
    mkdir -p "$(dirname -- "$dir")" || return $?; [ ! -e "$dir" ] || { p5_fail 'Incomplete personalization directory exists'; return 2; }; stage=$(mktemp -d "$(dirname -- "$dir")/.personalized.XXXXXX") || return $?
    p5_personalize "$resources/Baseband.bbfw" "$response" "$stage/Mav7personalized.zip" || return $?
    cp -- "$P5_TMP/tss-request.plist" "$stage/request.plist" || return $?; printf '%s' "$response"|p5_write_plist "$stage/response.plist" || return $?; printf '%s' "$query"|p5_write_plist "$stage/query.plist" || return $?; cp -- "$resources/BuildManifest.plist" "$stage/" || return $?
    jq -n --arg model "$model" --argjson ecid "$((ecid))" --argjson spec "$spec" --arg path "$(printf '%s' "$row"|jq -r .Manifest.BasebandFirmware.Info.Path)" --arg stock "$(p5_sha "$resources/Baseband.bbfw")" --arg package "$(p5_sha "$stage/Mav7personalized.zip")" --arg request "$(p5_sha "$stage/request.plist")" --arg source "${query_path:+exported-plist}" --arg mode "$mode" --arg query "$(p5_sha "$stage/query.plist")" --argjson nonce "$(printf '%s' "$params"|jq 'has("BbNonce")')" '{schema:1,model:$model,ecid:$ecid,ios_version:$spec.version,build:$spec.buildid,firmware_path:$path,source_package_sha256:$stock,package_sha256:$package,request_sha256:$request,query_source:(if $source!="" then $source else $mode end),query_sha256:$query,nonce_bound:$nonce,apple_tss_ticket_received:true,modem_acceptance_verified:false}' > "$stage/personalization.json" || return $?
    [ -s "$stage/personalization.json" ] || return 2
    mv -- "$stage" "$dir" || return $?; printf '%s\n' "$dest"
)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail; p5_args "$@"
    if [ "$(p5_get help no)" = yes ]; then printf 'Usage: baseband.sh --model MODEL --ecid ECID --out DIR --cache DIR [--native-source | --query PLIST --mode MODE --tools-dir DIR]\n'; exit 0; fi
    p5_required model ecid out cache
    if [ "$(p5_get native-source no)" = yes ]; then p5_stage_native "$(p5_get model)" "$(p5_get ecid)" "$(p5_abs "$(p5_get out)")" "$(p5_abs "$(p5_get cache)")";
    else p5_prepare_baseband "$(p5_get model)" "$(p5_get ecid)" "$(p5_get tools-dir "$P5_TOOLS")" "$(p5_get mode)" "$(p5_abs "$(p5_get out)")" "$(p5_abs "$(p5_get cache)")" "$(p5_get query)"; fi
fi
