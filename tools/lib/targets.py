"""Explicit 5c target identities; N48 is an unvalidated hardware candidate."""
TARGETS = {
    'N49AP': {'ProductType': 'iPhone5,4', 'HardwareModel': 'N49AP', 'board_id': 14},
    'N48AP': {'ProductType': 'iPhone5,3', 'HardwareModel': 'N48AP', 'board_id': 10},
}


def target_for(value):
    for target in TARGETS.values():
        if str(value).lower() in [target['ProductType'].lower(), target['HardwareModel'].lower()]:
            return dict(target)
    raise ValueError('Unsupported target: ' + str(value))


def bundle_target(report):
    target = target_for(report['target']['HardwareModel'])
    if report['target']['ProductType'] != target['ProductType']: raise ValueError('Inconsistent bundle model/board')
    return target


def components_for(target):
    board = target['HardwareModel'].lower(); short = board[:-2]
    directory = 'Firmware/all_flash/all_flash.' + board + '.production/'
    return {'ibss': 'Firmware/dfu/iBSS.' + board + '.RELEASE.dfu',
            'ibec': 'Firmware/dfu/iBEC.' + board + '.RELEASE.dfu',
            'devicetree': directory + 'DeviceTree.' + board + '.img3',
            'kernel': 'kernelcache.release.' + short, 'ramdisk': 'RestoreRamDisk.dmg', 'rootfs': 'RootFS.dmg'}
