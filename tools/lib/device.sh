#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/hosttools.sh"
p5_args "$@"; p5_required tools-dir
BINS=$(p5_get tools-dir)
COUNT=0
if [ "$(uname -s)" = Linux ]; then
    for node in /sys/bus/usb/devices/*; do
        [ -r "$node/idVendor" ] && [ -r "$node/idProduct" ] || continue
        vendor=$(cat "$node/idVendor"); product=$(cat "$node/idProduct")
        if [ "$vendor" = 05ac ]; then case "$product" in 1227|1280|1281|1282|1283) COUNT=$((COUNT+1)) ;; esac; fi
    done
elif [ "$(uname -s)" = Darwin ]; then
    p5_temp; /usr/sbin/ioreg -p IOUSB -a > "$P5_TMP/usb.plist"
    COUNT=$(p5_plist "$P5_TMP/usb.plist" | jq '[..|objects|select(.idVendor?==1452 and (.idProduct? as $p|[4647,4736,4737,4738,4739]|index($p)))]|length')
fi
[ "$COUNT" -le 1 ] || { p5_fail 'Multiple recovery/DFU devices connected'; exit 2; }
p5_temp; : > "$P5_TMP/devices.jsonl"; RECOVERY_FOUND=no
if [ -x "$BINS/irecovery" ]; then
    if ! fields=$(p5_recovery_fields "$BINS" 2>/dev/null); then fields='{}'; fi
    ecid=$(printf '%s' "$fields"|jq -r '.ECID//empty')
    if [ -n "$ecid" ]; then
        chip=$(printf '%s' "$fields"|jq -r '.CPID//"0"'); board=$(printf '%s' "$fields"|jq -r '.BDID//"0"'); model=
        if [ "$((chip))" = "$((0x8950))" ]; then case "$((board))" in 10) model=iPhone5,3 ;; 14) model=iPhone5,4 ;; esac; fi
        jq -nc --argjson ecid "$((ecid))" --arg model "$model" --arg mode "$(printf '%s' "$fields"|jq -r '.MODE//"Recovery"')" '{ecid:$ecid,model:$model,mode:$mode}' >> "$P5_TMP/devices.jsonl"; RECOVERY_FOUND=yes
    fi
fi
if [ -x "$BINS/ideviceinfo" ] || command -v ideviceinfo >/dev/null; then
    NORMAL_DEVICES=$(p5_native mux-list)
    while IFS= read -r udid; do
        [ -n "$udid" ] || continue
        info=ideviceinfo; [ ! -x "$BINS/ideviceinfo" ] || info="$BINS/ideviceinfo"
        model=$(p5_run_timeout 15 "$BINS" "$info" -u "$udid" -k ProductType); ecid=$(p5_run_timeout 15 "$BINS" "$info" -u "$udid" -k UniqueChipID)
        [ -n "$model" ] && [[ "$ecid" =~ ^[0-9]+$ ]] || { p5_fail 'Normal device identity unavailable; unlock/trust or enter DFU'; exit 2; }
        jq -nc --argjson ecid "$ecid" --arg model "$model" '{ecid:$ecid,model:$model,mode:"Normal"}' >> "$P5_TMP/devices.jsonl"
    done < <(printf '%s' "$NORMAL_DEVICES" | jq -r '.[].Properties.SerialNumber')
fi
[ "$COUNT" = 0 ] || [ "$RECOVERY_FOUND" = yes ] || { p5_fail 'Recovery/DFU identity unavailable'; exit 2; }
identity=$(jq -sc 'unique_by(.ecid)|if length==1 and (.[0].model=="iPhone5,3" or .[0].model=="iPhone5,4") and .[0].ecid>0 then .[0] else error("Connect exactly one supported iPhone 5c") end' "$P5_TMP/devices.jsonl")
ecidd=$(printf '%s' "$identity"|jq -r .ecid); printf -v ecidh '0x%x' "$ecidd"
printf '%s\t%s\t%s\n' "$(printf '%s' "$identity"|jq -r .model)" "$ecidh" "$(printf '%s' "$identity"|jq -r .mode)"
