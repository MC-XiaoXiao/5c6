"""Patch definition: n48/devicetree."""

PATCH = {
    'kind': 'tree',
    'profile_properties': {
        'native6-wifi-candidate': [{
            'node': '/device-tree/arm-io/usb-complex/usb-ehci/wlan',
            'name': 'module-instance',
            'accepted': [{'name': 'module-instance', 'flags': 0, 'value': b'centennial\0'.hex()}],
            'after': {'name': 'module-instance', 'flags': 0, 'value': b'barolo\0'.hex()},
            'index': 0,
        }],
    },
    'properties': [
        {
            'node': '/device-tree',
            'name': 'compatible',
            'accepted': [
                {
                    'name': 'compatible',
                    'flags': 0,
                    'value': '4e34394150006950686f6e65352c34004170706c6541524d00',
                },
                {
                    'name': 'compatible',
                    'flags': 0,
                    'value': '4e34324150006950686f6e65352c32004170706c6541524d00',
                },
                {
                    'name': 'compatible',
                    'flags': 0,
                    'value': '4e34314150006950686f6e65352c31004170706c6541524d00',
                },
            ],
            'after': {
                'name': 'compatible',
                'flags': 0,
                'value': '4e34384150006950686f6e65352c33004170706c6541524d00',
            },
            'index': 0,
        },
        {
            'node': '/device-tree',
            'name': 'model',
            'accepted': [
                {'name': 'model', 'flags': 0, 'value': '6950686f6e65352c3400'},
                {'name': 'model', 'flags': 0, 'value': '6950686f6e65352c3200'},
                {'name': 'model', 'flags': 0, 'value': '6950686f6e65352c3100'},
            ],
            'after': {'name': 'model', 'flags': 0, 'value': '6950686f6e65352c3300'},
            'index': 15,
        },
        {
            'node': '/device-tree/arm-io/usb-complex/usb-device',
            'name': 'product-version',
            'accepted': [
                {'name': 'product-version', 'flags': 0, 'value': '20050000'},
                {'name': 'product-version', 'flags': 0, 'value': '10050000'},
            ],
            'after': {'name': 'product-version', 'flags': 0, 'value': '30050000'},
            'index': 15,
        },
    ],
    'donor_model': 'iPhone5,3',
    'donor_build': '11A470a',
    'retained_compatibility_overrides': [
        {
            'node': '/device-tree/arm-io/usb-complex/usb-ehci/wlan',
            'name': 'module-instance',
            'reason': 'Baseline retains centennial; Wi-Fi candidate selects the original Barolo resource profile.',
        },
    ],
    'base': 'common/devicetree/patch.py',
    'input': 'n42-devicetree.dtb',
    'donor_input': 'DeviceTree.n48.dtb',
    'match': {'model': 'iPhone5,3', 'board': 'N48AP'},
    'destination': 'boot/DeviceTree.dtb',
    'mode': 0o644,
}
