#!/usr/bin/env bash
# Small Bash adapters around the same host tools used by Legacy iOS Kit.
# Firmware policy and the project-specific kernel/media algorithms stay separate.
p5_host_bins() { printf '%s\n' "${P5_BINS:-$(p5_get tools-dir "$P5_TOOLS")}"; }
p5_bspatch() { p5_run_timeout 120 "$(p5_host_bins)" bspatch "$1" "$3" "$2"; }
p5_hex_valid() {
    case "$1" in *[!0123456789abcdefABCDEF]*) p5_fail 'Invalid hexadecimal'; return 2 ;; esac
    [ "$((${#1}%2))" -eq 0 ] || { p5_fail 'Odd hex length'; return 2; }
}
p5_hex_write() { p5_hex_valid "$1" || return $?; printf '%s' "$1" | xxd -r -p > "$2"; }
p5_hex_range() {
    local offset=$2 length=$3 size
    [[ "$offset" =~ ^(0[xX][0-9a-fA-F]+|[0-9]+)$ && "$length" =~ ^(0[xX][0-9a-fA-F]+|[0-9]+)$ ]] || return 2
    offset=$((offset)); length=$((length)); size=$(p5_size "$1") || return $?
    [ "$offset" -ge 0 ] && [ "$length" -ge 0 ] && [ "$offset" -le "$size" ] && [ "$length" -le "$((size-offset))" ] || { p5_fail 'Range outside file'; return 2; }
    xxd -p -s "$offset" -l "$length" "$1" | tr -d '\n' || return $?
    printf '\n'
}
p5_edit() {
    local offset=$3 bytes=$((${#4}/2)) size
    p5_hex_valid "$4" || return $?
    [[ "$offset" =~ ^(0[xX][0-9a-fA-F]+|[0-9]+)$ ]] || return 2
    offset=$((offset)); size=$(p5_size "$1") || return $?
    [ "$offset" -ge 0 ] && [ "$offset" -le "$size" ] && [ "$bytes" -le "$((size-offset))" ] || { p5_fail 'Binary edit outside file'; return 2; }
    [ "$1" = "$2" ] || cp -- "$1" "$2" || return $?
    printf '%s' "$4" | xxd -r -p | dd of="$2" bs=1 seek="$offset" conv=notrunc 2>/dev/null
}
p5_locate() {
    p5_hex_valid "$2" || return $?
    [ -n "$2" ] || return 2
    xxd -p -c 4096 "$1" | LC_ALL=C awk -v pattern="$(printf '%s' "$2"|tr 'A-F' 'a-f')" '
      { chunk=tail $0; base=used-length(tail); scan=1;
        while ((pos=index(substr(chunk,scan),pattern))) {
          pos+=scan-1;
          if ((base+pos-1)%2==0) { found=(base+pos-1)/2; matches++ }
          scan=pos+1;
        }
        used+=length($0); keep=length(pattern)-2;
        tail=substr(chunk,length(chunk)-keep+1);
      }
      END { if(matches!=1)exit 2; printf "%.0f\n",found }'
}
p5_zip_list() {
    unzip -Z1 "$1" | awk '
      /^\// || /(^|\/)\.\.(\/|$)/ || !length || seen[$0]++ {exit 2}
      {print}'
}
p5_zip_check() { p5_zip_list "$1" >/dev/null || return $?; p5_run_timeout 120 "$(p5_host_bins)" unzip -tq "$1" >&2; }
p5_zip_member() {
    local archive=$1 member=$2 output=$3 count
    case "$member" in ''|/*|..|../*|*/../*|*/..|*'*'*|*'?'*|*'['*|*']'*) p5_fail 'Unsafe ZIP member path'; return 2 ;; esac
    count=$(p5_zip_list "$archive" | awk -v member="$member" '$0==member{n++} END{print n+0}') || return $?
    [ "$count" -eq 1 ] || { p5_fail "ZIP member missing/ambiguous: $member"; return 2; }
    if ! (ulimit -f 65536; p5_run_timeout 120 "$(p5_host_bins)" unzip -p "$archive" "$member") > "$output"; then rm -f -- "$output"; return 2; fi
    [ -s "$output" ] && [ "$(p5_size "$output")" -le 67108864 ] || { rm -f -- "$output"; p5_fail 'ZIP member exceeds component limit'; return 2; }
}
p5_xpwn_decode() {
    local input=$1 output=$2 iv=${3:-} key=${4:-} args=()
    [ -z "$iv" ] || args=(-iv "$iv" -k "$key")
    p5_run_timeout 180 "$(p5_host_bins)" xpwntool "$input" "$output" ${args[@]+"${args[@]}"} >&2
}
p5_xpwn_pack() {
    local input=$1 output=$2 template=$3
    p5_run_timeout 180 "$(p5_host_bins)" xpwntool "$input" "$output" -t "$template" >&2
}
p5_normal_devices() {
    p5_run_timeout 15 "$(p5_host_bins)" idevice_id -l
}
p5_remote_member() {
    local url=$1 member=$2 output=$3 result=0
    # Without -c this pinned pzb strips the directory part of -o, even when
    # the destination already exists. Retain the complete workspace path.
    (ulimit -f 65536; p5_run_live 300 "$(p5_host_bins)" "Download $member" pzb -c -g "$member" -o "$output" "$url") || result=$?
    if [ "$result" -ne 0 ]; then rm -f -- "$output"; return "$result"; fi
    [ -s "$output" ] && [ "$(p5_size "$output")" -le 67108864 ] || { rm -f -- "$output"; p5_fail 'Remote ZIP member exceeds component limit'; return 2; }
}
p5_tail_stitch() {
    local size bytes
    size=$(p5_size "$1") || return $?; bytes=$(p5_size "$2") || return $?
    [ "$bytes" -gt 0 ] && [ "$bytes" -lt "$size" ] || { p5_fail 'Invalid signature extent'; return 2; }
    cp -- "$1" "$3" || return $?
    dd if="$2" of="$3" bs=1 seek="$((size-bytes))" conv=notrunc 2>/dev/null
}
