"""Patch definition: common/autolock-runtime."""

PATCH = {
    'kind': 'payload',
    'input': None,
    'destination': 'rootfs/usr/local/lib/native6-autolock.dylib',
    'mode': 0o755,
    'sources': ['common/autolock-runtime/src/native6-autolock.c'],
    'payload': 'common/autolock-runtime/payload',
}
