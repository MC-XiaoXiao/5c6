#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/usb.sh"
p5_args "$@"; p5_required tools-dir
BINS=$(p5_get tools-dir)
# Keep discovery evidence alongside other tool diagnostics, including failures
# before the first upload. p5_temp reuses this directory without deleting it.
DIAGNOSTICS=${P5_TOOL_LOG_DIR:-"$P5_ROOT/runtime/logs/tools"}
mkdir -p "$DIAGNOSTICS"
P5_TMP=$(mktemp -d "$DIAGNOSTICS/device.XXXXXX")
trap 'status=$?; if [ "$status" -ne 0 ]; then p5_log "Device detection diagnostics: $P5_TMP"; fi' EXIT
printf 'Host: %s\nTools: %s\n' "$(uname -s)" "$BINS" > "$P5_TMP/detection.log"
p5_detect_query() {
    local record status=0
    record=$(mktemp "$P5_TMP/query.XXXXXX") || return $?
    p5_run_timeout "$@" > "$record" 2> "$record.err" || status=$?
    { printf 'Query:'; printf ' %q' "$@"; printf '\nExit: %s; output: %s\n' "$status" "${record##*/}"; } >> "$P5_TMP/detection.log"
    cat "$record"
    cat "$record.err" >&2
    return "$status"
}
: > "$P5_TMP/devices.jsonl"; RECOVERY_FOUND=no
RECOVERY_ECIDS=$(p5_recovery_ecids 2> "$P5_TMP/recovery-enumeration.err") || { cat "$P5_TMP/recovery-enumeration.err" >&2; p5_fail 'Cannot read iPhone 5c recovery/DFU USB identity'; exit 2; }
printf '%s\n' "$RECOVERY_ECIDS" > "$P5_TMP/recovery-ecids.txt"
COUNT=$(printf '%s\n' "$RECOVERY_ECIDS" | awk 'NF{n++} END{print n+0}')
[ "$COUNT" -le 1 ] || { p5_fail 'Multiple iPhone 5c devices connected; connect only one'; exit 2; }
while IFS= read -r ecid; do
    [ -n "$ecid" ] || continue
    fields=$(p5_recovery_fields "$BINS" 15 "$ecid" "$P5_TMP/recovery-$ecid.txt" 2> "$P5_TMP/recovery-$ecid.err") || { cat "$P5_TMP/recovery-$ecid.err" >&2; p5_fail 'iPhone 5c recovery/DFU identity unavailable; check USB permissions'; exit 2; }
    printf '%s\n' "$fields" > "$P5_TMP/recovery-$ecid.json"
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
    if p5_normal_devices "$BINS" > "$P5_TMP/normal-devices.txt" 2> "$P5_TMP/normal-devices.err"; then
        printf 'Normal enumeration exit: 0\n' >> "$P5_TMP/detection.log"
        NORMAL_DEVICES=$(cat "$P5_TMP/normal-devices.txt")
    else
        printf 'Normal enumeration exit: %s\n' "$?" >> "$P5_TMP/detection.log"
        if [ "$RECOVERY_FOUND" = yes ]; then
            NORMAL_DEVICES=
            P5_LOG_LEVEL=WARN p5_log 'Normal-mode device list unavailable; using recovery/DFU USB identity. Connect only one iPhone 5c.'
        else
            cat "$P5_TMP/normal-devices.err" >&2
            p5_fail 'Normal-mode enumeration failed; check usbmuxd. For DFU/recovery, check irecovery -q and USB permissions.'
            exit 2
        fi
    fi
    while IFS= read -r udid; do
        [ -n "$udid" ] || continue
        info=ideviceinfo; [ ! -x "$BINS/ideviceinfo" ] || info="$BINS/ideviceinfo"
        # Simple lockdown queries may expose DeviceClass while withholding
        # ProductType. Skip iPads/iPods/etc. before querying model or pairing.
        device_class=$(p5_detect_query 15 "$BINS" "$info" -s -u "$udid" -k DeviceClass 2>/dev/null) || device_class=
        case "$device_class" in iPhone|'') ;; *) continue ;; esac
        model=$(p5_detect_query 15 "$BINS" "$info" -s -u "$udid" -k ProductType 2> "$P5_TMP/normal-model.err") || model=
        if [ -z "$model" ]; then
            # A normal-mode iPhone can require its trusted session to expose
            # ProductType. Do not turn an empty simple query into a lost device.
            model=$(p5_detect_query 15 "$BINS" "$info" -u "$udid" -k ProductType 2>> "$P5_TMP/normal-model.err") || model=
        fi
        if [ -z "$model" ]; then
            cat "$P5_TMP/normal-model.err" >&2
            p5_fail 'Normal-mode iPhone identity unavailable; unlock/trust it or re-enter physical DFU'
            exit 2
        fi
        printf 'Normal device %s: class=%s model=%s\n' "$udid" "$device_class" "$model" >> "$P5_TMP/detection.log"
        case "$model" in
            iPhone5,3|iPhone5,4) ;;
            iPhone5,1|iPhone5,2)
                P5_LOG_LEVEL=WARN p5_log "Device reports $model (iPhone 5). If this is a 5c running a ported OS, enter physical DFU to read its hardware identity."
                continue ;;
            *) continue ;;
        esac
        ecid=$(p5_detect_query 15 "$BINS" "$info" -u "$udid" -k UniqueChipID) || { p5_fail 'iPhone 5c identity unavailable; unlock/trust or enter DFU'; exit 2; }
        [[ "$ecid" =~ ^[0-9]+$ ]] && [ "$ecid" -gt 0 ] || { p5_fail 'iPhone 5c identity unavailable; unlock/trust or enter DFU'; exit 2; }
        jq -nc --argjson ecid "$ecid" --arg model "$model" '{ecid:$ecid,model:$model,mode:"Normal"}' >> "$P5_TMP/devices.jsonl"
    done < <(printf '%s\n' "$NORMAL_DEVICES")
elif [ "$RECOVERY_FOUND" != yes ]; then
    p5_fail 'Missing ideviceinfo; install libimobiledevice or check --tools-dir and PATH'
    exit 2
else
    P5_LOG_LEVEL=WARN p5_log 'ideviceinfo unavailable; using recovery/DFU USB identity. Connect only one iPhone 5c.'
fi
devices=$(jq -sc 'unique_by(.ecid)' "$P5_TMP/devices.jsonl")
case "$(printf '%s' "$devices"|jq length)" in
    0)
        probe_readable=no
        if [ "$(uname -s)" = Darwin ]; then
            # Read-only diagnostic, never a substitute for the complete device
            # inventory: an unscoped -q can return just the first of many phones.
            probe_status=0
            probe=$(p5_recovery_fields "$BINS" 5 '' "$P5_TMP/recovery-probe.txt" 2> "$P5_TMP/recovery-probe.err") || probe_status=$?
            printf 'Recovery probe result: %s\n' "$probe_status" >> "$P5_TMP/detection.log"
            if [ "$probe_status" = 0 ]; then
                probe_readable=yes
                printf '%s\n' "$probe" > "$P5_TMP/recovery-probe.json"
                P5_LOG_LEVEL=WARN p5_log "irecovery can read a USB device, but the inventory did not identify a unique iPhone 5c: $(printf '%s' "$probe" | jq -c '{CPID,BDID,ECID,MODE}')"
            else
                p5_log "Read-only irecovery probe failed (exit $probe_status); see recovery-probe.txt and recovery-probe.err in the detection diagnostics"
                cat "$P5_TMP/recovery-probe.err" >&2
            fi
        fi
        if [ "$probe_readable" = yes ]; then
            p5_fail 'USB device is readable, but the registry inventory could not verify an iPhone 5c; inspect the detection diagnostics' || :
        else
            p5_fail 'No iPhone 5c detected; connect an iPhone5,3 or iPhone5,4' || :
        fi
        p5_log 'Check the USB data cable/port. In normal mode, unlock and trust this computer; for a ported OS or tethered boot, enter physical DFU (black screen) and retry.'
        exit 2 ;;
    1) identity=$(printf '%s' "$devices"|jq -c '.[0]') ;;
    *) p5_fail 'Multiple iPhone 5c devices connected; connect only one'; exit 2 ;;
esac
ecidd=$(printf '%s' "$identity"|jq -r .ecid); printf -v ecidh '0x%x' "$ecidd"
printf '%s\t%s\t%s\n' "$(printf '%s' "$identity"|jq -r .model)" "$ecidh" "$(printf '%s' "$identity"|jq -r .mode)"
