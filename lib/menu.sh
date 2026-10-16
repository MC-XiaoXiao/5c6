#!/usr/bin/env bash
set -euo pipefail
DEFAULT=0
if [ "${1:-}" = --default ]; then DEFAULT=$2; shift 2; fi
[ "$#" -ge 2 ] || { printf 'Usage: menu.sh [--default N] TITLE OPTIONS...\n' >&2; exit 2; }
TITLE=$1; shift; OPTIONS=("$@"); COUNT=${#OPTIONS[@]}
[[ "$DEFAULT" =~ ^[0-9]+$ ]] && [ "$DEFAULT" -lt "$COUNT" ] || exit 2
printf '\n%s\n' "$TITLE" >&2
if [ "${TERM:-dumb}" = dumb ] || [ "${TOOL_MENU:-}" = numbered ] || [ ! -t 0 ]; then
    for ((i=0;i<COUNT;i++)); do printf '  %s. %s\n' "$((i+1))" "${OPTIONS[i]}" >&2; done
    while :; do
        printf 'Choose [%s]: ' "$((DEFAULT+1))" >&2
        IFS= read -r value || exit 130; value=${value:-$((DEFAULT+1))}
        if [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 1 ] && [ "$value" -le "$COUNT" ]; then printf '%s\n' "$((value-1))"; exit 0; fi
    done
fi
SAVED=$(stty -g); SELECTED=$DEFAULT
restore_terminal() { stty "$SAVED"; printf '\033[0m\033[?25h' >&2; }
trap restore_terminal EXIT; trap 'exit 130' INT TERM
stty -echo -icanon min 1 time 0
printf 'Use ↑/↓ and Enter (or 1–9); Esc cancels.\n\033[?25l' >&2
while :; do
    for ((i=0;i<COUNT;i++)); do
        if [ "$i" = "$SELECTED" ]; then printf '\033[2K → \033[7m %s. %s \033[0m\n' "$((i+1))" "${OPTIONS[i]}" >&2;
        else printf '\033[2K    %s. %s\n' "$((i+1))" "${OPTIONS[i]}" >&2; fi
    done
    IFS= read -r -s -n 1 key || exit 130
    case "$key" in
        '') printf '%s\n' "$SELECTED"; exit 0 ;;
        $'\033') seq=; IFS= read -r -s -n 2 -t 1 seq || :
            case "$seq" in '[A'|'OA') SELECTED=$(((SELECTED+COUNT-1)%COUNT)) ;; '[B'|'OB') SELECTED=$(((SELECTED+1)%COUNT)) ;; '') exit 130 ;; esac ;;
        [1-9]) if [ "$key" -le "$COUNT" ]; then printf '%s\n' "$((key-1))"; exit 0; fi ;;
    esac
    printf '\033[%sA' "$COUNT" >&2
done
