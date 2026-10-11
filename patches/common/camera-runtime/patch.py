"""Patch definition: common/camera-runtime."""

PATCH = {
    'kind': 'payload',
    'input': None,
    'destination': 'rootfs/usr/local/lib/camera-ov9762.dylib',
    'mode': 0o755,
    'sources': [
        'common/camera-runtime/src/selector_patch.c',
        'common/camera-runtime/src/profile.h',
        'common/camera-runtime/src/profile-original.h',
    ],
    'payload': 'common/camera-runtime/payload',
}
