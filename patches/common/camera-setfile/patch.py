"""Patch definition: common/camera-setfile."""

PATCH = {
    'kind': 'copy',
    'input': 'n49-setfile.dat',
    'features': ['7652010500074e00000000000000000026000000140100000000000004830000'],
    'input_size': 22412,
    'destination': 'rootfs/usr/local/share/firmware/isp/7652_01XX.dat',
    'mode': 0o644,
}
