"""Patch definition: common/devicetree-img3."""

PATCH = {
    'kind': 'container',
    'input': None,
    'core': 'devicetree',
    'destination': 'boot/DeviceTree.img3',
    'mode': 0o644,
    'template_file': 'common/devicetree-img3/template.img3',
}
