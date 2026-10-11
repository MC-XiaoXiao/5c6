"""Patch definition: n49/devicetree."""

PATCH = {
    'kind': 'tree',
    'profile_properties': {
        'native6-wifi-candidate': [{
            'node': '/device-tree/arm-io/usb-complex/usb-ehci/wlan',
            'name': 'module-instance',
            'accepted': [{'name': 'module-instance', 'flags': 0, 'value': b'centennial\0'.hex()}],
            'after': {'name': 'module-instance', 'flags': 0, 'value': b'muscat\0'.hex()},
            'index': 6,
        }, {
            'node': '/device-tree/arm-io/usb-complex/usb-ehci/wlan',
            'name': 'bcom.btc.params',
            'accepted': [{'name': 'bcom.btc.params', 'flags': 0, 'value': '060000004100000008000000c8af000009000000983a00000a000000204e0000'}],
            'after': {'name': 'bcom.btc.params', 'flags': 0, 'value': '060000000f00000008000000c8af000009000000983a00000a000000204e0000'},
            'index': 23,
        }, *[{
            'node': '/device-tree/arm-io/usb-complex/usb-ehci/wlan',
            'name': name,
            'accepted': [None],
            'after': {'name': name, 'flags': 0, 'value': value},
            'index': index,
        } for index, name, value in [
            (30, 'rx-calibration-2.4', '00' * 27),
            (31, 'rx-calibration-5.0', '00' * 16),
            (32, 'rx-calibration-temp', '00'),
            (33, 'wlan.dfrts', '3c00c80002000500'),
        ]]],
    },
    'input': 'n42-devicetree.dtb',
    'base': 'common/devicetree/patch.py',
    'model': 'N49AP',
    'properties': [
        {
            'node': '/device-tree',
            'name': 'compatible',
            'accepted': [
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
                'value': '4e34394150006950686f6e65352c34004170706c6541524d00',
            },
            'index': 0,
        },
        {
            'node': '/device-tree',
            'name': 'model',
            'accepted': [
                {'name': 'model', 'flags': 0, 'value': '6950686f6e65352c3200'},
                {'name': 'model', 'flags': 0, 'value': '6950686f6e65352c3100'},
            ],
            'after': {'name': 'model', 'flags': 0, 'value': '6950686f6e65352c3400'},
            'index': 15,
        },
    ],
    'destination': 'boot/DeviceTree.dtb',
    'mode': 0o644,
}
