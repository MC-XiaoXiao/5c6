"""N48 uses Barolo calibration/firmware with the shared BCM43342/HSIC code."""

PATCH = {
    'kind': 'edits',
    'input': 'n42-kernel.macho',
    'destination': 'boot/kernelcache.macho',
    'mode': 0o644,
    'data': 'common/kernel-wifi-candidate/data.json',
    'edit_replacements': [
        {'before': b'43342a0/muscat'.hex(), 'after': b'43342a0/barolo'.hex(), 'count': 12},
        {'before': b'<key>muscat</key>'.hex(), 'after': b'<key>barolo</key>'.hex(), 'count': 3},
    ],
}
