"""Patch definition: n49/ibss."""

PATCH = {
    'kind': 'fixed-n49-boot',
    'input': 'n49-ibss.bin',
    'features': [
        '6942535320666f72206e34396170',
        '0e0000ea18f09fe518f09fe518f09fe518f09fe518f09fe518f09fe518f09fe540000010c8a5001000a6001038a6001074a60010aca6001038a5001080a50010',
    ],
    'note': 'Fixed encrypted N49 boot artifact; no donor boot-code rebase.',
    'destination': 'boot/iBSS.dfu',
    'mode': 0o644,
    'payload': 'n49/ibss/payload',
}
