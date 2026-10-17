#!/usr/bin/env bash
# Install only missing host packages; never run device tools or change USB state.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/host.sh"
MODE=${1:-runtime}
TOOLS=${2:-}
OPERATION=${3:-menu}
case "$MODE" in runtime|build) ;; *) printf 'Unknown dependency mode: %s\n' "$MODE" >&2; exit 2 ;; esac
packages=()
manager=
case "$(uname -s)" in
    Darwin)
        p5_macos_env
        if [ -z "${P5_BREW:-}" ]; then
            printf 'Install Homebrew from https://brew.sh, then run the tool again.\n' >&2
            exit 2
        fi
        manager=brew
        packages=(jq libarchive libplist openssl@3 curl libxml2 zlib pkgconf coreutils flock libimobiledevice)
        if ! xcrun --find clang >/dev/null 2>&1 || ! xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
            printf 'Install Apple Command Line Tools with: xcode-select --install\n' >&2; exit 2
        fi
        if [ "$MODE" = build ]; then
            packages+=(git cmake autoconf automake libtool pkgconf openssl@3 zlib libimobiledevice libirecovery libimobiledevice-glue libtatsu libusbmuxd libplist libzip curl libpng bzip2)
        fi ;;
    Linux)
        distro=; family=
        if [ -r /etc/os-release ]; then
            distro=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '\"')
            family=$(sed -n 's/^ID_LIKE=//p' /etc/os-release | tr -d '\"')
        fi
        case " $distro $family " in
            *' debian '*|*' ubuntu '*)
                manager=apt
                packages=(jq libarchive-tools unzip zip libusb-1.0-0 openssl zlib1g curl libbz2-1.0 liblzma5 libzstd1 usbmuxd build-essential pkg-config libplist-dev libzip-dev libssl-dev libcurl4-openssl-dev zlib1g-dev libxml2-dev coreutils util-linux xxd libplist-utils libimobiledevice-utils bsdiff)
                if [ "$MODE" = build ]; then
                    packages+=(git cmake build-essential autoconf automake libtool pkg-config libssl-dev zlib1g-dev libimobiledevice-dev libirecovery-dev libimobiledevice-glue-dev libtatsu-dev libusbmuxd-dev libplist-dev libzip-dev libcurl4-openssl-dev libpng-dev libbz2-dev)
                fi ;;
            *' arch '*|*' manjaro '*)
                manager=pacman
                packages=(jq libarchive unzip zip libusb openssl zlib curl libzip bzip2 xz zstd usbmuxd gcc make pkgconf libplist libxml2 coreutils util-linux tinyxxd libimobiledevice bsdiff)
                if [ "$MODE" = build ]; then
                    packages+=(git cmake gcc make autoconf automake libtool pkgconf libimobiledevice libirecovery libimobiledevice-glue libtatsu libusbmuxd libplist libpng)
                fi ;;
            *' fedora '*|*' rhel '*|*' centos '*)
                manager=dnf
                packages=(jq bsdtar unzip zip libusb1 openssl-libs zlib libcurl libzip bzip2-libs xz-libs libzstd usbmuxd gcc make pkgconf-pkg-config libplist-devel libzip-devel openssl-devel libcurl-devel zlib-devel libxml2-devel coreutils util-linux vim-common libimobiledevice-utils bsdiff)
                if [ "$MODE" = build ]; then
                    packages+=(git cmake gcc make autoconf automake libtool pkgconf-pkg-config openssl-devel zlib-devel libimobiledevice-devel libirecovery-devel libimobiledevice-glue-devel libtatsu-devel libusbmuxd-devel libplist-devel libzip-devel libcurl-devel libpng-devel bzip2-devel)
                fi ;;
            *' opensuse '*|*' opensuse-tumbleweed '*|*' opensuse-leap '*|*' suse '*)
                manager=zypper
                packages=(jq bsdtar unzip zip libusb-1_0-0 libopenssl3 libz1 libcurl4 libzip5 libbz2-1 liblzma5 libzstd1 usbmuxd gcc make pkg-config libplist-devel libzip-devel libopenssl-devel libcurl-devel zlib-devel libxml2-devel coreutils util-linux vim-small libplist-tools imobiledevice-tools bsdiff)
                if [ "$MODE" = build ]; then
                    packages+=(git cmake gcc make autoconf automake libtool pkg-config libopenssl-devel zlib-devel libimobiledevice-devel libirecovery-devel libimobiledevice-glue-devel libtatsu-devel libusbmuxd-devel libplist-devel libzip-devel libcurl-devel libpng16-devel libbz2-devel)
                fi ;;
            *) printf 'Automatic dependency installation does not support this distribution (%s). See README.md for requirements.\n' "$distro" >&2; exit 2 ;;
        esac
        if [ "$OPERATION" = menu ] && [ "$MODE" = runtime ] && { [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; }; then
            if ! command -v kdialog >/dev/null 2>&1 && ! command -v zenity >/dev/null 2>&1; then
                case "${XDG_CURRENT_DESKTOP:-}" in *KDE*|*kde*) packages+=(kdialog) ;; *) packages+=(zenity) ;; esac
            fi
        fi ;;
    *) printf 'Host dependencies require Linux or macOS.\n' >&2; exit 2 ;;
esac
installed() {
    case "$manager" in
        apt) [ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || :)" = 'install ok installed' ] ;;
        pacman) pacman -T "$1" >/dev/null 2>&1 ;;
        dnf|zypper) rpm -q "$1" >/dev/null 2>&1 ;;
        brew)
            local versions minimum=
            versions=$("$P5_BREW" list --versions "$1" 2>/dev/null || :)
            [ -n "$versions" ] || return 1
            [ "$1" != libplist ] || minimum=2.3.0
            # Match the pinned idevicerestore configure.ac requirements when
            # building it; an installed older formula still needs an upgrade.
            if [ "$MODE" = build ]; then
                case "$1" in
                    libplist) minimum=2.6.0 ;; libirecovery) minimum=1.3.0 ;;
                    libimobiledevice) minimum=1.4.0 ;; libusbmuxd) minimum=2.0.2 ;;
                    libimobiledevice-glue) minimum=1.3.0 ;; libtatsu) minimum=1.0.4 ;;
                    libzip) minimum=1.0.0 ;; curl) minimum=7.0.0 ;;
                esac
            fi
            if [ -n "$minimum" ]; then
                printf '%s\n' "$versions" | awk -v minimum="$minimum" '
                  BEGIN{split(minimum,m,".")}
                  {for(i=2;i<=NF;i++){split($i,v,/[^0-9]+/); good=1;
                    for(j=1;j<=3;j++){if(v[j]+0>m[j]+0)break; if(v[j]+0<m[j]+0){good=0;break}}
                    if(good)ok=1}}
                  END{exit !ok}'
            fi ;;
    esac
}
missing=()
checked=' '
for package in ${packages[@]+"${packages[@]}"}; do
    case "$checked" in *" $package "*) continue ;; esac
    checked="$checked$package "
    installed "$package" || missing+=("$package")
done
[ -n "${missing[0]+yes}" ] || exit 0
printf 'Missing or outdated %s dependencies (%s):' "$MODE" "$manager" >&2
printf ' %s' ${missing[@]+"${missing[@]}"} >&2
printf '\n' >&2
if [ "${TOOL_DEPS:-install}" = check ]; then exit 2; fi
privilege=()
if [ "$manager" != brew ] && [ "$(id -u)" != 0 ]; then
    if ! command -v sudo >/dev/null 2>&1; then
        printf 'Install sudo or ask your administrator to install the listed packages.\n' >&2; exit 2
    fi
    privilege=(sudo)
    if [ ! -t 0 ]; then privilege+=(--non-interactive); fi
fi
case "$manager" in
    apt)
        ${privilege[@]+"${privilege[@]}"} apt-get update
        ${privilege[@]+"${privilege[@]}"} apt-get install -y ${missing[@]+"${missing[@]}"} ;;
    pacman) ${privilege[@]+"${privilege[@]}"} pacman -S --needed --noconfirm ${missing[@]+"${missing[@]}"} ;;
    dnf) ${privilege[@]+"${privilege[@]}"} dnf install -y ${missing[@]+"${missing[@]}"} ;;
    zypper) ${privilege[@]+"${privilege[@]}"} zypper --non-interactive install ${missing[@]+"${missing[@]}"} ;;
    brew)
        fresh=(); upgrade=()
        for package in ${missing[@]+"${missing[@]}"}; do
            if [ -n "$("$P5_BREW" list --versions "$package" 2>/dev/null || :)" ]; then upgrade+=("$package"); else fresh+=("$package"); fi
        done
        [ -z "${fresh[0]+yes}" ] || "$P5_BREW" install ${fresh[@]+"${fresh[@]}"}
        [ -z "${upgrade[0]+yes}" ] || "$P5_BREW" upgrade ${upgrade[@]+"${upgrade[@]}"}
        for package in ${missing[@]+"${missing[@]}"}; do
            installed "$package" || { printf 'Dependency remains unavailable: %s\n' "$package" >&2; exit 2; }
        done ;;
esac
