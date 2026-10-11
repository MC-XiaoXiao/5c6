"""N48 HSIC bridge with a model-specific hardware guard."""

PATCH = {
    'kind': 'payload',
    'input': None,
    'destination': 'rootfs/usr/local/lib/project5c-commcenter-hsic.dylib',
    'mode': 0o755,
    'sources': ['n48/commcenter-bridge/src/commcenter_capabilities_hsic.c'],
    'payload': 'n48/commcenter-bridge/payload',
}
