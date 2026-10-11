"""Patch definition: n49/ibec."""

PATCH = {
    'kind': 'fixed-n49-boot',
    'input': 'n49-ibec.bin',
    'features': [
        '6942454320666f72206e34396170',
        '0e0000ea18f09fe518f09fe518f09fe518f09fe518f09fe518f09fe518f09fe54000f0bf842ff2bfbc2ff2bff42ff2bf3030f2bf6830f2bff42ef2bf3c2ff2bf',
    ],
    'note': 'Fixed encrypted N49 boot artifact; no donor boot-code rebase.',
    'destination': 'boot/iBEC.dfu',
    'mode': 0o644,
    'payload': 'n49/ibec/payload',
}
