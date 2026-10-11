#!/usr/bin/env bash
# Install only missing host packages; never run device tools or change USB state.
set -euo pipefail
MODE=${1:-runtime}
TOOLS=${2:-}
OPERATION=${3:-menu}
case "$MODE" in runtime|build) ;; *) printf 'Unknown dependency mode: %s\n' "$MODE" >&2; exit 2 ;; esac
packages=()
manager=
case "$(uname -s)" in
    Darwin)
        export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
        if ! command -v brew >/dev/null 2>&1; then
            if [ "$MODE" = runtime ] && command -v python3 >/dev/null 2>&1; then exit 0; fi
            printf 'Install Homebrew from https://brew.sh, then run the tool again.\n' >&2
            exit 2
        fi
        manager=brew
        packages=(python)
        if [ "$MODE" = build ]; then
            if ! xcrun --find clang >/dev/null 2>&1; then
                printf 'Install Apple Command Line Tools with: xcode-select --install\n' >&2
                exit 2
            fi
            packages+=(git cmake autoconf automake libtool pkgconf openssl@3 zlib libimobiledevice libirecovery libimobiledevice-glue libtatsu libusbmuxd libplist libzip curl)
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
                packages=(python3 libusb-1.0-0 openssl zlib1g curl libbz2-1.0 liblzma5 libzstd1 usbmuxd)
                if [ "$MODE" = build ]; then
                    packages+=(git cmake build-essential autoconf automake libtool pkg-config libssl-dev zlib1g-dev libimobiledevice-dev libirecovery-dev libimobiledevice-glue-dev libtatsu-dev libusbmuxd-dev libplist-dev libzip-dev libcurl4-openssl-dev)
                fi ;;
            *' arch '*|*' manjaro '*)
                manager=pacman
                packages=(python libusb openssl zlib curl libzip bzip2 xz zstd usbmuxd)
                if [ "$MODE" = build ]; then
                    packages+=(git cmake gcc make autoconf automake libtool pkgconf libimobiledevice libirecovery libimobiledevice-glue libtatsu libusbmuxd libplist)
                fi ;;
            *' fedora '*|*' rhel '*|*' centos '*)
                manager=dnf
                packages=(python3 libusb1 openssl-libs zlib libcurl libzip bzip2-libs xz-libs libzstd usbmuxd)
                if [ "$MODE" = build ]; then
                    packages+=(git cmake gcc make autoconf automake libtool pkgconf-pkg-config openssl-devel zlib-devel libimobiledevice-devel libirecovery-devel libimobiledevice-glue-devel libtatsu-devel libusbmuxd-devel libplist-devel libzip-devel libcurl-devel)
                fi ;;
            *' opensuse '*|*' opensuse-tumbleweed '*|*' opensuse-leap '*|*' suse '*)
                manager=zypper
                packages=(python3 libusb-1_0-0 libopenssl3 libz1 libcurl4 libzip5 libbz2-1 liblzma5 libzstd1 usbmuxd)
                if [ "$MODE" = build ]; then
                    packages+=(git cmake gcc make autoconf automake libtool pkg-config libopenssl-devel zlib-devel libimobiledevice-devel libirecovery-devel libimobiledevice-glue-devel libtatsu-devel libusbmuxd-devel libplist-devel libzip-devel libcurl-devel)
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
        brew) [ -n "$(brew list --versions "$1" 2>/dev/null || :)" ] ;;
    esac
}
missing=()
for package in "${packages[@]}"; do
    installed "$package" || missing+=("$package")
done
[ ${#missing[@]} -gt 0 ] || exit 0
printf 'Missing %s dependencies (%s):' "$MODE" "$manager" >&2
printf ' %s' "${missing[@]}" >&2
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
        "${privilege[@]}" apt-get update
        "${privilege[@]}" apt-get install -y "${missing[@]}" ;;
    pacman) "${privilege[@]}" pacman -S --needed --noconfirm "${missing[@]}" ;;
    dnf) "${privilege[@]}" dnf install -y "${missing[@]}" ;;
    zypper) "${privilege[@]}" zypper --non-interactive install "${missing[@]}" ;;
    brew) brew install "${missing[@]}" ;;
esac
