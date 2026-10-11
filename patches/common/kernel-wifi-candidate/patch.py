"""Patch definition: common/kernel-wifi-candidate. Binary operation data stays in data.json."""

PATCH = {
    'kind': 'edits',
    'input': 'n42-kernel.macho',
    'baseline_output_sha256': '98845ea86fc6582fb61a1456b2c3dd3d9c73fb3598fef9ff3db7d3b40d6d6291',
    'destination': 'boot/kernelcache.macho',
    'mode': 0o644,
    'data': 'common/kernel-wifi-candidate/data.json',
}
