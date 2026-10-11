"""N48 hardware branch; share checked iOS 6 Mav7/HSIC runtime operations."""

PATCH = {
    'kind': 'edits',
    'input': 'n42-commcenter',
    'destination': 'rootfs/usr/local/libexec/project5c/CommCenter.n48-runtime',
    'mode': 0o755,
    'data': 'n49/commcenter-runtime/data.json',
    'edit_replacements': [{'before': '31', 'after': '30', 'count': 1}],
}
