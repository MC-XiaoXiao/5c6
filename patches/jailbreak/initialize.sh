#!/bin/bash
# Seed the freshly formatted Data partition before running Cydia initialization.
set -e
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
SEED=/private/project5c-jailbreak/seed
MARKER=/private/var/.project5c-jailbreak-initialized
SEEDED=/private/var/.project5c-jailbreak-seeded
# Refuse to initialize into the unmounted System-side mount point.
ready=no
for ((attempt=0; attempt<120; attempt++)); do
    if /sbin/mount | /bin/grep -q ' on /private/var '; then ready=yes; break; fi
    /bin/sleep 1
done
[ "$ready" = yes ] || exit 1
# The periodic launchd job is retained for failed first-boot attempts only.
[ ! -f "$MARKER" ] || exit 0
/sbin/mount -u -o rw,suid,dev /
if [ ! -f "$SEEDED" ]; then
    [ -d "$SEED/lib/dpkg" ] || exit 1
    /bin/cp -Rp "$SEED/." /private/var/
    /bin/chown -R 0:0 /private/var/lib /private/var/root/Media/Cydia
    /bin/touch "$SEEDED"
fi
if [ ! -f "$MARKER" ]; then
    /usr/libexec/cydia/startup
    /bin/touch "$MARKER"
fi
