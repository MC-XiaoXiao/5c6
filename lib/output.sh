#!/usr/bin/env bash
# Non-interactive tools write raw diagnostics to disk. Polling that file avoids
# CR/ANSI cursor updates through tee, and works with macOS's Bash 3.2 and awk.
p5_output_text() {
    LC_ALL=C tr '\r' '\n' | LC_ALL=C awk '
      BEGIN { esc=sprintf("%c",27) }
      { gsub(esc "\\[[0-?]*[ -/]*[@-~]", ""); if(length)print }'
}
p5_output_percent() {
    tail -c 16384 "$1" | p5_output_text | LC_ALL=C awk '
      /^[[:space:]]*[0-9]+([.][0-9]+)?%[[:space:]]+\[[=> #]*\][[:space:]]*$/ { value=$0+0; found=1 }
      /^[[:space:]]*\[[=> #]*\][[:space:]]+[0-9]+([.][0-9]+)?%[[:space:]]*$/ {
        sub(/^[[:space:]]*\[[=> #]*\][[:space:]]+/, ""); value=$0+0; found=1
      }
      END { if(found && value>=0 && value<=100)printf "%d\n",value }'
}
p5_run_logged() (
    local style=$1 seconds=$2 bins=$3 label=$4 exe=$5; shift 5
    local directory=${P5_TOOL_LOG_DIR:-"$P5_ROOT/runtime/logs/tools"} log pid='' result=0
    local started=$SECONDS last=$SECONDS sampled=$SECONDS percent previous=-10
    case "$style" in quiet|step|progress) ;; *) p5_fail 'Unknown output style'; return 2 ;; esac
    mkdir -p "$directory" || return $?
    log=$(mktemp "$directory/${exe##*/}.log.XXXXXX") || return $?
    # Launch timeout directly: an asynchronous shell function would introduce
    # another shell PID and could leave the tool running after cancellation.
    p5_timeout_argv "$seconds" "$bins" "$exe" "$@" || return $?
    trap 'exit 130' INT
    trap 'exit 143' TERM
    [ "$style" = quiet ] || p5_log "$label (details: $log)"
    "${P5_TIMEOUT_ARGV[@]}" > "$log" 2>&1 <&0 &
    pid=$!
    # Bash 3.2 unwinds function locals before running EXIT on a signal. Capture
    # this numeric PID now instead of referring to a local from the trap.
    trap "kill -TERM $pid 2>/dev/null || :; wait $pid 2>/dev/null || :" EXIT
    if [ "$style" != quiet ]; then
        while kill -0 "$pid" 2>/dev/null; do
            if [ "$((SECONDS-sampled))" -ge 2 ]; then
                sampled=$SECONDS
                percent=''
                [ "$style" != progress ] || percent=$(p5_output_percent "$log")
                if [ -n "$percent" ] && [ "$percent" -ge "$((previous+10))" ]; then
                    p5_log "$label: ${percent}% reported, $((SECONDS-started))s elapsed"
                    previous=$percent; last=$SECONDS
                elif [ "$((SECONDS-last))" -ge 10 ]; then
                    p5_log "$label: working, $((SECONDS-started))s elapsed"
                    last=$SECONDS
                fi
            fi
            sleep 0.2
        done
    fi
    wait "$pid" || result=$?
    trap - EXIT
    pid=''
    if [ "$result" -ne 0 ]; then
        printf '[FAIL] %s (exit %s). Details: %s\n' "$label" "$result" "$log" >&2
        tail -c 16384 "$log" | p5_output_text | tail -n 40 >&2
    elif [ "$style" != quiet ]; then
        p5_log "$label complete ($((SECONDS-started))s)"
    fi
    return "$result"
)
p5_upload() {
    p5_run_logged progress 60 "$1" "Upload ${2##*/}" irecovery -f "$2"
}
