"""Patch definition: n48/ibec."""

PATCH = {
    'kind': 'boot-feature',
    'model': 'N48AP',
    'donor_version': '7.0.1',
    'donor_build': '11A470a',
    'input': 'iBEC.n48.dfu',
    'patcher': 'iBoot32Patcher',
    'flags': [
        '--rsa',
        '--debug',
        '--ticket',
        '-b',
        'rd=disk0s1s1 -v debug=0x2014e wdt=-1 pio-error=0 amfi=0xff cs_enforcement_disable=1',
    ],
    'validation': [
        'N48 decrypted component marker',
        'unchanged raw extent',
        'IMG3 image type preserved',
        'encrypted round trip',
    ],
    'physical_validation': False,
    'match': {
        'model': 'N48AP',
        'marker': 'iBEC for n48ap',
        'required_flags': [
            '--rsa',
            '--debug',
            '--ticket',
            '-b',
            'rd=disk0s1s1 -v debug=0x2014e wdt=-1 pio-error=0 amfi=0xff cs_enforcement_disable=1',
        ],
    },
    'destination': 'boot/iBEC.dfu',
    'mode': 0o644,
}
