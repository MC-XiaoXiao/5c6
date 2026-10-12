#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
p5_config() {
    local name=$1 input=$2 option=$3 output=$4
    if [ "$name" = fstab ]; then
        local stock wanted mode=ro
        stock=$(printf '/dev/disk0s1 / hfs ro 0 1\n/dev/disk0s2 /private/var hfs rw,nosuid,nodev 0 2\n')
        case "$option" in readonly) ;; jailbreak) mode=rw ;; *) p5_fail 'Unknown fstab mode'; return 2 ;; esac
        wanted=$(cat "$input")
        case "$wanted" in "$stock"|'/dev/disk0s1s1 / hfs ro 0 1
/dev/disk0s1s2 /private/var hfs rw,nosuid,nodev 0 2'|'/dev/disk0s1s1 / hfs rw 0 1
/dev/disk0s1s2 /private/var hfs rw,nosuid,nodev 0 2') ;; *) p5_fail 'Unexpected fstab layout'; return 2 ;; esac
        printf '/dev/disk0s1s1 / hfs %s 0 1\n/dev/disk0s1s2 /private/var hfs rw,nosuid,nodev 0 2\n' "$mode" > "$output"; return
    fi
    if [ "$name" = jailbreak ]; then
        [ "$option" = bootstrap ] || return 2
        printf '%s\n' '{"Label":"org.project5c.jailbreak","ProgramArguments":["/bin/bash","/usr/libexec/project5c-jailbreak-initialize"],"RunAtLoad":true,"StartInterval":60}' | p5_write_plist "$output"; return
    fi
    p5_plist "$input" | jq --arg name "$name" --arg option "$option" '
      def require($ok;$why): if $ok then . else error($why) end;
      def inject($libs): .EnvironmentVariables=(.EnvironmentVariables//{})
        |require((.EnvironmentVariables|type)=="object";"Invalid launchd environment")
        |require((.EnvironmentVariables.DYLD_INSERT_LIBRARIES//""|type)=="string";"Invalid library list")
        |.EnvironmentVariables.DYLD_INSERT_LIBRARIES=([(.EnvironmentVariables.DYLD_INSERT_LIBRARIES//""|split(":")[]|select(length>0))]+$libs|reduce .[] as $lib ([];if index($lib) then . else .+[$lib] end)|join(":"));
      require(type=="object";"Invalid launchd plist")|
      if $name=="mediaserverd" and $option=="camera" then inject(["/usr/local/lib/camera-ov9762.dylib"])
      elif $name=="mediaserverd" and $option=="microphone" then inject(["/usr/local/lib/native6-microphone-fix.dylib"])
      elif $name=="mediaserverd" and $option=="camera+microphone" then inject(["/usr/local/lib/camera-ov9762.dylib","/usr/local/lib/native6-microphone-fix.dylib"])
      elif $name=="SpringBoard" and $option=="autolock" then inject(["/usr/local/lib/native6-autolock.dylib"])
      elif $name=="locationd" and $option=="gps" then inject(["/usr/local/lib/project5c-locationd-gps.dylib"])
      elif ($name=="BlueTool" or $name=="BTServer") and $option=="bluetooth" then
        require(.Label==("com.apple."+$name);"Unexpected Bluetooth plist")|.EnvironmentVariables=(.EnvironmentVariables//{})
        |.EnvironmentVariables.DYLD_INSERT_LIBRARIES=""|.EnvironmentVariables._MSSafeMode="1"
      elif $name=="CommCenter" and (["n48-native","n48-baseband","n49-native","n49-baseband"]|index($option)) then
        ($option|split("-")) as $parts|require((.LimitLoadToHardware.machine|type)=="array";"Invalid hardware whitelist")
        |(if $parts[0]=="n48" then "iPhone5,3" else "iPhone5,4" end) as $model
        |.LimitLoadToHardware.machine|=if index($model) then . else .+[$model] end
        |if $parts[1]=="baseband" then inject(["/usr/local/lib/project5c-commcenter-hsic.dylib"])
          |.ProgramArguments=["/usr/local/libexec/project5c/CommCenter."+$parts[0]+"-runtime"]|.RunAtLoad=true
          |.StandardOutPath="/var/wireless/Library/Logs/CommCenter.project5c.stdout"|.StandardErrorPath="/var/wireless/Library/Logs/CommCenter.project5c.stderr"
         else . end
      else error("Unknown configuration option") end' | p5_write_plist "$output" binary
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    [ "$#" -eq 4 ] || { printf 'Usage: configpatch.sh NAME INPUT OPTION OUTPUT\n' >&2; exit 2; }
    p5_config "$@"
fi
