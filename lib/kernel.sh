#!/usr/bin/env bash
# The gyro adapter executes code hosted by the appended BMA kernel module.
# Declare that dependency before either driver can probe during a restore.
p5_restore_kernel_u32() {
    local bytes
    bytes=$(p5_native hex-range "$1" "$2" 4) || return $?
    printf '%s\n' "$((16#${bytes:6:2}${bytes:4:2}${bytes:2:2}${bytes:0:2}))"
}
p5_restore_sensor_kernel() {
    local input=$1 output=$2 temp meta dependency command offset used capacity size section hex
    p5_temp || return $?
    temp=$(mktemp -d "$P5_TMP/restore-sensors.XXXXXX") || return $?
    p5_unpack_kernel "$input" "$temp/kernel" || return $?
    meta=$(p5_native prelink "$temp/kernel") || return $?
    if ! printf '%s' "$meta"|jq -e 'any(._PrelinkInfoDictionary[];.CFBundleIdentifier=="com.project5c.AppleBMA282Native6")' >/dev/null; then
        cp -- "$input" "$output" || return $?
        printf 'null\n'; return
    fi
    dependency='{"from":"com.apple.driver.AppleEmbeddedGyro","to":"com.project5c.AppleBMA282Native6","version":"1.0.0d1"}'
    printf '%s' "$meta"|jq -e '
      [._PrelinkInfoDictionary[]|select(.CFBundleIdentifier=="com.apple.driver.AppleEmbeddedGyro")] as $gyro |
      [._PrelinkInfoDictionary[]|select(.CFBundleIdentifier=="com.project5c.AppleBMA282Native6")] as $bma |
      ($gyro|length)==1 and ($bma|length)==1 and $bma[0].CFBundleVersion=="1.0.0d1" and
      $gyro[0]._PrelinkExecutableSourceAddr==2156797952 and $bma[0]._PrelinkExecutableSourceAddr==2161504256' >/dev/null || {
        p5_fail 'Unsupported gyro/BMA adapter layout'; return 2;
    }
    p5_native kext-extract "$temp/kernel" com.apple.driver.AppleEmbeddedGyro "$temp/gyro" || return $?
    [ "$(p5_native hex-range "$temp/gyro" 0x2710 6)" = 7bf028b400bf ] || {
        p5_fail 'Gyro adapter branch differs'; return 2;
    }
    if printf '%s' "$meta"|jq -e 'any(._PrelinkInfoDictionary[];.CFBundleIdentifier=="com.apple.driver.AppleEmbeddedGyro" and .OSBundleLibraries["com.project5c.AppleBMA282Native6"]=="1.0.0d1")' >/dev/null; then
        cp -- "$input" "$output" || return $?
        printf '%s\n' "$dependency"; return
    fi
    printf '%s' "$meta"|jq -e 'all(._PrelinkInfoDictionary[]|select(.CFBundleIdentifier=="com.apple.driver.AppleEmbeddedGyro");.OSBundleLibraries|has("com.project5c.AppleBMA282Native6")|not)' >/dev/null || {
        p5_fail 'Conflicting gyro/BMA dependency version'; return 2;
    }
    # Require the existing, final, single-section PRELINK_INFO segment.
    command=$(p5_native locate "$temp/kernel" 010000007c0000005f5f5052454c494e4b5f494e464f000000) || return $?
    [ "$(p5_restore_kernel_u32 "$temp/kernel" "$((command+48))")" = 1 ] || return 2
    offset=$(p5_restore_kernel_u32 "$temp/kernel" "$((command+32))") || return $?
    size=$(p5_restore_kernel_u32 "$temp/kernel" "$((command+36))") || return $?
    section=$(p5_restore_kernel_u32 "$temp/kernel" "$((command+96))") || return $?
    [ "$section" = "$offset" ] && [ "$size" = "$(p5_restore_kernel_u32 "$temp/kernel" "$((command+92))")" ] || return 2
    capacity=$(($(p5_size "$temp/kernel")-offset))
    [ "$capacity" -ge "$size" ] && [ "$capacity" -le "$(p5_restore_kernel_u32 "$temp/kernel" "$((command+28))")" ] || return 2
    [ "$(dd if="$temp/kernel" bs=1 skip="$((offset+size))" 2>/dev/null|tr -d '\000'|wc -c)" -eq 0 ] || {
        p5_fail 'Kernel has nonzero data after prelink metadata'; return 2;
    }
    p5_native macho-section "$temp/kernel" __PRELINK_INFO __info "$temp/original.xml" || return $?
    tr -d '\000' < "$temp/original.xml" | LC_ALL=C awk '
      BEGIN { RS="\034"; ORS="" }
      { anchor="<key>CFBundleIdentifier</key><string>com.apple.driver.AppleEmbeddedGyro</string>";
        start=index($0,anchor); if(!start || index(substr($0,start+length(anchor)),anchor))exit 2;
        tail=substr($0,start+length(anchor)); marker="<key>OSBundleLibraries</key><dict>";
        pos=index(tail,marker); nextbundle=index(tail,"<key>CFBundleIdentifier</key>");
        if(!pos || (nextbundle && pos>nextbundle))exit 2;
        cut=start+length(anchor)-1+pos+length(marker)-1;
        printf "%s<key>com.project5c.AppleBMA282Native6</key><string>1.0.0d1</string>%s",substr($0,1,cut),substr($0,cut+1);
      }' > "$temp/updated.xml" || return $?
    printf '\0' >> "$temp/updated.xml" || return $?
    used=$(p5_size "$temp/updated.xml")
    [ "$used" -le "$capacity" ] || { p5_fail 'No room for sensor loading dependency'; return 2; }
    head -c "$offset" "$temp/kernel" > "$temp/updated" || return $?
    cat "$temp/updated.xml" >> "$temp/updated" || return $?
    dd if=/dev/zero bs=1 count="$((capacity-used))" 2>/dev/null >> "$temp/updated" || return $?
    hex=$(printf '%08x' "$used"|sed -E 's/(..)(..)(..)(..)/\4\3\2\1/')
    p5_native edit "$temp/updated" "$temp/header" "$((command+36))" "$hex" || return $?
    p5_native edit "$temp/header" "$temp/patched" "$((command+92))" "$hex" || return $?
    printf '%s' "$meta"|jq -S '(._PrelinkInfoDictionary[]|select(.CFBundleIdentifier=="com.apple.driver.AppleEmbeddedGyro")|.OSBundleLibraries["com.project5c.AppleBMA282Native6"])="1.0.0d1"' > "$temp/expected.json" || return $?
    p5_native prelink "$temp/patched"|jq -S . > "$temp/actual.json" || return $?
    cmp -s "$temp/expected.json" "$temp/actual.json" || { p5_fail 'Unexpected sensor metadata change'; return 2; }
    p5_native img3-data "$input" "$temp/template" || return $?
    p5_native lzss-pack "$temp/patched" "$temp/template" "$temp/compressed" || return $?
    p5_native img3-wrap "$input" "$temp/compressed" "$temp/result" plaintext || return $?
    p5_unpack_kernel "$temp/result" "$temp/readback" || return $?
    cmp -s "$temp/patched" "$temp/readback" || return 2
    mv -- "$temp/result" "$output" || return $?
    printf '%s\n' "$dependency"
}

# Apply a patch to the standalone core or one linked driver, never a full cache.
p5_kernel_patch() {
    local input=$1 directory=$2 stage=$3 profile=$4 output=$5 rules row sha patch wanted
    rules=''
    if [ -f "$directory/patches.tsv" ]; then
        rules=$(awk -F '\t' -v stage="$stage" -v profile="$profile" '$1==stage && ($2=="*" || $2==profile)' "$directory/patches.tsv") || return $?
    fi
    if [ -z "$rules" ]; then cp -- "$input" "$output"; return $?; fi
    sha=$(p5_sha "$input") || return $?
    row=$(printf '%s\n' "$rules" | awk -F '\t' -v sha="$sha" '$3==sha {print; n++} END {if(n!=1)exit 2}') || {
        p5_fail "Unsupported $stage input for ${directory##*/}"; return 2;
    }
    IFS=$'\t' read -r stage profile sha patch wanted <<< "$row"
    patch=$(p5_relative "$directory" "$patch") || return $?
    p5_native apply "$input" "$patch" "$output" || return $?
    [ "$(p5_sha "$output")" = "$wanted" ] || { p5_fail "Driver patch output differs: $directory"; return 2; }
}
p5_kernel_config() {
    local directory=$1 name=$2 profile=$3 board=$4 candidate
    for candidate in "$name-$profile-$board.plist" "$name-$profile.plist" "$name.plist"; do
        if [ -f "$directory/$candidate" ]; then printf '%s\n' "$directory/$candidate"; return; fi
    done
    printf '%s\n' '-'
}
p5_kernel_build() {
    local input=$1 output=$2 model=$3 profile=$4 jailbreak=$5 board temp name id directory code info personality deps layout
    p5_temp || return $?
    temp=$(mktemp -d "$P5_TMP/kernel.XXXXXX") || return $?
    board=$(p5_target "$model"|jq -r '.HardwareModel|ascii_downcase|.[0:3]') || return $?
    p5_log "Rebuild kernelcache from core and drivers: $board / $profile / jailbreak=$jailbreak"
    p5_native kernel-core "$input" "$temp/core.original" || return $?
    p5_kernel_patch "$temp/core.original" "$P5_ROOT/kernel/core" port "$profile" "$temp/core.ported" || return $?
    if [ "$jailbreak" = yes ]; then p5_kernel_patch "$temp/core.ported" "$P5_ROOT/kernel/core" jailbreak "$profile" "$temp/core" || return $?
    else cp -- "$temp/core.ported" "$temp/core" || return $?; fi
    : > "$temp/drivers.tsv"
    while IFS=$'\t' read -r name id; do
        case "$name" in ''|'#'*) continue ;; esac
        directory=$(p5_relative "$P5_ROOT/kernel/drivers" "$name") || return $?
        info=$(p5_kernel_config "$directory" Info "$profile" "$board") || return $?
        personality=$(p5_kernel_config "$directory" personality "$profile" "$board") || return $?
        deps=$(p5_kernel_config "$directory" deps "$profile" "$board") || return $?
        layout=$(p5_kernel_config "$directory" layout "$profile" "$board") || return $?
        code='-'
        if [ -f "$directory/patches.tsv" ]; then
            if [ "$layout" != '-' ]; then : > "$temp/$name.original"
            else p5_native kext-extract "$input" "$id" "$temp/$name.original" || return $?; fi
            p5_kernel_patch "$temp/$name.original" "$directory" port "$profile" "$temp/$name.ported" || return $?
            if [ "$jailbreak" = yes ]; then p5_kernel_patch "$temp/$name.ported" "$directory" jailbreak "$profile" "$temp/$name" || return $?
            else cp -- "$temp/$name.ported" "$temp/$name" || return $?; fi
            code="$temp/$name"
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$code" "$info" "$personality" "$deps" "$layout" >> "$temp/drivers.tsv" || return $?
    done < "$P5_ROOT/kernel/drivers.tsv"
    p5_native kernel-build "$input" "$temp/core" "$temp/drivers.tsv" "$P5_ROOT/kernel/kexts.list" "$output"
}
