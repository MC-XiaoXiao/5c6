#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/usb.sh"
p5_args "$@"; p5_required tools-dir
BINS=$(p5_get tools-dir)
p5_temp; : > "$P5_TMP/devices.jsonl"; RECOVERY_FOUND=no
RECOVERY_ECIDS=$(p5_recovery_ecids) || { p5_fail 'Cannot read iPhone 5c recovery/DFU USB identity'; exit 2; }
COUNT=$(printf '%s\n' "$RECOVERY_ECIDS" | awk 'NF{n++} END{print n+0}')
[ "$COUNT" -le 1 ] || { p5_fail 'Multiple iPhone 5c devices connected; connect only one'; exit 2; }
while IFS= read -r ecid; do
    [ -n "$ecid" ] || continue
    fields=$(p5_recovery_fields "$BINS" 15 "$ecid") || { p5_fail 'iPhone 5c recovery/DFU identity unavailable; check USB permissions'; exit 2; }
    actual=$(printf '%s' "$fields"|jq -r '.ECID//"0"'); chip=$(printf '%s' "$fields"|jq -r '.CPID//"0"'); board=$(printf '%s' "$fields"|jq -r '.BDID//"0"'); mode=$(printf '%s' "$fields"|jq -r '.MODE//empty'); model=
    if [ "$((chip))" = "$((0x8950))" ]; then case "$((board))" in 10) model=iPhone5,3 ;; 14) model=iPhone5,4 ;; esac; fi
    [ -n "$model" ] && [ "$((actual))" = "$((ecid))" ] && [ "$((actual))" -gt 0 ] || { p5_fail 'iPhone 5c recovery/DFU identity changed'; exit 2; }
    case "$mode" in DFU|Recovery*) ;; *) p5_fail 'Unrecognized iPhone 5c recovery/DFU mode'; exit 2 ;; esac
    jq -nc --argjson ecid "$((ecid))" --arg model "$model" --arg mode "$mode" '{ecid:$ecid,model:$model,mode:$mode}' >> "$P5_TMP/devices.jsonl"; RECOVERY_FOUND=yes
done < <(printf '%s\n' "$RECOVERY_ECIDS")
if [ -x "$BINS/ideviceinfo" ] || command -v ideviceinfo >/dev/null; then
    # Linux may stop usbmuxd when only a DFU/recovery device is connected.
    # libirecovery uses USB directly, so that identity remains usable. Still
    # enumerate normal devices when possible to reject mixed-mode duplicates.
    if NORMAL_DEVICES=$(p5_normal_devices 2> "$P5_TMP/normal-devices.err"); then
        :
    elif [ "$RECOVERY_FOUND" = yes ]; then
        NORMAL_DEVICES=
        P5_LOG_LEVEL=WARN p5_log 'Normal-mode device list unavailable; using recovery/DFU USB identity. Connect only one iPhone 5c.'
    else
        cat "$P5_TMP/normal-devices.err" >&2
        p5_fail 'Normal-mode enumeration failed; check usbmuxd. For DFU/recovery, check irecovery -q and USB permissions.'
        exit 2
    fi
    while IFS= read -r udid; do
        [ -n "$udid" ] || continue
        info=ideviceinfo; [ ! -x "$BINS/ideviceinfo" ] || info="$BINS/ideviceinfo"
        # Simple lockdown queries may expose DeviceClass while withholding
        # ProductType. Skip iPads/iPods/etc. before querying model or pairing.
        device_class=$(p5_run_timeout 15 "$BINS" "$info" -s -u "$udid" -k DeviceClass 2>/dev/null) || device_class=
        case "$device_class" in iPhone|'') ;; *) continue ;; esac
        model=$(p5_run_timeout 15 "$BINS" "$info" -s -u "$udid" -k ProductType 2> "$P5_TMP/normal-model.err") || model=
        if [ -z "$model" ] && [ "$device_class" = iPhone ]; then
            # A normal-mode iPhone can require its trusted session to expose
            # ProductType. Do not turn an empty simple query into a lost device.
            model=$(p5_run_timeout 15 "$BINS" "$info" -u "$udid" -k ProductType 2>> "$P5_TMP/normal-model.err") || model=
        fi
        if [ -z "$model" ]; then
            cat "$P5_TMP/normal-model.err" >&2
            p5_fail 'Normal-mode iPhone identity unavailable; unlock/trust it or re-enter physical DFU'
            exit 2
        fi
        case "$model" in iPhone5,3|iPhone5,4) ;; *) continue ;; esac
        ecid=$(p5_run_timeout 15 "$BINS" "$info" -u "$udid" -k UniqueChipID) || { p5_fail 'iPhone 5c identity unavailable; unlock/trust or enter DFU'; exit 2; }
        [[ "$ecid" =~ ^[0-9]+$ ]] && [ "$ecid" -gt 0 ] || { p5_fail 'iPhone 5c identity unavailable; unlock/trust or enter DFU'; exit 2; }
        jq -nc --argjson ecid "$ecid" --arg model "$model" '{ecid:$ecid,model:$model,mode:"Normal"}' >> "$P5_TMP/devices.jsonl"
    done < <(printf '%s\n' "$NORMAL_DEVICES")
fi
devices=$(jq -sc 'unique_by(.ecid)' "$P5_TMP/devices.jsonl")
case "$(printf '%s' "$devices"|jq length)" in
    0) p5_fail 'No iPhone 5c detected; connect an iPhone5,3 or iPhone5,4'; exit 2 ;;
    1) identity=$(printf '%s' "$devices"|jq -c '.[0]') ;;
    *) p5_fail 'Multiple iPhone 5c devices connected; connect only one'; exit 2 ;;
esac
ecidd=$(printf '%s' "$identity"|jq -r .ecid); printf -v ecidh '0x%x' "$ecidd"
printf '%s\t%s\t%s\n' "$(printf '%s' "$identity"|jq -r .model)" "$ecidh" "$(printf '%s' "$identity"|jq -r .mode)"
