"""Patch definition: n49/commcenter-bridge."""

PATCH = {
    'kind': 'payload',
    'input': None,
    'destination': 'rootfs/usr/local/lib/project5c-commcenter-hsic.dylib',
    'mode': 0o755,
    'sources': ['n49/commcenter-bridge/src/commcenter_capabilities_hsic.c'],
    'payload': 'n49/commcenter-bridge/payload',
}
