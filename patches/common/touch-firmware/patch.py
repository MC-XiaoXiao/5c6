"""Shared C1F57,2 touch resource; only input alias and installed name differ."""

PATCH = {
    'kind': 'copy',
    'models': {
        'iPhone5,3': {
            'input': 'N48.mtprops',
            'destination': 'rootfs/usr/share/firmware/multitouch/N48.mtprops',
        },
        'iPhone5,4': {
            'input': 'n49-mtprops',
            'destination': 'rootfs/usr/share/firmware/multitouch/N49.mtprops',
        },
    },
    'sha256': '3c7b9a6a9aa6d47358a96daf163d57c205a94fc8000675622dd41af51d88d612',
    'size': 91795,
    'kernel_dependency': ['kernel-validated', 'kernel-wifi-candidate'],
    'kernel_check': 'touch-kernel',
    'physical_validation': False,
    'match': {'plist': True},
    'mode': 0o644,
}
