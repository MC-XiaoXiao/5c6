#!/usr/bin/env bash
# Bounded HTTPS transfers. Progress goes to stderr; stdout is the final URL.
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
p5_http_policy() {
    # connect, attempt, total (including retries), retries, stall, bytes/sec
    case "$1" in
        firmware) printf '15 1800 3600 2 30 1024\n' ;;
        tool) printf '15 300 600 2 30 1024\n' ;;
        keys) printf '15 60 120 2 20 64\n' ;;
        metadata) printf '10 20 45 1 15 64\n' ;;
        tss) printf '10 30 30 0 15 64\n' ;;
        *) p5_fail 'Unknown HTTP transfer policy'; return 2 ;;
    esac
}
p5_http_progress() {
    local label=$1 file=$2 expected=$3 elapsed=$4 bytes=0
    [ ! -f "$file" ] || bytes=$(p5_size "$file")
    p5_log "$label: $(awk -v bytes="$bytes" -v expected="$expected" -v elapsed="$elapsed" 'BEGIN {
      if (expected>0) printf "%.1f / %.1f MiB (%.0f%%)", bytes/1048576,expected/1048576,bytes*100/expected;
      else printf "%.1f KiB received",bytes/1024;
      printf ", %.1f KiB/s, %ds elapsed",bytes/1024/(elapsed>0?elapsed:1),elapsed;
    }')"
}
p5_http_fetch() (
    local kind=$1 label=$2 url=$3 output=$4 expected=$5; shift 5
    local policy connect attempt total retries stall speed meta pid='' code status final
    local started=$SECONDS now remaining limit last tries=0 retry delay
    policy=$(p5_http_policy "$kind") || return $?
    read -r connect attempt total retries stall speed <<< "$policy"
    mkdir -p "$(dirname -- "$output")" || return $?
    meta=$(mktemp "$output.http.XXXXXX") || return $?
    trap 'if [ -n "$pid" ]; then kill -TERM "$pid" 2>/dev/null || :; wait "$pid" 2>/dev/null || :; fi; rm -f -- "$meta"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    while :; do
        remaining=$((total-(SECONDS-started)))
        [ "$remaining" -gt 0 ] || { p5_fail "$label: total timeout (${total}s)"; return 28; }
        limit=$attempt; [ "$limit" -le "$remaining" ] || limit=$remaining
        tries=$((tries+1)); last=$SECONDS
        p5_log "$label: request $tries, ${remaining}s remaining"
        : > "$output" || return $?
        curl --user-agent 'Project5C6/2.0' "$@" --fail --silent --show-error \
            --proto '=https' --proto-redir '=https' --max-redirs 5 \
            --connect-timeout "$connect" --max-time "$limit" \
            --speed-limit "$speed" --speed-time "$stall" \
            --output "$output" --write-out '%{http_code}\n%{url_effective}\n' "$url" > "$meta" &
        pid=$!
        while kill -0 "$pid" 2>/dev/null; do
            now=$SECONDS
            if [ "$((now-last))" -ge 2 ]; then p5_http_progress "$label" "$output" "$expected" "$((now-started))"; last=$now; fi
            sleep 0.2
        done
        code=0; wait "$pid" || code=$?; pid=''
        status=$(sed -n '1p' "$meta"); final=$(sed -n '2p' "$meta")
        if [ "$code" = 0 ]; then
            p5_http_progress "$label" "$output" "$expected" "$((SECONDS-started))"
            printf '%s\n' "${final:-$url}"; return 0
        fi
        retry=no
        case "$code" in 5|6|7|18|28|35|52|55|56|92) retry=yes ;; 22) case "$status" in 408|429|500|502|503|504) retry=yes ;; esac ;; esac
        remaining=$((total-(SECONDS-started)))
        if [ "$retry" = yes ] && [ "$tries" -le "$retries" ] && [ "$remaining" -gt 1 ]; then
            delay=$tries; [ "$delay" -lt "$remaining" ] || delay=$((remaining-1))
            p5_log "$label: curl $code / HTTP ${status:-000}; retry in ${delay}s"
            sleep "$delay"
        else
            p5_fail "$label: curl $code / HTTP ${status:-000}, $((SECONDS-started))s elapsed (total limit ${total}s)"
            return "$code"
        fi
    done
)
