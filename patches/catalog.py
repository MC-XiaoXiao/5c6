"""The patch list. Edit patch.py beside an asset to change its operation.

JSON data files contain generated binary edits, not another configuration layer.
The default profile is shared by N48 and N49; only the listed patches override it."""

COMMON = [
    'touch-firmware',
    'touch-kernel',
    'kernel-validated',
    'kernel-wifi-candidate',
    'kernel-img3-validated',
    'kernel-img3-wifi-candidate',
    'devicetree-img3',
    'sensors-cache',
    'locationd-heading',
    'bluetooth',
    'camera-isp',
    'camera-setfile',
    'camera-runtime',
    'autolock-runtime',
]

MODELS = {
    'iPhone5,3': [
        'bluetooth',
        'kernel-wifi-candidate',
        'commcenter-bridge',
        'commcenter-runtime',
        'devicetree',
        'devicetree-img3',
        'ibec',
        'ibss',
        'microphone-runtime',
    ],
    'iPhone5,4': [
        'commcenter-bridge',
        'commcenter-runtime',
        'devicetree',
        'gps-runtime',
        'ibec',
        'ibss',
        'microphone-runtime',
    ],
}

PROFILES = {
    'native6-validated': [
        'kernel-validated',
        'kernel-img3-validated',
        'touch-firmware',
        'devicetree',
        'devicetree-img3',
        'ibss',
        'ibec',
        'sensors-cache',
        'locationd-heading',
        'bluetooth',
        'camera-isp',
        'camera-setfile',
        'camera-runtime',
        'autolock-runtime',
        'microphone-runtime',
    ],
    'native6-wifi-candidate': [
        'kernel-wifi-candidate',
        'kernel-img3-wifi-candidate',
        'touch-firmware',
        'devicetree',
        'devicetree-img3',
        'ibss',
        'ibec',
        'sensors-cache',
        'locationd-heading',
        'bluetooth',
        'camera-isp',
        'camera-setfile',
        'camera-runtime',
        'autolock-runtime',
        'microphone-runtime',
    ],
}

EXTRAS = {
    'gps': ['gps-runtime'],
    'baseband': ['commcenter-runtime', 'commcenter-bridge'],
}

# Source firmware and target hardware are independent axes.
SOURCE_VARIANTS = {
    'n41ap': {
        '6.1.3': 'sources/n41/6.1.3',
        '6.1.4': 'sources/n41/6.1.4',
    },
}

INPUTS = {
    'n42-kernel.macho': {
        'size': 14204928,
        'firmware': 'N42 / 6.1.3 / 10B329',
        'origin': 'kernelcache.release.n42; decrypt IMG3, then decompress complzss',
        'rootfs_path': None,
    },
    'n42-kernel.complzss': {
        'size': 7797941,
        'firmware': 'N42 / 6.1.3 / 10B329',
        'origin': 'kernelcache.release.n42; decrypt IMG3 DATA before decompression',
        'rootfs_path': None,
    },
    'n42-devicetree.dtb': {
        'size': 83852,
        'firmware': 'N42 / 6.1.3 / 10B329',
        'origin': 'Firmware/all_flash/all_flash.n42ap.production/DeviceTree.n42ap.img3; decrypted DATA',
        'rootfs_path': None,
    },
    'n49-ibss.bin': {
        'size': 73728,
        'firmware': 'N49 / 7.0.1 / 11A470a',
        'origin': 'Firmware/dfu/iBSS.n49ap.RELEASE.dfu; decrypted DATA',
        'rootfs_path': None,
    },
    'n49-ibec.bin': {
        'size': 286720,
        'firmware': 'N49 / 7.0.1 / 11A470a',
        'origin': 'Firmware/dfu/iBEC.n49ap.RELEASE.dfu; decrypted DATA',
        'rootfs_path': None,
    },
    'n42-cache': {
        'size': 244601807,
        'firmware': 'N42 / 6.1.3 / 10B329',
        'origin': 'rootfs',
        'rootfs_path': '/System/Library/Caches/com.apple.dyld/dyld_shared_cache_armv7s',
    },
    'n42-locationd': {
        'size': 4505248,
        'firmware': 'N42 / 6.1.3 / 10B329',
        'origin': 'rootfs',
        'rootfs_path': '/usr/libexec/locationd',
    },
    'n42-commcenter': {
        'size': 9048240,
        'firmware': 'N42 / 6.1.3 / 10B329',
        'origin': 'rootfs',
        'rootfs_path': '/System/Library/Frameworks/CoreTelephony.framework/Support/CommCenter',
    },
    'n42-bluetool': {
        'size': 1814944,
        'firmware': 'N42 / 6.1.3 / 10B329',
        'origin': 'rootfs',
        'rootfs_path': '/usr/sbin/BlueTool',
    },
    'n49-mtprops': {
        'size': 91795,
        'firmware': 'N49 / 7.0.1 / 11A470a',
        'origin': 'rootfs',
        'rootfs_path': '/usr/share/firmware/multitouch/N49.mtprops',
    },
    'n49-bluetool': {
        'size': 4601616,
        'firmware': 'N49 / 7.0.1 / 11A470a',
        'origin': 'rootfs',
        'rootfs_path': '/usr/sbin/BlueTool',
    },
    'n49-isp.bin': {
        'size': 1519724,
        'firmware': 'N49 / 7.0.1 / 11A470a',
        'origin': 'rootfs dyld_shared_cache_armv7s: H4ISPServices embedded firmware; extract-rootfs --model n49',
        'rootfs_path': None,
        'scan_prefix_hex': '3e0400eafeffffeafeffffeafeffffea',
    },
    'n49-setfile.dat': {
        'size': 22412,
        'firmware': 'N49 / 7.0.1 / 11A470a',
        'origin': 'rootfs dyld_shared_cache_armv7s: embedded 7652_01XX.dat; extract-rootfs --model n49',
        'rootfs_path': None,
        'scan_prefix_hex': '7652010500074e000000000000000000',
    },
}

# The same rootfs paths are extracted under the actual source board's name.
# Per-version sizes and hashes are recorded by extraction/build receipts.
INPUTS.update({
    'n41' + name[3:]: {**spec, 'firmware': 'N41 / iOS 6.1.3 or 6.1.4',
                      'origin': spec['origin'].replace('n42', 'n41'),
                      'size': None}
    for name, spec in list(INPUTS.items()) if name.startswith('n42-')
})
