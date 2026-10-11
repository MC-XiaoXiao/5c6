"""Patch definition: common/sensors-cache. Binary operation data stays in data.json."""

PATCH = {
    'kind': 'edits',
    'input': 'n42-cache',
    'baseline_output_sha256': '5cbcba12dd151ce6d4433a2f27b96b5633a0a57e4ddafe0140717b9769aa3dbf',
    'destination': 'rootfs/System/Library/Caches/com.apple.dyld/dyld_shared_cache_armv7s',
    'mode': 0o644,
    'data': 'common/sensors-cache/data.json',
}
