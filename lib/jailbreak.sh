#!/usr/bin/env bash
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
p5_bootstrap() {
    local output=$1 patches="$P5_ROOT/resources/jailbreak" count essential rel hashes='{}' stage archive name tree escaped
    p5_temp
    stage=$(mktemp -d "$P5_TMP/bootstrap.XXXXXX") || return $?
    : > "$stage/entries"
    for name in cydia.tar.gz substrate.tar; do
        archive="$patches/$name"; tree="$stage/$name.files"; mkdir -p "$tree" || return $?
        # Convert archive metadata directly to mtree, retaining uid/gid and
        # setuid bits even when the host cannot chown the extracted contents.
        bsdtar --format=mtree --options='!all,type,uid,gid,mode,size,link,!use-set' -cf "$stage/input.mtree" "@$archive" || return $?
        awk '$1 !~ /^#/ && ($1 ~ /^\// || $1 ~ /(^|\/)\.\.(\/|$)/) {exit 2}' "$stage/input.mtree" || return $?
        bsdtar -xf "$archive" -C "$tree" --no-same-owner --no-same-permissions || return $?
        escaped=$(printf '%s' "$tree" | sed 's/\\/\\134/g; s/ /\\040/g')
        P5_MTREE_CONTENTS="$escaped" awk '
          /^#/ || $1=="." {next}
          { original=$1; sub(/^\.\//,"",original); path=original;
            if (path ~ /^private\/var(\/|$)/) {
              if (path !~ /^private\/var\/lib(\/|$)/ && path !~ /^private\/var\/root\/Media\/Cydia(\/|$)/) next;
              sub(/^private\/var/,"private/project5c-jailbreak/seed",path);
            }
            if(path=="Library/LaunchDaemons/com.saurik.Cydia.Startup.plist")next;
            if($0 !~ / type=(file|dir|link)( |$)/)exit 2;
            $1="./" path;
            if($0 ~ / type=file( |$)/) $0=$0 " contents=" ENVIRON["P5_MTREE_CONTENTS"] "/" original;
            print $0 " time=0 nlink=1";
          }' "$stage/input.mtree" >> "$stage/entries" || return $?
    done
    printf '#mtree\n' > "$stage/output.mtree"
    # The second archive overrides duplicate paths, matching installation order.
    awk '{entry[$1]=$0} END{for(path in entry)print entry[path]}' "$stage/entries" | LC_ALL=C sort >> "$stage/output.mtree" || return $?
    bsdtar --format=ustar -s ',^\./,,HS' -cf "$output" "@$stage/output.mtree" || return $?
    count=$(($(wc -l < "$stage/output.mtree")-1))
    essential='["Applications/Cydia.app/Cydia","bin/bash","usr/bin/dpkg","usr/bin/dpkg-query","usr/libexec/cydia/startup","private/project5c-jailbreak/seed/lib/dpkg/status"]'
    while IFS= read -r rel; do
        bsdtar -xOf "$output" "$rel" > "$P5_TMP/bootstrap-essential" || return $?
        [ -s "$P5_TMP/bootstrap-essential" ] || { p5_fail "Bootstrap lacks $rel"; return 2; }
        hashes=$(printf '%s' "$hashes"|jq --arg rel "$rel" --arg sha "$(p5_sha "$P5_TMP/bootstrap-essential")" '.[$rel]=$sha')
    done < <(printf '%s' "$essential"|jq -r '.[]')
    jq -n --argjson files "$count" --arg sha "$(p5_sha "$output")" --argjson essential "$essential" --argjson hashes "$hashes" '{kind:"tethered-iOS6-bootstrap",archive_sha256:$sha,files:$files,tethered:true,data_seed:"/private/project5c-jailbreak/seed",essential_paths:$essential,essential_sha256:$hashes}'
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then set -euo pipefail; [ "$#" -eq 1 ] || exit 2; p5_bootstrap "$1"; fi
