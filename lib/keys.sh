#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
p5_args "$@"; p5_required model version build components
MODEL=$(p5_get model); VERSION=$(p5_get version); BUILD=$(p5_get build); COMPONENTS=$(p5_get components)
KEYFILE="$P5_ROOT/firmware/keys.json"
[ -f "$KEYFILE" ] || { p5_fail 'Bundled firmware/keys.json is missing; restore it or supply --keys'; exit 2; }
p5_log "Load bundled firmware keys: $MODEL / $VERSION / $BUILD"
jq -e --arg model "$MODEL" --arg version "$VERSION" --arg build "$BUILD" \
    --arg components "$COMPONENTS" --arg rootfs "$(p5_get rootfs no)" '
 def material($name;$sizes):
   if type!="string" then error("Missing firmware decryption material: "+$name)
   elif test("^[0-9a-fA-F]+$") and (length as $n|$sizes|index($n)) then ascii_downcase
   else error("Invalid firmware decryption material: "+$name) end;
 .[$version]
 |if .build==$build then .devices[$model] else error("Firmware version/build differs from bundled keys") end
 |if type=="object" then . else error("No bundled firmware keys for "+$model+" / "+$version) end
 |. as $f|reduce ($components|split(",")[]) as $component ({};
   .[$component]={iv:($f[$component].iv|material($component+" IV";[32])),key:($f[$component].key|material($component+" Key";[32,64]))})
 |if $rootfs=="yes" then .rootfs=($f.rootfs|material("RootFS Key";[72])) else . end' "$KEYFILE"
