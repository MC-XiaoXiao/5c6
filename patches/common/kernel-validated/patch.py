"""Patch definition: common/kernel-validated. Binary operation data stays in data.json."""

PATCH = {
    'kind': 'edits',
    'input': 'n42-kernel.macho',
    'baseline_output_sha256': '4c9b23c5d8266d657cb87f223bf89b4ae4280c38968409fdbb1eb0e696310618',
    'destination': 'boot/kernelcache.macho',
    'mode': 0o644,
    'data': 'common/kernel-validated/data.json',
}
