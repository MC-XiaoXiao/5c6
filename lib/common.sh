#!/usr/bin/env bash
# Shared Bash 3.2 utilities. No embedded interpreter or script self-hashes.
if [ "${P5_COMMON_LOADED:-no}" = yes ]; then return 0; fi
P5_COMMON_LOADED=yes
P5_LIB=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
P5_ROOT=$(CDPATH= cd -- "$P5_LIB/.." && pwd -P)
P5_ARCH=$(uname -m); [ "$P5_ARCH" != aarch64 ] || P5_ARCH=arm64
# uname reports x86_64 under Rosetta; select A6 tools for the physical Mac.
if [ "$(uname -s)" = Darwin ] && [ "$(sysctl -in hw.optional.arm64 2>/dev/null || :)" = 1 ]; then P5_ARCH=arm64; fi
if [ "$(uname -s)" = Darwin ]; then P5_TOOLS="$P5_ROOT/bin/macos"; else P5_TOOLS="$P5_ROOT/bin/linux/$P5_ARCH"; fi
P5_NATIVE=${P5_NATIVE:-"$P5_TOOLS/p5-native"}
p5_fail() { printf '[FAIL] %s\n' "$*" >&2; return 2; }
p5_log() { printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "${P5_LOG_LEVEL:-STEP}" "$*" >&2; }
p5_native() {
    local source rebuild=no
    [ -x "$P5_NATIVE" ] || rebuild=yes
    for source in "$P5_ROOT"/src/native/*.[ch] "$P5_ROOT/src/native/build.sh"; do [ ! "$source" -nt "$P5_NATIVE" ] || rebuild=yes; done
    if [ "$rebuild" = yes ]; then bash "$P5_ROOT/src/native/build.sh" "$P5_NATIVE" || return $?; fi
    "$P5_NATIVE" "$@"
}
p5_sha() { openssl dgst -sha256 -r "$1" | awk '{print $1}'; }
p5_size() { wc -c < "$1" | tr -d '[:space:]'; }
p5_receipt() { jq -n --arg sha "$(p5_sha "$1")" --argjson size "$(p5_size "$1")" '{size:$size,sha256:$sha}'; }
p5_check_file() {
    local file=$1 size=$2 sha=$3
    [ -f "$file" ] && [ "$(p5_size "$file")" = "$size" ] && [ "$(p5_sha "$file")" = "$sha" ] || { p5_fail "Input/output differs: $file"; return 2; }
}
p5_abs() {
    local path=$1 tail= part
    case "$path" in '~/'*) path="$HOME/${path#\~/}" ;; /*) ;; *) path="$PWD/$path" ;; esac
    while [ ! -e "$path" ]; do
        part=${path##*/}; tail="/$part$tail"; path=${path%/*}; [ -n "$path" ] || path=/
    done
    if [ -d "$path" ]; then path=$(CDPATH= cd -- "$path" && pwd -P); else part=${path##*/}; path=$(CDPATH= cd -- "${path%/*}" && pwd -P); tail="/$part$tail"; fi
    local parts=()
    IFS=/ read -r -a parts <<< "$tail"
    for part in ${parts[@]+"${parts[@]}"}; do
        case "$part" in ''|.) ;; ..) path=${path%/*}; [ -n "$path" ] || path=/ ;; *) path="${path%/}/$part"; if [ -d "$path" ]; then path=$(CDPATH= cd -- "$path" && pwd -P); fi ;; esac
    done
    printf '%s\n' "${path:-/}"
}
p5_relative() {
    case "$2" in ''|/*|..|../*|*/../*|*/..|./../*) p5_fail "Unsafe relative path: $2"; return 2 ;; esac
    local root path
    root=$(p5_abs "$1"); path=$(p5_abs "$1/$2")
    case "$path" in "$root"/*) ;; *) p5_fail "Path escapes directory: $2"; return 2 ;; esac
    [ ! -L "$1/$2" ] || { p5_fail "Symlink refused: $2"; return 2; }
    printf '%s\n' "$path"
}
p5_temp() {
    # Large firmware operations pass their workspace so --work selects the disk.
    if [ -z "${P5_TMP:-}" ]; then P5_TMP=$(mktemp -d "${1:-${TMPDIR:-/tmp}}/.project5c.XXXXXX") || return $?; trap 'rm -rf -- "$P5_TMP"' EXIT; fi
}
p5_output_temp() {
    local parent
    parent=$(dirname -- "$(p5_abs "$1")"); mkdir -p "$parent"
    p5_temp "$parent"
}
p5_plist() { p5_native plist-json "$1"; }
p5_write_plist() {
    p5_temp || return $?
    local input="$P5_TMP/plist-input.$RANDOM.json"
    cat > "$input" || return $?
    p5_native json-plist "$input" "$@" || return $?
    rm -f -- "$input"
}
p5_args() {
    ARGS=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --) shift; while [ "$#" -gt 0 ]; do ARGS+=("$1"); shift; done; break ;;
            --*=*) local key=${1%%=*} value=${1#*=}; key=${key#--}; shift ;;
            --*) local key=${1#--} value
                 case "$key" in json|execute|erase|native-source|identity-only|retry-incomplete|directory|baseband|help|boot-only|restore-debug) value=yes; shift ;;
                     *) [ "$#" -ge 2 ] || { p5_fail "Missing value: $1"; return 2; }; value=$2; shift 2 ;; esac ;;
            *) ARGS+=("$1"); shift; continue ;;
        esac
        case "$key" in *[!a-zA-Z0-9_-]*|'') p5_fail 'Invalid option name'; return 2 ;; esac
        key=${key//-/_}; printf -v "P5_ARG_$key" '%s' "$value"
    done
}
p5_get() { local name="P5_ARG_${1//-/_}"; printf '%s' "${!name:-${2:-}}"; }
p5_required() { local key; for key in "$@"; do [ -n "$(p5_get "$key")" ] || { p5_fail "--$key is required"; return 2; }; done; }
p5_tool_env() {
    local directory=$1
    if [ -d "$directory/lib" ]; then
        if [ "$(uname -s)" = Darwin ]; then export DYLD_LIBRARY_PATH="$directory/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}";
        else export LD_LIBRARY_PATH="$directory/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"; fi
    fi
}
p5_build_env() {
    unset LD_LIBRARY_PATH DYLD_LIBRARY_PATH
    if [ "$(uname -s)" = Darwin ]; then
        export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
        local formula prefix
        for formula in openssl@3 zlib curl libxml2 libarchive; do
            prefix=$(brew --prefix "$formula" 2>/dev/null || :)
            [ -z "$prefix" ] || { export PKG_CONFIG_PATH="$prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"; export CMAKE_PREFIX_PATH="$prefix${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"; }
        done
    fi
}
p5_run() {
    local bins=$1; shift
    (p5_tool_env "$bins"; if [ -x "$bins/$1" ]; then local exe="$bins/$1"; shift; "$exe" "$@"; else "$@"; fi)
}
p5_run_timeout() {
    local seconds=$1 bins=$2 exe=$3; shift 3
    [ ! -x "$bins/$exe" ] || exe="$bins/$exe"
    local variable=LD_LIBRARY_PATH library="$bins/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    if [ "$(uname -s)" = Darwin ]; then variable=DYLD_LIBRARY_PATH; library="$bins/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"; fi
    p5_native run-timeout "$seconds" env "$variable=$library" "$exe" "$@"
}
p5_run_live() {
    local seconds=$1 bins=$2 label=$3 exe=$4; shift 4
    [ ! -x "$bins/$exe" ] || exe="$bins/$exe"
    (p5_tool_env "$bins"; p5_native run-live "$seconds" "$label" "$exe" "$@")
}
p5_hfs_run() {
    # Directory, permission and readback operations are too frequent for step logs.
    # Keep tool diagnostics and show them only when an operation fails.
    local seconds=$1 bins=$2 image=$3 log status; shift 3
    p5_temp || return $?
    log=$(mktemp "$P5_TMP/hfs.XXXXXX") || return $?
    if p5_run_timeout "$seconds" "$bins" hfsplus "$image" "$@" > "$log" 2>&1; then
        rm -f -- "$log"
    else
        status=$?
        printf '[FAIL] HFS %s failed in %s (exit %s):' "${1:-operation}" "$image" "$status" >&2
        printf ' %s' "$@" >&2; printf '\n' >&2
        cat "$log" >&2
        rm -f -- "$log"
        return "$status"
    fi
}
p5_require_tools() { local bins=$1 name; shift; for name in "$@"; do [ -x "$bins/$name" ] || { p5_fail "Missing tool: $bins/$name"; return 2; }; done; }
p5_target() {
    case "$1" in iPhone5,3|N48AP|n48ap) printf '{"ProductType":"iPhone5,3","HardwareModel":"N48AP","board_id":10}\n' ;;
        iPhone5,4|N49AP|n49ap) printf '{"ProductType":"iPhone5,4","HardwareModel":"N49AP","board_id":14}\n' ;;
        *) p5_fail "Unsupported target: $1"; return 2 ;; esac
}
p5_components() {
    p5_target "$1" | jq '.HardwareModel|ascii_downcase as $board|$board[0:3] as $short|{
      ibss:("Firmware/dfu/iBSS."+$board+".RELEASE.dfu"),ibec:("Firmware/dfu/iBEC."+$board+".RELEASE.dfu"),
      devicetree:("Firmware/all_flash/all_flash."+$board+".production/DeviceTree."+$board+".img3"),
      kernel:("kernelcache.release."+$short),ramdisk:"RestoreRamDisk.dmg",rootfs:"RootFS.dmg"}'
}
p5_normalize_extras() {
    printf '%s\n' "$1" | jq -Rr 'split(",")|map(select(length>0))|unique|if all(.=="gps" or .=="baseband") then join(",") else error("Runtime extras must be gps/baseband") end'
}
p5_zip_member() { p5_native zip-extract "$1" "$2" "$3"; }
p5_finish() { if [ "$(p5_get json no)" = yes ]; then cat "$1"; else p5_log "${2:-Operation complete}"; fi; }
p5_json_update() { local file=$1; shift; jq "$@" "$file" > "$file.tmp" || return $?; mv -- "$file.tmp" "$file"; }

# A single row parser serves the pinned downloads; JSON stays in memory.
p5_tool_rows() {
    awk -F '\t' -v platform="$1" -v arch="$2" '$1==platform && $2==arch' "$P5_ROOT/resources/tools.tsv" |
      jq -Rnc '[inputs|split("\t")|{path:.[2],bytes:(.[3]|tonumber),sha256:.[4],mode:(.[5]|tonumber),url:.[6]}]|if length>0 then .[] else error("Unsupported host platform/architecture") end'
}
p5_source_tool() {
    p5_tool_rows source - | jq -ce --arg name "$1" 'select(.path==$name)'
}
