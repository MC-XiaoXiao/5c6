#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
p5_args "$@"
DIRECTORY=$(p5_get directory no); BASEBAND=$(p5_get baseband no); INITIAL=${ARGS[0]:-}
if [ -n "$(p5_get path)" ]; then
    [ "$DIRECTORY" = yes ] || { p5_fail '--path requires --directory'; exit 2; }
    PATH_VALUE=$(p5_abs "$(p5_get path)")
    [ ! -e "$PATH_VALUE" ] || [ -d "$PATH_VALUE" ] || { p5_fail 'Workspace must be a directory'; exit 2; }
    printf '%s\n' "$PATH_VALUE"; exit 0
fi
if { [ "$(uname -s)" = Linux ] && [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; } || { [ "$(uname -s)" = Darwin ] && [ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ]; }; then exit 3; fi
FOLDER=${INITIAL:-"$HOME/Downloads"}; [ ! -f "$FOLDER" ] || FOLDER=${FOLDER%/*}; [ -d "$FOLDER" ] || FOLDER=$HOME
FOLDER=$(p5_abs "$FOLDER")/
# KDialog expects patterns|label; Zenity expects label|patterns.
TITLE='Select original iPhone 5 IPSW'; LABEL='iOS firmware (*.ipsw)'; PATTERNS='*.ipsw *.IPSW'; EXT=ipsw
[ "$BASEBAND" = no ] || { TITLE='Select personalized Mav7 ZIP'; LABEL='Personalized Mav7 (*.zip)'; PATTERNS='*.zip *.ZIP'; EXT=zip; }
[ "$DIRECTORY" = no ] || TITLE='Select workspace folder'
STATUS=0
if [ "$(uname -s)" = Darwin ]; then
    RESULT=$(osascript - "$FOLDER" "$TITLE" "$DIRECTORY" <<'APPLESCRIPT'
on run argv
    try
        if item 3 of argv is "yes" then
            set chosen to choose folder with prompt (item 2 of argv) default location (POSIX file (item 1 of argv))
        else
            -- Validate the extension in Bash; "ipsw" can be treated as a legacy type code here.
            set chosen to choose file with prompt (item 2 of argv) default location (POSIX file (item 1 of argv))
        end if
        return POSIX path of chosen
    on error number -128
        return ""
    end try
end run
APPLESCRIPT
) || STATUS=$?
    # Cancellation returns an empty result; other AppleScript failures need the terminal fallback.
    case "$STATUS" in
        0|130) ;;
        *) printf '[WARN] macOS file picker failed; enter the path in the terminal.\n' >&2; exit 3 ;;
    esac
elif command -v kdialog >/dev/null && { [[ "${XDG_CURRENT_DESKTOP:-}" = *KDE* ]] || ! command -v zenity >/dev/null; }; then
    if [ "$DIRECTORY" = yes ]; then RESULT=$(kdialog --title "$TITLE" --getexistingdirectory "$FOLDER") || STATUS=$?;
    else RESULT=$(kdialog --title "$TITLE" --getopenfilename "$FOLDER" "$PATTERNS|$LABEL"$'\n''*|All files') || STATUS=$?; fi
elif command -v zenity >/dev/null; then
    DARGS=(--file-selection "--title=$TITLE" "--filename=$FOLDER")
    if [ "$DIRECTORY" = yes ]; then DARGS+=(--directory); else DARGS+=("--file-filter=$LABEL | $PATTERNS" '--file-filter=All files | *'); fi
    RESULT=$(zenity ${DARGS[@]+"${DARGS[@]}"}) || STATUS=$?
else p5_fail 'Install zenity or kdialog, or supply a path from the terminal'; exit 2; fi
case "$STATUS" in 0) [ -n "$RESULT" ] || exit 130 ;; 1|130) exit 130 ;; *) exit 2 ;; esac
if [ "$DIRECTORY" = yes ]; then [ -d "$RESULT" ] || exit 2;
else [ -f "$RESULT" ] && [ "$(printf '%s' "${RESULT##*.}" | tr '[:upper:]' '[:lower:]')" = "$EXT" ] || { p5_fail "Select an existing .$EXT file"; exit 2; }; fi
p5_abs "$RESULT"
