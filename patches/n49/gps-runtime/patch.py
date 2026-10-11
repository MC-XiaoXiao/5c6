"""Patch definition: n49/gps-runtime."""

PATCH = {
    'kind': 'payload',
    'input': None,
    'destination': 'rootfs/usr/local/lib/project5c-locationd-gps.dylib',
    'mode': 0o755,
    'sources': ['n49/gps-runtime/src/locationd_gps.c'],
    'payload': 'n49/gps-runtime/payload',
}
