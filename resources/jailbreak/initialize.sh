#!/bin/bash
# The tethered kernel already contains the iOS 6 jailbreak policy patches.
# Seed Data once, then run the jailbreak startup tasks once on every boot.
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
/sbin/mount -u -o rw,suid,dev /
if [ ! -f "$SEEDED" ]; then
    [ -d "$SEED/lib/dpkg" ] || exit 1
    /bin/cp -Rp "$SEED/." /private/var/
    /bin/chown -R 0:0 /private/var/lib /private/var/root/Media/Cydia
    /bin/touch "$SEEDED"
fi
if [ ! -f "$MARKER" ]; then
    # startup removes AutoInstall packages even if dpkg fails. Restore only
    # these packages for a retry, without overwriting the live dpkg database.
    /bin/mkdir -p /private/var/root/Media/Cydia/AutoInstall
    /bin/cp -p "$SEED"/root/Media/Cydia/AutoInstall/*.deb /private/var/root/Media/Cydia/AutoInstall/
    /usr/libexec/cydia/startup
    [ "$(/usr/bin/dpkg-query -W -f='${Status}' mobilesubstrate)" = 'install ok installed' ]
    [ -x /usr/libexec/substrate ]
    /bin/touch "$MARKER"
fi
# Match Kit's post-patch startup: rc.d scripts, then third-party launchd jobs.
# The Substrate package normally provides /etc/rc.d/substrate.
failed=no
if [ ! -x /etc/rc.d/substrate ]; then /usr/libexec/substrate || failed=yes; fi
for script in /etc/rc.d/*; do
    [ -f "$script" ] && [ -x "$script" ] || continue
    "$script" || failed=yes
done
if [ -d /Library/LaunchDaemons ]; then
    # launchctl also reports already-loaded jobs as an error.
    /bin/launchctl load /Library/LaunchDaemons || true
fi
[ "$failed" = no ] || exit 1
# Remove this loaded job only for the current launchd lifetime. Its System
# plist remains enabled and is loaded again at the next boot. Failed runs
# retain the job and its StartInterval retry, without a persistent boot marker.
exec /bin/launchctl remove org.project5c.jailbreak
