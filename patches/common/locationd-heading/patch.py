"""Patch definition: common/locationd-heading. Binary operation data stays in data.json."""

PATCH = {
    'kind': 'edits',
    'input': 'n42-locationd',
    'baseline_output_sha256': '7c0e8c6af6006865d06aa8bf5af9b7b10a5ea561706a0bec139fc97dacfb8808',
    'destination': 'rootfs/usr/libexec/locationd',
    'mode': 0o755,
    'data': 'common/locationd-heading/data.json',
}
