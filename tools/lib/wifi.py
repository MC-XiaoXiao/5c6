"""Check the iOS 6 BCM43342 driver, board properties and firmware as one set."""
import hashlib
import struct

from features import commands, parse_tree, tree_nodes
from firmware import extract_img3_data, decompress_complzss, extract_macho32_section, parse_prelink_xml
from targets import target_for

WLAN = '/device-tree/arm-io/usb-complex/usb-ehci/wlan'
BUS = 'com.apple.driver.AppleBCMWLANBusInterfaceHSIC'
SHIM = BUS + 'Shim'
DEVICE = 'com.apple.driver.AppleBCMWLANHSICDevice'
# These are stock N49 placeholders, not calibration measured from another phone.
# The complete set was used by the 2026-10-08 HSIC v2 physical networking test.
N49_PROPERTIES = {
    'module-instance': b'muscat\0',
    'bcom.btc.params': bytes.fromhex('060000000f00000008000000c8af000009000000983a00000a000000204e0000'),
    'rx-calibration-2.4': bytes(27),
    'rx-calibration-5.0': bytes(16),
    'rx-calibration-temp': bytes(1),
    'wlan.dfrts': bytes.fromhex('3c00c80002000500'),
}


def unpack_kernel(data):
    if data[:4] != b'\xce\xfa\xed\xfe':
        data = extract_img3_data(data, None, None)
    return decompress_complzss(data)[0] if data.startswith(b'complzss') else data


def check(kernel, devicetree, model, firmware_paths=None):
    model = target_for(model)['ProductType']
    prefix = {'iPhone5,4': 'muscat', 'iPhone5,3': 'barolo'}[model]
    if devicetree[:4] == b'3gmI':
        devicetree = extract_img3_data(devicetree, None, None)
    nodes = tree_nodes(parse_tree(devicetree))
    props = {p['name']: bytes.fromhex(p['value']) for p in nodes[WLAN]['properties']}
    required = N49_PROPERTIES if model == 'iPhone5,4' else {'module-instance': b'barolo\0'}
    for name, value in required.items():
        if props.get(name) != value:
            raise ValueError('WiFi DeviceTree property differs: ' + name + '; rebuild the WiFi bundle')
    kernel = unpack_kernel(kernel)
    meta = parse_prelink_xml(extract_macho32_section(kernel, '__PRELINK_INFO', '__info'))
    entries = {row['CFBundleIdentifier']: row for row in meta['_PrelinkInfoDictionary']}
    personality = entries[SHIM]['IOKitPersonalities']['43342']
    if (personality.get('idVendor'), personality.get('idProduct')) != (0x0a5c, 0xbd21):
        raise ValueError('WiFi BCM43342 USB identity differs')
    products = personality['HSICProductInfo']
    expected = {'43342a0/' + prefix + suffix for suffix in ('.trx', '-m-mt.txt', '-t-kk.txt', '-u-kk.txt')}
    if len(products) != 3:
        raise ValueError('WiFi requires all three BCM43342 module profiles')
    selected_paths = set()
    vendors = set()
    for product in products.values():
        rf = product.get('HSICRFHardwareInfo', [])
        if product.get('HSICChipInfo') != ['s=A1'] or len(rf) != 2 or rf[0] != 'M=IMPE':
            raise ValueError('WiFi BCM43342 chip/RF profile differs')
        vendors.add(rf[1])
        files = product['FilesDB']
        if (set(files) != {'default', prefix}
                or not set(files[prefix].values()) <= expected
                or files['default'] != files[prefix]):
            raise ValueError('WiFi kernel firmware paths differ from target ' + model)
        selected_paths.update(files[prefix].values())
    if selected_paths != expected:
        raise ValueError('WiFi module profiles do not cover the matching firmware set')
    if vendors != {'V=m', 'V=t', 'V=u'}:
        raise ValueError('WiFi module vendor profiles differ')
    if '43342' not in entries[DEVICE]['IOKitPersonalities']:
        raise ValueError('WiFi BCM43342 device personality is missing')
    row = entries[BUS]
    start, size = row['_PrelinkExecutableSourceAddr'], row['_PrelinkExecutableSize']
    executable = None
    for cmd, p, _ in commands(kernel):
        if cmd == 1:
            vm, _, off, length = struct.unpack_from('<4I', kernel, p + 24)
            if vm <= start and start + size <= vm + length:
                executable = kernel[off + start - vm:off + start - vm + size]
    if executable is None:
        raise ValueError('WiFi HSIC executable is outside kernel mappings')
    # Pin the chip/RAM adaptations and synchronous reset -> host-start sequence.
    for offset, value in [(0xf34, '4af64e12'), (0xdd8, '4af64e10'), (0xdf0, '4ff40020'),
                          (0x2d18, '00f00cf8'), (0x2d32, '27e0'),
                          (0x2d34, '08b58847204605f0ddf8204608bd')]:
        wanted = bytes.fromhex(value)
        if executable[offset:offset + len(wanted)] != wanted:
            raise ValueError('WiFi HSIC v2 instruction feature differs at ' + hex(offset))
    paths = {'usr/share/firmware/wifi/' + name for name in expected}
    if firmware_paths is not None and set(firmware_paths) != paths:
        raise ValueError('WiFi firmware file set differs from kernel FilesDB')
    return {'model': model, 'module': prefix, 'hsic_v2_features_verified': True,
            'bus_executable_sha256': hashlib.sha256(executable).hexdigest(),
            'board_properties_verified': sorted(required), 'firmware_paths': sorted(paths)}
