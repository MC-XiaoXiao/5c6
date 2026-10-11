"""Patch definition: n48/devicetree-img3."""

PATCH = {
    'model': 'N48AP',
    'kind': 'container',
    'core': 'devicetree',
    'destination': 'boot/DeviceTree.img3',
    'template_recipe': 'common/devicetree-img3/patch.py',
    'validation': ['IMG3 DATA matches N48 DeviceTree', 'IMG3 type preserved'],
    'physical_validation': False,
    'match': {'model': 'N48AP', 'core': 'devicetree'},
    'mode': 0o644,
}
