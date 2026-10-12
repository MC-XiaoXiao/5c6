#!/usr/bin/env bash
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
p5_bootstrap() {
    local output=$1 patches="$P5_ROOT/patches/jailbreak" row name count essential rel hashes='{}'
    p5_temp
    while IFS= read -r row; do
        name=$(printf '%s' "$row" | jq -r .path)
        p5_check_file "$(p5_relative "$patches" "$name")" "$(printf '%s' "$row"|jq -r .bytes)" "$(printf '%s' "$row"|jq -r .sha256)" || return $?
    done < <(jq -c '.archives[]' "$patches/bootstrap.json")
    jq --arg dir "$patches" '{archives:[.archives[]|$dir+"/"+.path],filter_prefix:"private/var",keep_prefixes:["private/var/lib","private/var/root/Media/Cydia"],rename_prefix:"private/project5c-jailbreak/seed",exclude:["Library/LaunchDaemons/com.saurik.Cydia.Startup.plist"]}' "$patches/bootstrap.json" > "$P5_TMP/bootstrap-policy.json"
    count=$(p5_native tar-repack "$P5_TMP/bootstrap-policy.json" "$output") || return $?
    essential='["Applications/Cydia.app/Cydia","bin/bash","usr/bin/dpkg","usr/bin/dpkg-query","usr/libexec/cydia/startup","private/project5c-jailbreak/seed/lib/dpkg/status"]'
    while IFS= read -r rel; do
        bsdtar -xOf "$output" "$rel" > "$P5_TMP/bootstrap-essential" || return $?
        [ -s "$P5_TMP/bootstrap-essential" ] || { p5_fail "Bootstrap lacks $rel"; return 2; }
        hashes=$(printf '%s' "$hashes"|jq --arg rel "$rel" --arg sha "$(p5_sha "$P5_TMP/bootstrap-essential")" '.[$rel]=$sha')
    done < <(printf '%s' "$essential"|jq -r '.[]')
    jq -n --argjson files "$count" --arg sha "$(p5_sha "$output")" --argjson essential "$essential" --argjson hashes "$hashes" '{kind:"tethered-iOS6-bootstrap",archive_sha256:$sha,files:$files,tethered:true,data_seed:"/private/project5c-jailbreak/seed",essential_paths:$essential,essential_sha256:$hashes}'
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then set -euo pipefail; [ "$#" -eq 1 ] || exit 2; p5_bootstrap "$1"; fi
