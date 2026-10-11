"""Patch definition: n48/ibss."""

PATCH = {
    'kind': 'boot-feature',
    'model': 'N48AP',
    'donor_version': '7.0.1',
    'donor_build': '11A470a',
    'input': 'iBSS.n48.dfu',
    'patcher': 'iBoot32Patcher',
    'flags': ['--rsa'],
    'validation': [
        'N48 decrypted component marker',
        'unchanged raw extent',
        'IMG3 image type preserved',
        'encrypted round trip',
    ],
    'physical_validation': False,
    'match': {'model': 'N48AP', 'marker': 'iBSS for n48ap', 'required_flags': ['--rsa']},
    'destination': 'boot/iBSS.dfu',
    'mode': 0o644,
}
