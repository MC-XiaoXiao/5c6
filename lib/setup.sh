#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/usb.sh"
source "$P5_LIB/http.sh"
p5_fetch_locked() {
    local row=$1 destination=$2 url size sha mode
    url=$(printf '%s' "$row"|jq -r .url); size=$(printf '%s' "$row"|jq -r .bytes); sha=$(printf '%s' "$row"|jq -r .sha256)
    mode=$(printf '%s' "$row"|jq -r '.mode//420'); printf -v mode '%o' "$mode"
    if [ -f "$destination" ]; then p5_check_file "$destination" "$size" "$sha" || return $?; chmod "$mode" "$destination" || return $?; p5_log "Use cached ${destination##*/}"; return; fi
    [[ "$url" = https://* ]] || return 2
    [ ! -L "$destination" ] || return 2
    mkdir -p "$(dirname -- "$destination")"
    p5_log "Fetch ${destination##*/}"
    p5_http_fetch tool "Download ${destination##*/}" "$url" "$destination.part" "$size" --location --max-filesize "$size" >/dev/null || return $?
    p5_check_file "$destination.part" "$size" "$sha" || return $?
    chmod "$mode" "$destination.part" || return $?; mv -n -- "$destination.part" "$destination"
}
p5_check_host_tools() {
    local out=$1 scope=$2 version
    if [ "$scope" = detection ]; then p5_require_tools "$out" irecovery; return; fi
    p5_require_boot "$out"
    if [ "$scope" = restore ]; then
        p5_require_tools "$out" hfsplus xpwntool iBoot32Patcher dmg idevicerestore
        version=$(p5_run_timeout 15 "$out" idevicerestore --version) || return $?
        [[ "$version" = *native6-5c-no-baseband* || "$version" = *native6-5c-bb-native-v[12]* ]] || { p5_fail 'Use a Project5C patched restore host'; return 2; }
    fi
}
p5_upgrade_restore_host() {
    local out=$1 version='' build row
    if [ -x "$out/idevicerestore" ]; then version=$(p5_run_timeout 15 "$out" idevicerestore --version) || return $?; fi
    [[ "$version" != *native6-5c-bb-native-v2* ]] || return 0
    row=$(p5_source_tool idevicerestore) || return $?
    p5_fetch_locked "$row" "$out/sources/idevicerestore.tar.gz" || return $?
    mkdir -p "$out/build" || return $?
    build=$(mktemp -d "$out/build/native-baseband-host.XXXXXX") || return $?
    bash "$P5_ROOT/src/host/build-restore.sh" --source-archive "$out/sources/idevicerestore.tar.gz" --out "$build/host" || return $?
    [ ! -f "$out/idevicerestore" ] || cp -p -- "$out/idevicerestore" "$build/previous-idevicerestore" || return $?
    cp -- "$build/host/src/idevicerestore" "$out/idevicerestore.tmp.$$" || return $?
    chmod 755 "$out/idevicerestore.tmp.$$" || return $?
    mv -f -- "$out/idevicerestore.tmp.$$" "$out/idevicerestore" || return $?
    p5_log "Installed native BasebandData host; previous binary/build retained in $build"
}
p5_build_custom() {
    local out=$1 name row work="$1/build"
    if [ -x "$out/dmg" ] && [ -x "$out/idevicerestore" ]; then p5_check_host_tools "$out" restore; return; fi
    bash "$P5_ROOT/lib/deps.sh" build "$out" setup
    for name in xpwn idevicerestore; do row=$(p5_source_tool "$name"); p5_fetch_locked "$row" "$out/sources/$name.tar.gz"; done
    [ ! -e "$work/xpwn-source" ] || { p5_fail 'Incomplete source build retained; use a new tools directory'; return 2; }
    mkdir -p "$work/xpwn-source"
    bsdtar -xf "$out/sources/xpwn.tar.gz" -C "$work/xpwn-source" --strip-components 1 --no-same-owner
    (
        p5_build_env
        cd -- "$work/xpwn-source"
        git apply --check "$P5_ROOT/patches/host/xpwn.patch"; git apply "$P5_ROOT/patches/host/xpwn.patch"
        cmake -S "$work/xpwn-source" -B "$work/xpwn-build" -DCMAKE_POLICY_VERSION_MINIMUM=3.5
        cmake --build "$work/xpwn-build" --target dmg-bin -j2
        bash "$P5_ROOT/src/host/build-dmg.sh" --source "$work/xpwn-source" --build "$work/xpwn-build" --out "$work/explicit-zero-dmg"
        bash "$P5_ROOT/src/host/build-restore.sh" --source-archive "$out/sources/idevicerestore.tar.gz" --out "$work/restore-host"
    ) > "$work/build.log" 2>&1
    cp -- "$work/explicit-zero-dmg/dmg" "$out/dmg"; cp -- "$work/restore-host/src/idevicerestore" "$out/idevicerestore"; chmod 755 "$out/dmg" "$out/idevicerestore"
    # Git tracks builders and patches. No script-hash receipt is required.
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    COMMAND=${1:-help}; [ "$#" -eq 0 ] || shift; p5_args "$@"
    OUT=$(p5_abs "$(p5_get out "$P5_TOOLS")"); SCOPE=$(p5_get scope restore)
    case "$COMMAND" in
        restore-host) p5_upgrade_restore_host "$OUT" ;;
        check) p5_check_host_tools "$OUT" "$SCOPE" ;;
        setup|fetch|detection)
            PLATFORM=$(p5_get platform "$(if [ "$(uname -s)" = Darwin ]; then printf macos; else printf linux; fi)"); ARCH=$(p5_get arch "$P5_ARCH")
            ROWS=$(p5_tool_rows "$PLATFORM" "$ARCH")
            while IFS= read -r ROW; do
                PATH_NAME=$(printf '%s' "$ROW"|jq -r .path)
                if [ "$COMMAND" = detection ]; then case "$PATH_NAME" in irecovery|ideviceinfo|lib/*) ;; *) continue ;; esac; fi
                p5_fetch_locked "$ROW" "$(p5_relative "$OUT" "$PATH_NAME")"
            done < <(printf '%s\n' "$ROWS")
            if [ "$COMMAND" = setup ]; then p5_build_custom "$OUT"; fi ;;
        help|--help) printf 'Usage: setup.sh setup|fetch|detection|check [--out PATH] [--scope detection|boot|restore]\n'; exit 0 ;;
        *) p5_fail 'Unknown host tool operation'; exit 2 ;;
    esac
    if [ "$(p5_get json no)" = yes ]; then jq -n --arg scope "$SCOPE" --arg out "$OUT" '{passed:true,scope:$scope,tools_directory:$out,device_accessed:false}'; else p5_log "Host tools $COMMAND complete: $OUT"; fi
fi
