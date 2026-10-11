"""Patch definition: n49/commcenter-runtime. Binary operation data stays in data.json."""

PATCH = {
    'kind': 'edits',
    'input': 'n42-commcenter',
    'baseline_output_sha256': 'e37be1c7a6a54a1417bde0d298331b407736911726231594f9adee6c84c07513',
    'destination': 'rootfs/usr/local/libexec/project5c/CommCenter.n49-runtime',
    'mode': 0o755,
    'data': 'n49/commcenter-runtime/data.json',
}
