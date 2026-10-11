"""Patch definition: common/bluetooth. Binary operation data stays in data.json."""

PATCH = {
    'kind': 'edits',
    'input': 'n42-bluetool',
    'baseline_output_sha256': '3487de09043cbdda0a95953d207559b7129a1682faedddc6944f526c579b65a5',
    'destination': 'rootfs/usr/sbin/BlueTool',
    'mode': 0o755,
    'data': 'common/bluetooth/data.json',
}
