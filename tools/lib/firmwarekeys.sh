#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/http.sh"
p5_args "$@"; p5_required model version build components
MODEL=$(p5_get model); VERSION=$(p5_get version); BUILD=$(p5_get build); COMPONENTS=$(p5_get components)
case "$MODEL" in iPhone5,1|iPhone5,2|iPhone5,3|iPhone5,4) ;; *) exit 2 ;; esac
case "$BUILD" in 10B329|10B350) CODENAME=BrightonMaps ;; 11A470a) CODENAME=Innsbruck ;; *) exit 2 ;; esac
p5_temp
URL="https://theapplewiki.com/wiki/Keys:${CODENAME}_${BUILD}_(${MODEL})?action=raw"
FINAL_URL=$(p5_http_fetch keys 'Fetch AppleWiki firmware keys' "$URL" "$P5_TMP/keys.raw" 0 --location --max-filesize 262144 --user-agent 'Project5C6/1.0 firmware keys client') || { p5_fail 'Cannot retrieve AppleWiki keys; retry or supply --keys'; exit 2; }
case "$FINAL_URL" in https://theapplewiki.com/*|https://www.theapplewiki.com/*) ;; *) p5_fail 'AppleWiki redirected outside its domain'; exit 2 ;; esac
[ "$(p5_size "$P5_TMP/keys.raw")" -le 262144 ] || exit 2
awk 'match($0,/^[ \t]*\|[ \t]*[A-Za-z0-9]+[ \t]*=/){s=$0;sub(/^[ \t]*\|[ \t]*/,"",s);key=s;sub(/[ \t]*=.*/,"",key);sub(/^[^=]*=[ \t]*/,"",s);sub(/[ \t\r]+$/,"",s);if(seen[key]++)exit 2;print key "\t" s}' "$P5_TMP/keys.raw" | jq -Rn '[inputs|split("\t")|{key:.[0],value:.[1]}]|from_entries' > "$P5_TMP/fields.json"
jq -e --arg model "$MODEL" --arg version "$VERSION" --arg build "$BUILD" '.Device==$model and .Version==$version and .Build==$build' "$P5_TMP/fields.json" >/dev/null || { p5_fail 'AppleWiki identity differs'; exit 2; }
jq --arg components "$COMPONENTS" --arg rootfs "$(p5_get rootfs no)" '
 def material($name;$sizes): .[$name]//""|if test("^[0-9a-fA-F]+$") and (length as $n|$sizes|index($n)) then ascii_downcase else error("Invalid firmware decryption material") end;
 . as $f|reduce ($components|split(",")[]) as $component ({};($component|if .=="KernelCache" then "Kernelcache" elif .=="RestoreRamDisk" then "RestoreRamdisk" else . end) as $name|.[$component]={iv:($f|material($name+"IV";[32])),key:($f|material($name+"Key";[32,64]))})
 |if $rootfs=="yes" then .rootfs=($f|material("RootFSKey";[72])) else . end' "$P5_TMP/fields.json"
