#!/usr/bin/env bash
# Device-driven restore and tethered boot. Compatible with macOS Bash 3.2.
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
LIB="$ROOT/tools/lib"
VERSION=6.1.3
ACTIVATION=hacktivate
JAILBREAK=yes
PROFILE=native6-wifi-candidate
# EXTRAS=baseband  # Disabled by default until modem resources are needed.
EXTRAS=
WIFI_FIRMWARE_DIR=
BASEBAND_FIRMWARE=
BASEBAND_SOURCE=
BASEBAND_QUERY=
# BASEBAND_DISABLED=no
BASEBAND_DISABLED=auto
WORK="$ROOT/runtime"
WORK_EXPLICIT=no
BOOT_WORK=
HOST_ARCH=$(uname -m)
if [ "$HOST_ARCH" = aarch64 ]; then HOST_ARCH=arm64; fi
if [ "$(uname -s)" = Darwin ]; then
    HOST_TOOLS="$ROOT/tools/bin/macos"
else
    HOST_TOOLS="$ROOT/tools/bin/linux/$HOST_ARCH"
fi
EXECUTE=no
ERASE=no
ROOTFS=
RAMDISK=
TEMPLATE=
IBEC=
DONOR_INPUTS=
SOURCE_IPSW=
DOWNLOAD=no
KEYS=
progress() { printf '[%s] [STEP] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >&2; }
fail() { printf 'Error: %s\n' "$*" >&2; return 2; }
usage() {
    cat <<'EOF'
iPhone 5c iOS 6 Tool
Usage: ./tool.sh [menu|prepare|flash|boot] [options]
  --version 6.1.3|6.1.4        Prepare/flash; default: 6.1.3 (613/614 also accepted)
  --activation hacktivate|none Default: hacktivate
  --jailbreak yes|no          Default: yes
  --profile NAME              native6-wifi-candidate (default, both models) or native6-validated
  --extras gps,baseband        Additional runtime patches; none enabled by default
  --wifi-firmware-dir PATH     Model-matched 43342a0 donor directory; packaged files used by default
  --baseband-firmware PATH     Optional personalized Mav7 ZIP override
  --baseband-query PATH        Optional device-bound query plist for offline parameter input
  --baseband                   Enable CommCenter patches and prepare modem firmware resources
  --no-baseband                Disable CommCenter patches and modem firmware resources
  --work PATH                 Original inputs and generated bundle/session
  --tools-dir PATH            Native host tools, including device detection
  --source-ipsw PATH          iPhone 5 iOS 6.1.3 / 6.1.4 source IPSW
  --download                  Download and verify the source IPSW from Apple
  --keys PATH                 Optional offline override; otherwise fetched from AppleWiki
  --rootfs-hfs PATH --ramdisk-hfs PATH --ramdisk-template PATH --ibec-raw PATH
                             Optional pre-extracted image inputs
  --donor-inputs PATH         Optional pre-extracted matching donor directory
  --execute                   Perform USB operations; otherwise preview
  --erase                     Required with --execute for flash
Model and ECID are read from the connected device. No device, no menu.
Baseband transfer is disabled. No baseband selection menu is shown.
No normal iOS boot is required. Enter DFU for the ordinary restore boot.
EOF
}
COMMAND=menu
if [ "$#" -gt 0 ]; then
    case "$1" in --*|-h) ;; *) COMMAND=$1; shift ;; esac
fi
while [ "$#" -gt 0 ]; do
    case "$1" in
        --download) DOWNLOAD=yes; shift; continue ;;
        --execute) EXECUTE=yes; shift; continue ;;
        --erase) ERASE=yes; shift; continue ;;
        --baseband) BASEBAND_DISABLED=no; shift; continue ;;
        --no-baseband) BASEBAND_DISABLED=yes; shift; continue ;;
        --help|-h) usage; exit 0 ;;
    esac
    [ "$#" -ge 2 ] || { fail "Missing value for $1"; exit 2; }
    case "$1" in
        --version) VERSION=$2 ;; --activation) ACTIVATION=$2 ;; --jailbreak) JAILBREAK=$2 ;;
        --work) WORK=$2; WORK_EXPLICIT=yes; BOOT_WORK=$2 ;; --tools-dir) HOST_TOOLS=$2 ;;
        --rootfs-hfs) ROOTFS=$2 ;; --ramdisk-hfs) RAMDISK=$2 ;;
        --ramdisk-template) TEMPLATE=$2 ;; --ibec-raw) IBEC=$2 ;;
        --donor-inputs) DONOR_INPUTS=$2 ;; --keys) KEYS=$2 ;;
        --source-ipsw) SOURCE_IPSW=$2 ;;
        --profile) PROFILE=$2 ;; --extras) EXTRAS=$2 ;;
        --wifi-firmware-dir) WIFI_FIRMWARE_DIR=$2 ;; --baseband-firmware) BASEBAND_FIRMWARE=$2 ;;
        --baseband-query) BASEBAND_QUERY=$2 ;;
        *) fail "Unknown option: $1"; exit 2 ;;
    esac
    shift 2
done
validate() {
    if [ "$DOWNLOAD" = yes ] && [ -n "$SOURCE_IPSW" ]; then fail "Choose either --source-ipsw or --download"; return 2; fi
    case "$VERSION" in 613) VERSION=6.1.3 ;; 614) VERSION=6.1.4 ;; 6.1.3|6.1.4) ;; *) fail 'Only iOS 6.1.3 and 6.1.4 are supported'; return 2 ;; esac
    case "$ACTIVATION" in hacktivate|none) ;; *) fail 'Activation must be hacktivate or none'; return 2 ;; esac
    case "$JAILBREAK" in yes|no) ;; *) fail 'Jailbreak must be yes or no'; return 2 ;; esac
    case "$PROFILE" in native6-validated|native6-wifi-candidate) ;; *) fail 'Unknown patch profile'; return 2 ;; esac
    if [ "$BASEBAND_DISABLED" = auto ]; then
        BASEBAND_DISABLED=yes
        case ",$EXTRAS," in *,baseband,*) BASEBAND_DISABLED=no ;; esac
        [ -z "$BASEBAND_FIRMWARE$BASEBAND_QUERY" ] || BASEBAND_DISABLED=no
    fi
    if [ "$BASEBAND_DISABLED" = yes ]; then
        if [ -n "$BASEBAND_FIRMWARE" ] || [ -n "$BASEBAND_QUERY" ]; then
            fail '--no-baseband conflicts with baseband firmware/query inputs'; return 2
        fi
        EXTRAS=${EXTRAS//baseband/}; EXTRAS=${EXTRAS#,}; EXTRAS=${EXTRAS%,}
    else
        case ",$EXTRAS," in *,baseband,*) ;; *) EXTRAS=${EXTRAS:+$EXTRAS,}baseband ;; esac
    fi
    EXTRAS=$(bash "$LIB/selection.sh" --normalize-extras "$EXTRAS") || return $?
    if [ "$PROFILE" = native6-validated ] && [ -n "$WIFI_FIRMWARE_DIR" ]; then
        fail '--wifi-firmware-dir requires --profile native6-wifi-candidate'; return 2
    fi
}
detect_device() {
    local identity next_model next_ecid next_mode
    progress "Detect connected device"
    identity=$(bash "$LIB/device.sh" --tools-dir "$HOST_TOOLS") || return $?
    IFS=$'\t' read -r next_model next_ecid next_mode <<< "$identity"
    if [ -n "${ECID:-}" ] && [ "$ECID" != "$next_ecid" ]; then
        fail "The connected device changed. Restart for the new device."; return 2
    fi
    MODEL=$next_model; ECID=$next_ecid; MODE=$next_mode
    progress "Device: $MODEL | ECID: $ECID | Mode: $MODE"
}
check_version() {
    local args=(--version "$VERSION" --model "$MODEL" --ecid "$ECID" --activation "$ACTIVATION" --jailbreak "$JAILBREAK" --profile "$PROFILE" --extras "$EXTRAS")
    if [ -n "$WIFI_FIRMWARE_DIR" ]; then args+=(--wifi-firmware-dir "$WIFI_FIRMWARE_DIR"); fi
    if [ -n "$BASEBAND_FIRMWARE" ]; then args+=(--baseband-firmware "$BASEBAND_FIRMWARE"); fi
    if [ -n "$BASEBAND_SOURCE" ]; then args+=(--baseband-source "$BASEBAND_SOURCE"); fi
    bash "$LIB/selection.sh" ${args[@]+"${args[@]}"} "$@" >/dev/null
}
ensure_tools() {
    progress "Check restore host tools: $HOST_TOOLS"
    local name missing=no
    local exploit=a6meowing
    if [ "$(uname -s)" = Darwin ]; then
        if [ "$(uname -m)" = arm64 ]; then exploit=ipwnder; else exploit=x86_64/ipwnder32; fi
    fi
    for name in irecovery "$exploit" gaster hfsplus xpwntool iBoot32Patcher dmg idevicerestore; do
        if [ ! -x "$HOST_TOOLS/$name" ]; then missing=yes; fi
    done
    if [ "$missing" = yes ]; then
        bash "$LIB/tools.sh" setup --out "$HOST_TOOLS" || return $?
    fi
    bash "$LIB/tools.sh" check --out "$HOST_TOOLS" --scope restore >/dev/null || return $?
}
build_bundle() {
    check_version --inputs "$WORK/inputs" --identity-only || return $?
    local build_args=(--model "$MODEL" --profile "$PROFILE" --extras "$EXTRAS" --inputs "$WORK/inputs" --tools-dir "$HOST_TOOLS" --out "$WORK/bundle")
    if [ -n "$DONOR_INPUTS" ]; then build_args+=(--donor-inputs "$DONOR_INPUTS"); fi
    if [ -n "$KEYS" ]; then build_args+=(--keys "$KEYS");
    elif [ -f "$WORK/firmware/keys.json" ]; then build_args+=(--keys "$WORK/firmware/keys.json"); fi
    bash "$LIB/patchctl.sh" build ${build_args[@]+"${build_args[@]}"} || return $?
}
resolve_work() {
    if [ "$WORK_EXPLICIT" = no ]; then
        WORK="$ROOT/runtime/firmware/$MODEL/$VERSION-$ACTIVATION-$JAILBREAK"
        if [ "$PROFILE" != native6-validated ]; then WORK="$WORK-$PROFILE"; fi
        if [ -n "$EXTRAS" ]; then WORK="$WORK-${EXTRAS//,/-}"; fi
        if [ "$BASEBAND_DISABLED" = no ]; then WORK="$WORK-native-baseband-$ECID"; fi
    fi
}
prepare_firmware() {
    # Derived image paths stay scoped to this operation when menu choices change.
    local ROOTFS="$ROOTFS" RAMDISK="$RAMDISK" TEMPLATE="$TEMPLATE" IBEC="$IBEC" DONOR_INPUTS="$DONOR_INPUTS"
    local BASEBAND_FIRMWARE="$BASEBAND_FIRMWARE"
    local BASEBAND_SOURCE="$BASEBAND_SOURCE"
    validate || return $?
    resolve_work
    progress "Prepare firmware: $MODEL / iOS $VERSION | profile: $PROFILE | extras: ${EXTRAS:-none}"
    progress "Workspace: $WORK"
    if [ -f "$WORK/session/restore.json" ]; then progress "Reuse existing session after identity and integrity checks"; fi
    if [ "$PROFILE" = native6-wifi-candidate ] && [ -z "$WIFI_FIRMWARE_DIR" ]; then
        WIFI_FIRMWARE_DIR="$ROOT/donor/$MODEL/wifi/43342a0"
    fi
    if [ "$MODEL" = iPhone5,3 ]; then
        case ",$EXTRAS," in *,gps,*) fail 'GPS runtime currently requires iPhone5,4 / N49'; return 2 ;; esac
    fi
    if [ "$BASEBAND_DISABLED" = no ] && [ -z "$BASEBAND_FIRMWARE" ] && [ -f "$WORK/baseband/Mav7personalized.zip" ]; then
        BASEBAND_FIRMWARE="$WORK/baseband/Mav7personalized.zip"
        (source "$LIB/baseband.sh"; p5_baseband_receipt "$BASEBAND_FIRMWARE" "$MODEL" "$ECID" >/dev/null) || return $?
    fi
    if [ "$BASEBAND_DISABLED" = no ] && [ -d "$WORK/baseband-source" ]; then BASEBAND_SOURCE="$WORK/baseband-source"; fi
    if [ "$BASEBAND_DISABLED" = no ] && [ -f "$WORK/session/restore.json" ]; then
        jq -e ' .restore_options.UpdateBaseband==false ' "$WORK/session/restore.json" >/dev/null || return $?
    fi
    if [ ! -f "$WORK/session/restore.json" ] && [ ! -f "$WORK/inputs/SystemVersion.plist" ]; then
        if [ "$DOWNLOAD" = yes ]; then
            SOURCE_IPSW=$(bash "$LIB/download.sh" --version "$VERSION" --out "$ROOT/runtime/downloads") || return $?
            DOWNLOAD=no
        fi
    fi
    if [ ! -f "$WORK/session/restore.json" ]; then
        if [ ! -f "$WORK/inputs/SystemVersion.plist" ] && [ -n "$SOURCE_IPSW" ]; then
            ensure_tools || return $?
            local extract_args=(--source-ipsw "$SOURCE_IPSW" --tools-dir "$HOST_TOOLS" --work "$WORK" --model "$MODEL" --version "$VERSION")
            if [ -n "$KEYS" ]; then extract_args+=(--keys "$KEYS"); fi
            bash "$LIB/inputs.sh" ${extract_args[@]+"${extract_args[@]}"} || return $?
        fi
        if [ -f "$WORK/firmware/source-rootfs.hfs" ]; then
            ROOTFS="$WORK/firmware/source-rootfs.hfs"
            RAMDISK="$WORK/firmware/restore-ramdisk.hfs"
            TEMPLATE="$WORK/firmware/restore-ramdisk.img3"
            IBEC="$WORK/firmware/donor-ibec.bin"
            if [ "$MODEL" = iPhone5,3 ] && [ -d "$WORK/firmware/n48-inputs" ]; then
                DONOR_INPUTS="$WORK/firmware/n48-inputs"
            fi
        fi
        [ -n "$ROOTFS" ] && [ -n "$RAMDISK" ] && [ -n "$TEMPLATE" ] && [ -n "$IBEC" ] || { fail 'Supply the original restore image inputs; see --help'; return 2; }
        ensure_tools || return $?
        if [ ! -f "$WORK/bundle/build.json" ]; then
            build_bundle || return $?
        else
            progress "Reuse existing patch bundle: $WORK/bundle (will verify before use)"
        fi
        if [ "$BASEBAND_DISABLED" = no ]; then
            progress "Prepare model-matched baseband resources (modem transfer disabled)"
            local bb_args=(--model "$MODEL" --ecid "$ECID" --mode "$MODE" --bundle "$WORK/bundle" --tools-dir "$HOST_TOOLS" --out "$WORK/baseband" --cache "$ROOT/runtime/downloads/baseband")
            if [ -n "$BASEBAND_QUERY" ] && [ -z "$BASEBAND_FIRMWARE" ]; then
                BASEBAND_FIRMWARE=$(bash "$LIB/baseband.sh" ${bb_args[@]+"${bb_args[@]}"} --query "$BASEBAND_QUERY") || return $?
            fi
            bb_args=(--model "$MODEL" --ecid "$ECID" --mode "$MODE" --bundle "$WORK/bundle" --tools-dir "$HOST_TOOLS" --out "$WORK/baseband-source" --cache "$ROOT/runtime/downloads/baseband" --native-source)
            BASEBAND_SOURCE=$(bash "$LIB/baseband.sh" ${bb_args[@]+"${bb_args[@]}"}) || return $?
        fi
        check_version --policy-only || return $?
        check_version --bundle "$WORK/bundle" || return $?
        bash "$LIB/patchctl.sh" verify --bundle "$WORK/bundle" >/dev/null || return $?
        local restore_args=(prepare --retry-incomplete --activation "$ACTIVATION" --jailbreak "$JAILBREAK" --bundle "$WORK/bundle" --rootfs-hfs "$ROOTFS" --ramdisk-hfs "$RAMDISK" --ramdisk-template "$TEMPLATE" --ibec-raw "$IBEC" --out "$WORK/session" --tools-dir "$HOST_TOOLS" --dmg-tool "$HOST_TOOLS/dmg")
        if [ -n "$WIFI_FIRMWARE_DIR" ]; then restore_args+=(--wifi-firmware-dir "$WIFI_FIRMWARE_DIR"); fi
        if [ -n "$BASEBAND_FIRMWARE" ]; then restore_args+=(--baseband-firmware "$BASEBAND_FIRMWARE" --baseband-ecid "$ECID"); fi
        if [ -n "$BASEBAND_SOURCE" ]; then restore_args+=(--baseband-source "$BASEBAND_SOURCE" --baseband-ecid "$ECID"); fi
        bash "$LIB/restore6.sh" ${restore_args[@]+"${restore_args[@]}"} || return $?
        check_version --session "$WORK/session" --record || return $?
    fi
    progress "Verify session, selected patches and device boot record"
    check_version --session "$WORK/session" || return $?
    check_version --bundle "$WORK/bundle" || return $?
    bash "$LIB/restore6.sh" verify --session "$WORK/session" >/dev/null || return $?
    bash "$LIB/bootstate.sh" check --state "$ROOT/runtime/devices" --work "$WORK" --model "$MODEL" --ecid "$ECID" >/dev/null || return $?
    printf 'Firmware identity checked: %s / %s\n' "$MODEL" "$VERSION"
    printf '\nFirmware ready: %s/session\nModel: %s | iOS: %s | Activation: %s | Jailbreak: %s\n' "$WORK" "$MODEL" "$VERSION" "$ACTIVATION" "$JAILBREAK"
    printf 'Patch profile: %s | Runtime extras: %s\n' "$PROFILE" "${EXTRAS:-none}"
}
flash_device() {
    if [ "$EXECUTE" = yes ] && [ "$ERASE" != yes ]; then fail 'Flash requires --execute --erase'; return 2; fi
    prepare_firmware || return $?
    if [ "$EXECUTE" = yes ] && [ "$MODE" != DFU ]; then fail "Enter physical DFU before flashing"; return 2; fi
    ensure_tools || return $?
    local args=(--session "$WORK/session" --ecid "$ECID" --tools-dir "$HOST_TOOLS" --idevicerestore "$HOST_TOOLS/idevicerestore")
    if [ "$EXECUTE" = yes ]; then args+=(--execute --erase); fi
    # The install backend boots the restore ramdisk, waits for restored, and flashes.
    bash "$LIB/restore6.sh" install ${args[@]+"${args[@]}"} || return $?
    if [ "$EXECUTE" = yes ]; then
        bash "$LIB/bootstate.sh" record --state "$ROOT/runtime/devices" --work "$WORK" --model "$MODEL" --ecid "$ECID" || return $?
        MODE='Awaiting manual DFU'
        printf '\nFlash complete. Keep the USB cable connected and manually enter physical DFU.\n'
        printf 'Then select Tethered boot in the menu, or run ./tool.sh boot --execute.\n'
    fi
}
tethered_boot() {
    validate || return $?
    if [ "$EXECUTE" = yes ] && [ "$MODE" != DFU ]; then fail "Enter physical DFU before tethered boot"; return 2; fi
    [ "$ERASE" = no ] || { fail '--erase applies only to flash'; return 2; }
    local boot_work
    local state_args=(resolve --state "$ROOT/runtime/devices" --model "$MODEL" --ecid "$ECID")
    if [ -n "$BOOT_WORK" ]; then state_args+=(--work "$BOOT_WORK"); fi
    boot_work=$(bash "$LIB/bootstate.sh" ${state_args[@]+"${state_args[@]}"}) || return $?
    WORK=$boot_work
    printf 'Tethered boot workspace: %s\n' "$WORK"
    (source "$LIB/hosttools.sh"; p5_require_boot "$HOST_TOOLS") 2>/dev/null || {
        bash "$LIB/tools.sh" fetch --out "$HOST_TOOLS" || return $?
    }
    bash "$LIB/tools.sh" check --out "$HOST_TOOLS" --scope boot >/dev/null || return $?
    local args=(--bundle "$WORK/bundle" --ecid "$ECID" --tools-dir "$HOST_TOOLS")
    if [ "$EXECUTE" = yes ]; then args+=(--execute); fi
    # Boot the installed OS from its matching patch bundle, without a restore ramdisk.
    bash "$LIB/patchctl.sh" ramboot ${args[@]+"${args[@]}"}
}
ask() { printf '%s [%s]: ' "$1" "$2"; IFS= read -r REPLY || return 1; REPLY=${REPLY:-$2}; }
ready_for_usb() {
    if [ "$MODE" != DFU ]; then
        printf "Enter physical DFU on the connected iPhone 5c.\n"
        ask "Press Enter when ready" READY || return $?
    fi
    detect_device || return $?
    [ "$MODE" = DFU ] || { fail "Physical DFU was not detected"; return 2; }
}
select_option() {
    CHOICE=$(bash "$LIB/menu.sh" "$@") || return $?
}
firmware_choices() {
    local version_default=0 activation_default=0 jailbreak_default=0 source_default=0 picker_status=0
    if [ "$VERSION" = 6.1.4 ]; then version_default=1; fi
    if [ "$ACTIVATION" = none ]; then activation_default=1; fi
    if [ "$JAILBREAK" = no ]; then jailbreak_default=1; fi
    if [ "$DOWNLOAD" = yes ]; then source_default=1; fi
    select_option --default "$version_default" 'Target iOS' 'iOS 6.1.3' 'iOS 6.1.4' 'Back' || return 1
    case "$CHOICE" in 0) VERSION=6.1.3 ;; 1) VERSION=6.1.4 ;; *) return 1 ;; esac
    select_option --default "$activation_default" 'Activation' 'Hacktivate' 'Keep stock activation' 'Back' || return 1
    case "$CHOICE" in 0) ACTIVATION=hacktivate ;; 1) ACTIVATION=none ;; *) return 1 ;; esac
    select_option --default "$jailbreak_default" 'Jailbreak' 'Install Cydia and Substrate' 'No jailbreak' 'Back' || return 1
    case "$CHOICE" in 0) JAILBREAK=yes ;; 1) JAILBREAK=no ;; *) return 1 ;; esac
    printf 'CommCenter runtime patches: %s\n' "$([ "$BASEBAND_DISABLED" = yes ] && printf disabled || printf enabled)"
    printf 'Baseband transfer: disabled\n'
    resolve_work
    printf 'Workspace: %s\n' "$WORK"
    while [ -f "$WORK/session/restore.json" ] || [ -f "$WORK/firmware/source-rootfs.hfs" ]; do
        select_option 'Prepared firmware exists' 'Reuse this workspace' 'Choose another workspace' 'Back' || return 1
        case "$CHOICE" in
            0) return 0 ;;
            1) picker_status=0
               REPLY=$(bash "$LIB/filepicker.sh" --directory -- "$WORK") || picker_status=$?
               case "$picker_status" in
                   0) ;;
                   3) ask 'Workspace path (empty cancels; spaces are supported)' '' || continue
                      [ -n "$REPLY" ] || continue
                      case "$REPLY" in
                          \"*\") REPLY=${REPLY#\"}; REPLY=${REPLY%\"} ;;
                          \'*\') REPLY=${REPLY#\'}; REPLY=${REPLY%\'} ;;
                      esac
                      [ -n "$REPLY" ] || continue
                      REPLY=$(bash "$LIB/filepicker.sh" --directory --path="$REPLY") || continue ;;
                   130) continue ;;
                   *) continue ;;
               esac
               WORK=$REPLY; WORK_EXPLICIT=yes
               printf 'Workspace: %s\n' "$WORK" ;;
            *) return 1 ;;
        esac
    done
    if [ -n "$ROOTFS" ] && [ -n "$RAMDISK" ] && [ -n "$TEMPLATE" ] && [ -n "$IBEC" ]; then return 0; fi
    while :; do
        select_option --default "$source_default" 'Original iPhone 5 source firmware' 'Select a local IPSW' 'Download from Apple' 'Back' || return 1
        case "$CHOICE" in
            0) picker_status=0
               REPLY=$(bash "$LIB/filepicker.sh" -- "$SOURCE_IPSW") || picker_status=$?
               case "$picker_status" in
                   0) ;;
                   3) ask 'Local IPSW path (spaces are supported)' "$SOURCE_IPSW" || continue
                      [ -n "$REPLY" ] || continue
                      case "$REPLY" in
                          \"*\") REPLY=${REPLY#\"}; REPLY=${REPLY%\"} ;;
                          \'*\') REPLY=${REPLY#\'}; REPLY=${REPLY%\'} ;;
                      esac ;;
                   130) continue ;;
                   *) return 1 ;;
               esac
               SOURCE_IPSW=$REPLY; DOWNLOAD=no ;;
            1) SOURCE_IPSW=; DOWNLOAD=yes ;;
            *) return 1 ;;
        esac
        return 0
    done
}
menu() {
    [ -t 0 ] || { fail 'Interactive menu requires a terminal'; return 2; }
    while :; do
        printf '\n=== iPhone 5c iOS 6 Tool ===\nConnected: %s | ECID: %s | Mode: %s\n' "$MODEL" "$ECID" "$MODE"
        select_option 'Choose an operation' 'Generate firmware / Flash iOS 6' 'Tethered boot' 'Exit' || return 0
        case "$CHOICE" in
            2) return 0 ;;
            0)
                if ! firmware_choices; then continue; fi
                if ! prepare_firmware; then continue; fi
                select_option 'Firmware is ready' 'Flash now (erase system and data)' 'Return to menu' || continue
                if [ "$CHOICE" = 0 ]; then
                    ask 'Type ERASE to erase system and data' CANCEL || return 0
                    if [ "$REPLY" = ERASE ]; then
                        if ready_for_usb; then
                            EXECUTE=yes; ERASE=yes
                            if flash_device; then
                                EXECUTE=no; ERASE=no
                                # Wait for an explicit operation before looking for the device again.
                                continue
                            fi
                            EXECUTE=no; ERASE=no
                        fi
                    fi
                fi ;;
            1)
                if ready_for_usb; then
                    EXECUTE=yes; ERASE=no; tethered_boot || :; EXECUTE=no
                fi ;;
        esac
        detect_device || return $?
    done
}

case "$COMMAND" in
    help|--help|-h) usage; exit 0 ;;
    menu|prepare|flash|boot) ;;
    *) fail "Unknown command: $COMMAND"; exit 2 ;;
esac
if [ "$COMMAND" = prepare ] && { [ "$EXECUTE" = yes ] || [ "$ERASE" = yes ]; }; then
    fail 'prepare only generates firmware; use flash --execute --erase to install it'; exit 2
fi
if [ "$ERASE" = yes ] && [ "$EXECUTE" = no ]; then
    fail '--erase requires --execute'; exit 2
fi
# Keep stdin attached to the terminal for menus and sudo. Only output is teed.
mkdir -p "$ROOT/runtime/logs"
RUN_LOG=$(mktemp "$ROOT/runtime/logs/$(date '+%Y%m%d-%H%M%S')-$COMMAND.log.XXXXXX")
exec 3>&1 4>&2
exec > >(tee -a "$RUN_LOG") 2>&1
LOG_TEE_PID=$!
finish_log() {
    local status=$?
    trap - EXIT
    if [ "$status" -eq 0 ]; then
        progress "Command finished: $COMMAND (exit $status). Log: $RUN_LOG"
    else
        printf '[%s] [FAIL] Command: %s | exit: %s | log: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$COMMAND" "$status" "$RUN_LOG" >&2
    fi
    exec 1>&3 2>&4
    wait "$LOG_TEE_PID" || printf 'Warning: log writer failed: %s\n' "$RUN_LOG" >&2
    exec 3>&- 4>&-
    exit "$status"
}
trap finish_log EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
progress "Start $COMMAND. Run log: $RUN_LOG"
progress "Check host dependencies"
if [ "$(uname -s)" = Darwin ]; then export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"; fi
bash "$ROOT/tools/dependencies.sh" runtime "$HOST_TOOLS" "$COMMAND"
for required in jq openssl curl bsdtar unzip zip; do command -v "$required" >/dev/null || { fail "Missing dependency: $required"; exit 2; }; done
(source "$LIB/common.sh"; p5_native version >/dev/null)
validate
if [ ! -x "$HOST_TOOLS/irecovery" ]; then
    bash "$LIB/tools.sh" detection --out "$HOST_TOOLS"
fi
bash "$LIB/tools.sh" check --out "$HOST_TOOLS" --scope detection >/dev/null
detect_device
case "$COMMAND" in menu) menu ;; prepare) prepare_firmware ;; flash) flash_device ;; boot) tethered_boot ;; esac
