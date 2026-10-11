"""N48 BCM43342A1 / Barolo Bluetooth firmware and startup backport."""

PATCH = {
    'kind': 'edits',
    'input': 'n42-bluetool',
    'destination': 'rootfs/usr/sbin/BlueTool',
    'mode': 0o755,
    'data': 'n48/bluetooth/data.json',
}
