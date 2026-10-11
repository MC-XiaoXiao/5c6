#!/usr/bin/env python3
"""Prepare and restore iPhone 5c firmware with a patched native restore host."""
import argparse
import hashlib
import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import zipfile

import patchctl
from progress import log, stage, commands as preview_commands, error_detail
from contextlib import nullcontext
from hosttools import tool_directory, tool_env, require_tools, require_boot_tools, prepare_pwned_ibss
from targets import target_for, bundle_target, components_for
from features import locate, resign, verify_signature, parse_tree
from firmware import extract_img3_data, decompress_complzss, parse_img3

BOOTARGS = ('rd=md0 -v nand-enable-reformat=1 amfi=0xff '
            'amfi_get_out_of_my_way=1 cs_enforcement_disable=1 pio-error=0')
ASR_ANCHOR = bytes.fromhex('784410f0b6e80125f3e717980ff012ef4df6a430c0f20000784410f0aae8502419980ff0')
RESTORED_ANCHOR = bytes.fromhex('2046a8478346bbf1000f11d14af64a210822c0f20c0141f2c9307944c0f20800cdf8048009687844')
RESTORED_EPILOGUE = bytes.fromhex('0398002c01684ff00000419a08bf0120914202bf42b0bde8000df0bd')
FLASH = dict(FlashNOR=False, UpdateBaseband=False, FormatForLwVM=True,
             CreateFilesystemPartitions=True, SystemImage=True)
ALL_FLASH = 'Firmware/all_flash/all_flash.n49ap.production/'
COMPONENTS = {'ibss': 'Firmware/dfu/iBSS.n49ap.RELEASE.dfu',
              'ibec': 'Firmware/dfu/iBEC.n49ap.RELEASE.dfu',
              'devicetree': ALL_FLASH + 'DeviceTree.n49ap.img3',
              'kernel': 'kernelcache.release.n49', 'ramdisk': 'RestoreRamDisk.dmg',
              'rootfs': 'RootFS.dmg'}


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def check_system_dmg(path):
    """Reject skip-write runs in the HFS volume, including allocated zero data."""
    path = Path(path)
    with path.open('rb') as f:
        size = path.stat().st_size
        require(size >= 512, 'Truncated restore DMG')
        f.seek(size - 512); footer = f.read(512)
        require(footer[:4] == b'koly', 'Restore image lacks UDIF footer')
        offset, length = struct.unpack_from('>QQ', footer, 216)
        require(0 < length <= 16 * 1024 * 1024 and offset + length <= size - 512,
                'Invalid restore DMG resource extent')
        f.seek(offset); resources = plistlib.loads(f.read(length))
    volumes = []
    for item in resources['resource-fork']['blkx']:
        if 'Apple_HFS' not in item.get('Name', ''):
            continue
        data = item['Data']
        require(len(data) >= 204 and data[:4] == b'mish', 'Invalid HFS block table')
        count = struct.unpack_from('>I', data, 200)[0]
        require(0 < count <= 100000 and len(data) == 204 + count * 40,
                'Invalid HFS block run count')
        types = [struct.unpack_from('>I', data, 204 + i * 40)[0] for i in range(count)]
        require(2 not in types, 'HFS DMG contains skip-write runs; build the explicit-zero DMG tool '
                'with maintenance/build_restore_dmg.py and pass --dmg-tool (see RESTORE.md)')
        volumes.append(count)
    require(len(volumes) == 1, 'Expected exactly one HFS restore volume')
    return dict(hfs_runs=volumes[0], hfs_skip_write_runs=0, zero_regions_written=True)


def require(ok, message):
    if not ok:
        raise ValueError(message)


WIFI_FILES = ('muscat.trx', 'muscat-m-mt.txt', 'muscat-t-kk.txt', 'muscat-u-kk.txt')


def copy_hfs(source, destination):
    """Copy a raw HFS volume, extracting its bounded extent from an Apple partition map."""
    source = Path(source)
    size = source.stat().st_size
    with source.open('rb') as src:
        header = src.read(4096)
        offset, length, container = 0, size, 'raw-hfs'
        if header[1024:1026] not in (b'H+', b'HX'):
            require(header[:2] == b'ER', 'Expected raw HFS or Apple partition map')
            block = struct.unpack_from('>H', header, 2)[0]
            require(block in (512, 1024, 2048, 4096), 'Invalid partition block size')
            src.seek(block); first = src.read(512)
            require(first[:2] == b'PM', 'Missing Apple partition map')
            count = struct.unpack_from('>I', first, 4)[0]
            require(1 <= count <= 128 and (count + 1) * block <= size, 'Invalid partition count')
            volumes = []
            for i in range(1, count + 1):
                src.seek(i * block); entry = src.read(512)
                require(entry[:2] == b'PM', 'Invalid partition record')
                if entry[48:80].split(b'\0')[0] not in (b'Apple_HFS', b'Apple_HFSX'):
                    continue
                start, blocks = struct.unpack_from('>II', entry, 8)
                offset, length = start * block, blocks * block
                require(offset >= (count + 1) * block and length >= 2048
                        and offset + length <= size, 'HFS partition outside source')
                volumes.append((offset, length))
            require(len(volumes) == 1, 'Expected exactly one HFS partition')
            offset, length = volumes[0]; container = 'apple-partition-map'
        src.seek(offset + 1024)
        require(src.read(2) in (b'H+', b'HX'), 'HFS volume signature absent')
        src.seek(offset)
        with Path(destination).open('wb') as dst:
            remaining = length
            while remaining:
                data = src.read(min(1024 * 1024, remaining))
                require(data, 'Truncated HFS source')
                dst.write(data); remaining -= len(data)
    return dict(container=container, offset=offset, length=length)


def wifi_files(directory, model='iPhone5,4'):
    """Check packaged donor bytes or validate an explicit external donor directory."""
    rows = []
    prefix = {'iPhone5,3': 'barolo', 'iPhone5,4': 'muscat'}[model]
    for name in (prefix+'.trx', prefix+'-m-mt.txt', prefix+'-t-kk.txt', prefix+'-u-kk.txt'):
        source = Path(directory) / name
        require(source.is_file() and not source.is_symlink(), 'Missing WiFi donor file: ' + name)
        data = source.read_bytes()
        packaged = Path(__file__).resolve().parents[2] / 'donor'
        if source.resolve().is_relative_to(packaged):
            from integrity import checked
            data = checked(source)
        if name.endswith('.trx'):
            require(len(data) >= 28 and data[:4] == b'HDR0'
                    and struct.unpack_from('<I', data, 4)[0] == len(data), 'Invalid WiFi TRX structure')
        else:
            require(b'moduleid=' in data and b'devid=' in data and b'\0' not in data,
                    'Invalid WiFi calibration text: ' + name)
        rows.append(('usr/share/firmware/wifi/43342a0/' + name, source))
    return rows


def kit_env(bins):
    return tool_env(bins)


def external_tools(a):
    return tool_directory(getattr(a, 'kit', None), getattr(a, 'tools_dir', None))


def run(bins, name, *args, timeout=180):
    return subprocess.run([str(bins / name), *map(str, args)], env=kit_env(bins),
                          capture_output=True, check=True, timeout=timeout).stdout


def hfs_extract(bins, image, remote, destination, optional=False):
    with nullcontext() if optional else stage('Extract HFS file: ' + remote):
        destination.parent.mkdir(parents=True, exist_ok=True)
        run(bins, 'hfsplus', image, 'extract', '/' + remote.lstrip('/'), destination)
        if not destination.is_file() or destination.stat().st_size == 0:
            destination.unlink(missing_ok=True)
            raise ValueError('HFS extraction failed: ' + remote)


def hfs_add(bins, image, remote, source, mode):
    with stage('Write and verify HFS file: ' + remote):
        # Add supports replacement and preserves existing file ownership; new files are root-owned.
        parts = Path(remote).parts
        for i in range(1, len(parts)):
            run(bins, 'hfsplus', image, 'mkdir', '/'.join(parts[:i]))
        run(bins, 'hfsplus', image, 'add', source, remote)
        run(bins, 'hfsplus', image, 'chmod', oct(mode)[2:], remote)
        run(bins, 'hfsplus', image, 'chown', '0:0', remote)
        with tempfile.TemporaryDirectory() as temp:
            check = Path(temp) / 'check'
            hfs_extract(bins, image, remote, check)
            require(check.read_bytes() == source.read_bytes(), 'HFS readback differs: ' + remote)


def patch_restore_ibec(bins, source, destination):
    result = subprocess.run([str(bins / 'iBoot32Patcher'), str(source), str(destination),
                             '--rsa', '--debug', '-b', BOOTARGS], env=kit_env(bins),
                            capture_output=True, timeout=60)
    # The bundled legacy patcher returns 1 on successful completion.
    require(result.returncode in (0, 1) and destination.is_file()
            and BOOTARGS.encode() + b'\0' in destination.read_bytes()
            and b'main: Quitting...' in result.stdout + result.stderr,
            'Restore iBEC patch failed')


def patch_asr(data):
    require(data[:4] == b'\xce\xfa\xed\xfe', 'ASR must be ARM Mach-O')
    p = locate(data, ASR_ANCHOR) + 16
    # Common image-authentication failure -> existing success cleanup, same extent.
    candidate = data[:p] + bytes.fromhex('fff7ebbf') + data[p + 4:]
    candidate, pages = resign(candidate)
    verify_signature(candidate)
    return candidate, {'feature_offset': p, 'code_pages_updated': pages}


def patch_restored(data):
    require(data[:4] == b'\xce\xfa\xed\xfe', 'Restored must be ARM Mach-O')
    start = locate(data, RESTORED_ANCHOR)
    end = start + 0x27e
    require(data[end:end + len(RESTORED_EPILOGUE)] == RESTORED_EPILOGUE, 'Restored ticket epilogue layout changed')
    p = start + 12
    # Only the NULL-ticket path: r4=0, branch to existing stack-canary epilogue.
    # The present-ticket type/hash checks are unchanged. NOR flashing is disabled.
    candidate = data[:p] + bytes.fromhex('002400f036b9') + data[p + 6:]
    candidate, pages = resign(candidate)
    verify_signature(candidate)
    return candidate, {'feature_offset': p, 'code_pages_updated': pages,
                       'scope': 'NULL APTicket only; existing error and non-NULL paths retained'}


def check_components(kernel, devicetree, target="N49AP"):
    raw = extract_img3_data(kernel, None, None)
    if raw.startswith(b'complzss'):
        raw = decompress_complzss(raw)[0]
    require(raw[:4] == b'\xce\xfa\xed\xfe' and b'Darwin Kernel Version 13.' in raw,
            'Expected a patched iOS 6 ARM kernel, not an iOS 7 kernel')
    dt = parse_tree(extract_img3_data(devicetree, None, None))
    root = dt
    require(any(p['name'] == 'compatible' and (target+'\x00').encode() in bytes.fromhex(p['value'])
                for p in root['properties']), 'DeviceTree must identify '+target)


def check_prepare_space(a):
    # HFS working copy, worst-case DMG and IPSW copy coexist during preparation.
    mib = 1024 * 1024
    root_size = a.rootfs_hfs.stat().st_size + 128 * mib
    ramdisk_size = max(40 * mib, a.ramdisk_hfs.stat().st_size + 8 * mib)
    required = 3 * root_size + 3 * ramdisk_size + 256 * mib
    directory = a.out.resolve().parent
    while not directory.exists():
        directory = directory.parent
    free = shutil.disk_usage(directory).free
    require(free >= required,
            'Insufficient disk space at ' + str(directory) + ': '
            + f'{free / (1024 ** 3):.2f} GiB available; reserve at least '
            + f'{required / (1024 ** 3):.2f} GiB for firmware preparation. '
            + 'Free space or use --work on another disk.')


def reset_incomplete_session(a, components):
    require(not a.out.is_symlink(), 'Session output must not be a symlink')
    if not a.out.exists():return
    require(getattr(a, 'retry_incomplete', False),
            'Output directory already exists: ' + str(a.out)
            + '. Use --retry-incomplete to rebuild a failed session.')
    require(a.out.is_dir() and not (a.out / 'restore.json').exists(),
            'Refusing to replace a completed session: ' + str(a.out))
    # Retry only our generated output; never discard unknown files or source inputs.
    output = a.out.resolve()
    for name in ['bundle', 'rootfs_hfs', 'ramdisk_hfs', 'ramdisk_template', 'ibec_raw', 'baseband_firmware', 'baseband_source', 'wifi_firmware_dir']:
        source = getattr(a, name, None)
        require(source is None or not source.resolve().is_relative_to(output),
                'Source inputs must be outside the failed session: ' + name)
    files = set(components.values()) | {'RootFS.hfs', 'RestoreRamDisk.hfs', 'Restore.plist', 'Restore.ipsw'}
    files.update({'Firmware/Baseband/Mav7personalized.zip', 'Firmware/Baseband/personalization.json'})
    files.update('Firmware/Baseband/'+name for name in ['Baseband.bbfw','BuildManifest.plist','identity.plist','source.json'])
    files.add(str(Path(components['devicetree']).parent / 'manifest'))
    directories = {str(parent) for name in files for parent in Path(name).parents if str(parent) != '.'}
    for path in a.out.rglob('*'):
        relative = path.relative_to(a.out).as_posix()
        require(not path.is_symlink() and
                ((path.is_file() and relative in files) or (path.is_dir() and relative in directories)),
                'Unknown file in failed session; retained for inspection: ' + str(path))
    print('Rebuilding incomplete session: ' + str(a.out), file=sys.stderr)
    shutil.rmtree(a.out)


def prepare(a):
    bins = external_tools(a)
    require_tools(bins, ['hfsplus', 'xpwntool', 'iBoot32Patcher'] +
                  ([] if getattr(a, 'dmg_tool', None) else ['dmg']))
    if getattr(a, 'dmg_tool', None):
        require_tools(a.dmg_tool.resolve().parent, [a.dmg_tool.name])
    bundle = a.bundle.resolve()
    with stage('Verify patch bundle: ' + str(bundle)):
        report = patchctl.verify_bundle(bundle)
    target = bundle_target(report); board = target['HardwareModel'].lower(); short = board[:-2]
    components = components_for(target); all_flash = str(Path(components['devicetree']).parent)+'/'
    wifi = wifi_files(a.wifi_firmware_dir,target['ProductType']) if getattr(a, 'wifi_firmware_dir', None) else []
    wifi_candidate = any(row['id'] == 'kernel-wifi-candidate' for row in report['files'])
    require(not wifi_candidate or wifi,
            'WiFi candidate requires --wifi-firmware-dir containing model-matched 43342a0 donor files')
    require(not wifi or wifi_candidate, '43342a0 donor firmware requires the WiFi candidate kernel')
    wifi_compatibility = None
    if wifi_candidate:
        from wifi import check as check_wifi
        wifi_compatibility = check_wifi((bundle / 'boot/kernelcache.macho').read_bytes(),
                                       (bundle / 'boot/DeviceTree.dtb').read_bytes(),
                                       target['ProductType'], [rel for rel, _ in wifi])
    baseband = any(row['id'] == 'commcenter-runtime' for row in report['files'])
    baseband_ecid = getattr(a, 'baseband_ecid', None)
    baseband_source = getattr(a, 'baseband_source', None)
    native = None
    baseband_receipt = None
    require(baseband or not a.baseband_firmware, 'Baseband firmware requires the CommCenter runtime patch pair')
    require(baseband or not baseband_source, 'Native baseband source requires the CommCenter runtime patch pair')
    if baseband:
        require(a.baseband_firmware or baseband_source, 'CommCenter requires a native baseband source or personalized ZIP')
        if baseband_source:
            from baseband import native_source
            require(baseband_ecid, 'Native baseband source requires --baseband-ecid')
            native = native_source(baseband_source, target['ProductType'], baseband_ecid)
        if a.baseband_firmware:
            patchctl.validate_baseband(a.baseband_firmware)
        if a.baseband_firmware and (Path(a.baseband_firmware).parent / 'personalization.json').is_file():
            from baseband import receipt
            require(baseband_ecid, 'Automatically signed baseband requires --baseband-ecid')
            baseband_receipt = receipt(a.baseband_firmware, target['ProductType'], baseband_ecid)
    # Validate all source artifacts before creating an output image.
    check_components((bundle / 'boot/kernelcache.img3').read_bytes(),
                     (bundle / 'boot/DeviceTree.img3').read_bytes(), target['HardwareModel'])
    check_prepare_space(a)
    reset_incomplete_session(a, components)
    a.out.mkdir(parents=True)
    try:
        with tempfile.TemporaryDirectory(dir=a.out, prefix='prepare-') as temp:
            temp = Path(temp)
            root = temp / 'root'
            required_existing = set()
            manifest = patchctl.registry()
            recipes = {r['id']: r for r in manifest['recipes']}
            for row in report['files']:
                if not row['path'].startswith('rootfs/'):
                    continue
                for ident in row.get('original_inputs', recipes[row['id']]['inputs']):
                    spec = manifest['inputs'].get(ident, {})
                    if ident.startswith(('n41-', 'n42-')) and spec.get('rootfs_path'):
                        required_existing.add(spec['rootfs_path'].lstrip('/'))
            required = {'System/Library/CoreServices/SystemVersion.plist',
                        'System/Library/CoreServices/SpringBoard.app/SpringBoard',
                        'private/etc/fstab'}
            for recipe in report['files']:
                if recipe['path'].startswith('rootfs/'):
                    required.add(recipe['path'][7:])
            for daemon in ['mediaserverd', 'SpringBoard', 'locationd', 'CommCenter', 'BTServer', 'BlueTool']:
                required.add('System/Library/LaunchDaemons/com.apple.' + daemon + '.plist')
            # Optional new runtime paths are absent in a stock image. Extract only existing originals.
            for rel in sorted(required | required_existing):
                try:
                    hfs_extract(bins, a.rootfs_hfs, rel, root / rel,
                                optional=rel not in required_existing | {
                                    'System/Library/CoreServices/SystemVersion.plist',
                                    'System/Library/CoreServices/SpringBoard.app/SpringBoard', 'private/etc/fstab'})
                except (subprocess.CalledProcessError, ValueError):
                    if rel in required_existing | {'System/Library/CoreServices/SystemVersion.plist',
                               'System/Library/CoreServices/SpringBoard.app/SpringBoard', 'private/etc/fstab'}:
                        raise
            for name in ['N42AP.plist', 'N41AP.plist']:
                rel = 'System/Library/CoreServices/SpringBoard.app/' + name
                try:
                    hfs_extract(bins, a.rootfs_hfs, rel, root / rel, optional=True)
                except (subprocess.CalledProcessError, ValueError):
                    pass
            version = plistlib.loads((root / 'System/Library/CoreServices/SystemVersion.plist').read_bytes())
            require(version.get('ProductVersion') in ['6.1.3', '6.1.4'], 'Source filesystem must be iOS 6.1.3 or 6.1.4')
            require(version.get('ProductVersion') == report['target'].get('ProductVersion'), 'Rootfs version differs from the patch bundle')
            activation_report = None
            activation_file = None
            if getattr(a, 'activation', 'hacktivate') == 'hacktivate':
                from activation import patch
                hfs_extract(bins, a.rootfs_hfs, 'usr/libexec/lockdownd', temp / 'lockdownd.original')
                with stage('Apply lockdownd activation patch'):
                    activated, activation_report = patch((temp / 'lockdownd.original').read_bytes(), version['ProductVersion'])
                activation_file = temp / 'lockdownd.patched'
                activation_file.write_bytes(activated)
            jailbreak_report = None
            bootstrap_tar = None
            if getattr(a, 'jailbreak', 'yes') == 'yes':
                from jailbreak import bootstrap
                bootstrap_tar = temp / 'jailbreak.tar'
                with stage('Prepare jailbreak bootstrap'):
                    jailbreak_report = bootstrap(bootstrap_tar)
            ops = patchctl.rootfs_plan(bundle, root, a.baseband_firmware, report=report, baseband_source=baseband_source)
            require(ops, 'No patches selected')
            system = a.out / 'RootFS.hfs'
            with stage('Copy source RootFS: ' + str(system)):
                source_layout = copy_hfs(a.rootfs_hfs, system)
            # Make room for runtime additions and personalized baseband without changing the source.
            size = (system.stat().st_size + 128 * 1024 * 1024 + 4095) // 4096 * 4096
            with stage('Expand RootFS for runtime patches'):
                run(bins, 'hfsplus', system, 'grow', size)
            for i, op in enumerate(ops):
                log(f'RootFS patch [{i + 1}/{len(ops)}]: {op["path"]}')
                source = Path(op['source']) if op['source'] else temp / ('file-' + str(i))
                if op['source'] is None:
                    source.write_bytes(op['data'])
                hfs_add(bins, system, op['path'], source, op['mode'])
            if bootstrap_tar:
                with stage('Install jailbreak bootstrap into RootFS'):
                    run(bins, 'hfsplus', system, 'untar', bootstrap_tar, timeout=600)
                initialize = Path(__file__).resolve().parents[2] / 'patches/jailbreak/initialize.sh'
                hfs_add(bins, system, 'usr/libexec/project5c-jailbreak-initialize', initialize, 0o755)
                daemon = temp / 'jailbreak.plist'
                daemon.write_bytes(plistlib.dumps(dict(Label='org.project5c.jailbreak', ProgramArguments=['/bin/bash', '/usr/libexec/project5c-jailbreak-initialize'], RunAtLoad=True, StartInterval=60)))
                hfs_add(bins, system, 'System/Library/LaunchDaemons/org.project5c.jailbreak.plist', daemon, 0o644)
                for rel in jailbreak_report['essential_paths']:
                    check = temp / ('jb-check-' + Path(rel).name)
                    hfs_extract(bins, system, rel, check)
                    require(digest(check) == jailbreak_report['essential_sha256'][rel], 'Jailbreak readback hash differs: ' + rel)
                writable_fstab = temp / 'jailbreak.fstab'
                writable_fstab.write_bytes(b'/dev/disk0s1s1 / hfs rw 0 1\n/dev/disk0s1s2 /private/var hfs rw,nosuid,nodev 0 2\n')
                hfs_add(bins, system, 'private/etc/fstab', writable_fstab, 0o644)
            if activation_file:
                hfs_add(bins, system, 'usr/libexec/lockdownd', activation_file, 0o755)
                hfs_extract(bins, system, 'usr/libexec/lockdownd', temp / 'lockdownd.readback')
                require(digest(temp / 'lockdownd.readback') == activation_report['output_sha256'], 'Hacktivation readback failed')
            for rel, source in wifi:
                hfs_add(bins, system, rel, source, 0o644)
                readback = temp / ('wifi-check-' + source.name)
                hfs_extract(bins, system, rel, readback)
                require(digest(readback) == digest(source), 'WiFi firmware readback differs: ' + rel)
            for key, source in [('kernel', bundle / 'boot/kernelcache.img3'),
                                ('devicetree', bundle / 'boot/DeviceTree.img3'),
                                ('ibss', bundle / 'boot/iBSS.dfu'), ('ibec', bundle / 'boot/iBEC.dfu')]:
                dest = a.out / components[key]
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, dest)
            # Restore iBEC must contain RAM-root boot arguments; installed-system iBEC is unsuitable.
            ibec_data = a.ibec_raw.read_bytes()
            require(b'iBoot-' in ibec_data and ('iBEC for '+board).encode() in ibec_data,
                    'Expected decrypted iBEC belonging to '+target['HardwareModel'])
            with stage('Patch restore iBEC boot arguments and package IMG3'):
                patch_restore_ibec(bins, a.ibec_raw, temp / 'iBEC.patched')
                run(bins, 'xpwntool', temp / 'iBEC.patched', a.out / components['ibec'], '-t', bundle / 'boot/iBEC.dfu')
            # Restored installs this patched kernel to the system as well as RAM-booting it.
            hfs_add(bins, system, 'System/Library/Caches/com.apple.kernelcaches/kernelcache',
                    a.out / components['kernel'], 0o644)
            with stage('Build and verify RootFS.dmg (large image)'):
                run(bins, str(a.dmg_tool.resolve()) if getattr(a, 'dmg_tool', None) else 'dmg',
                    'build', system, a.out / components['rootfs'], timeout=1800)
                dmg_report = check_system_dmg(a.out / components['rootfs'])
            ramdisk = a.out / 'RestoreRamDisk.hfs'
            with stage('Copy and expand restore ramdisk'):
                copy_hfs(a.ramdisk_hfs, ramdisk)
                run(bins, 'hfsplus', ramdisk, 'grow', max(40 * 1024 * 1024, ramdisk.stat().st_size + 8 * 1024 * 1024))
            # The restore kernel uses the same BCM43342 personalities as System.
            # Keep its firmware available before the installed System is mounted.
            for rel, source in wifi:
                hfs_add(bins, ramdisk, rel, source, 0o644)
            original_asr = temp / 'asr'
            hfs_extract(bins, ramdisk, 'usr/sbin/asr', original_asr)
            with stage('Patch ramdisk ASR image verification'):
                patched, asr_report = patch_asr(original_asr.read_bytes())
            original_asr.write_bytes(patched)
            hfs_add(bins, ramdisk, 'usr/sbin/asr', original_asr, 0o755)
            # Keep the stock iOS 6 restored. Supply N49 options using kit's ramdisk technique.
            hfs_extract(bins, ramdisk, 'usr/local/bin/restored_external', temp / 'restored')
            require(b'FormatForLwVM' in (temp / 'restored').read_bytes(), 'Restored lacks LwVM format support')
            with stage('Patch restored for the target device'):
                patched_restored, restored_report = patch_restored((temp / 'restored').read_bytes())
            (temp / 'restored').write_bytes(patched_restored)
            hfs_add(bins, ramdisk, 'usr/local/bin/restored_external', temp / 'restored', 0o755)
            options = dict(FLASH, SystemPartitionSize=max(2048, (size + 1048575) // 1048576 + 256))
            (temp / 'options.plist').write_bytes(plistlib.dumps(options))
            for name in ['options.plist', 'options.'+short+'.plist']:
                hfs_add(bins, ramdisk, 'usr/local/share/restore/' + name, temp / 'options.plist', 0o644)
            # The source template may be encrypted; omit KBAG for our plaintext HFS.
            from features import wrap_img3
            with stage('Package and verify restore ramdisk IMG3'):
                ramdisk_img3 = wrap_img3(a.ramdisk_template.read_bytes(), ramdisk.read_bytes(), plaintext=True)
                check_ramdisk(ramdisk_img3)
                (a.out / components['ramdisk']).write_bytes(ramdisk_img3)
            restore = dict(DeviceClass='iPhone', DeviceMap=[dict(BDID=target['board_id'], CPID=0x8950,
                           BoardConfig=board, Platform='s5l8950x', SCEP=16)],
                           FirmwareDirectory='Firmware', ProductType=target['ProductType'],
                           SupportedProductTypes=[target['ProductType']],
                           ProductVersion=version['ProductVersion'], ProductBuildVersion=version['ProductBuildVersion'],
                           KernelCachesByTarget={short: {'Release': components['kernel']}},
                           RestoreRamDisks={'User': components['ramdisk']},
                           SystemRestoreImages={'User': components['rootfs']},
                           MinimumSystemPartition={components['rootfs']: options['SystemPartitionSize']})
            if native:
                import copy
                bb_identity = copy.deepcopy(native['identity'])
                bb_identity['Manifest']['BasebandFirmware']['Info']['Path'] = 'Firmware/Baseband/Baseband.bbfw'
                restore['Project5CBasebandIdentity'] = bb_identity
            (a.out / 'Restore.plist').write_bytes(plistlib.dumps(restore))
            (a.out / all_flash / 'manifest').write_text('DeviceTree.'+board+'.img3\n')
            baseband_files = []
            if baseband:
                # Package the native BBFW/manifest and any optional runtime ZIP.
                directory = a.out / 'Firmware/Baseband'
                directory.mkdir(parents=True)
                if a.baseband_firmware:
                    shutil.copyfile(a.baseband_firmware, directory / 'Mav7personalized.zip')
                    baseband_files.append('Firmware/Baseband/Mav7personalized.zip')
                if native:
                    for name in ['Baseband.bbfw','BuildManifest.plist','identity.plist','source.json']:
                        shutil.copyfile(baseband_source / name, directory / name)
                        baseband_files.append('Firmware/Baseband/'+name)
                if baseband_receipt:
                    (directory / 'personalization.json').write_text(json.dumps(baseband_receipt, indent=2) + '\n')
                    baseband_files.append('Firmware/Baseband/personalization.json')
            with stage('Package Restore.ipsw: ' + str(a.out / 'Restore.ipsw')):
                with zipfile.ZipFile(a.out / 'Restore.ipsw', 'w', compression=zipfile.ZIP_STORED) as z:
                    for rel in ['Restore.plist', all_flash + 'manifest', *components.values(), *baseband_files]:
                        z.write(a.out / rel, rel)
            with stage('Hash generated images and save restore.json'):
                result = dict(schema=1, experimental=True, physical_restore_verified=False,
                              activation=activation_report, jailbreak=jailbreak_report,
                              target=target['HardwareModel'], source_version=version, rootfs_patch_files=[op['path'] for op in ops],
                              source_hfs_layout=source_layout,
                              selected_artifacts=[r['id'] for r in report['files']], asr=asr_report, restored=restored_report,
                              wifi_firmware_files=[rel for rel, _ in wifi],
                              wifi_firmware_sha256={rel: digest(source) for rel, source in wifi},
                              wifi_ramdisk_firmware_sha256={rel: digest(source) for rel, source in wifi},
                              wifi_compatibility=wifi_compatibility,
                              baseband_firmware_sha256=digest(a.baseband_firmware) if a.baseband_firmware else None,
                              baseband_ecid=baseband_ecid if baseband else None,
                              baseband_native=bool(native),
                              baseband_source_sha256=digest(baseband_source/'source.json') if native else None,
                              baseband_version=native['spec']['version'] if native else None,
                              baseband_files=baseband_files, baseband_personalization=baseband_receipt,
                              bluetooth_launch_environment={'DYLD_INSERT_LIBRARIES': '', '_MSSafeMode': '1'} if any(r['id'] == 'bluetooth' for r in report['files']) else None,
                              system_dmg=dmg_report,
                              restore_options=options, boot_args=BOOTARGS, components=components,
                              rootfs_contains_patched_kernel=True, nand_writes=False,
                              integrity_receipts={rel: digest(a.out / rel) for rel in [*components.values(), *baseband_files, 'Restore.ipsw']})
                (a.out / 'restore.json').write_text(json.dumps(result, indent=2) + '\n')
        return result
    except BaseException:
        # Keep failed local artifacts for diagnosis, but never mark them ready.
        (a.out / 'restore.json').unlink(missing_ok=True)
        raise


def exact(sock, n):
    data = b''
    while len(data) < n:
        part = sock.recv(n - len(data))
        require(part, 'Connection closed before complete protocol message')
        data += part
    return data


def mux_request(sock, payload):
    raw = plistlib.dumps(dict(ClientVersionString='restore6', ProgName='restore6', kLibUSBMuxVersion=3, **payload))
    sock.sendall(struct.pack('<4I', 16 + len(raw), 1, 8, 1) + raw)
    size, version, kind, tag = struct.unpack('<4I', exact(sock, 16))
    require(16 <= size <= 4 * 1024 * 1024 and (version, kind, tag) == (1, 8, 1), 'Invalid usbmuxd reply')
    return plistlib.loads(exact(sock, size - 16))


def mux_socket():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(15)
    try:
        s.connect('/var/run/usbmuxd')
    except BaseException:
        s.close()
        raise
    return s


def restored_probe(ecid, target="N49AP"):
    # Only QueryType / QueryValue; never StartRestore or Reboot.
    with mux_socket() as s:
        devices = mux_request(s, {'MessageType': 'ListDevices'}).get('DeviceList', [])
    found = []
    for device in devices:
        if device.get('Properties', {}).get('ConnectionType') != 'USB':
            continue
        try:
            with mux_socket() as s:
                reply = mux_request(s, {'MessageType': 'Connect', 'DeviceID': device['DeviceID'], 'PortNumber': socket.htons(62078)})
                require(reply.get('Number') == 0, 'usbmuxd connection rejected')
                def query(request):
                    raw = plistlib.dumps(dict(Label='restore6', **request))
                    s.sendall(struct.pack('>I', len(raw)) + raw)
                    size = struct.unpack('>I', exact(s, 4))[0]
                    require(0 < size <= 4 * 1024 * 1024, 'Invalid restored reply size')
                    return plistlib.loads(exact(s, size))
                kind = query({'Request': 'QueryType'})
                if kind.get('Type') != 'com.apple.mobile.restored':
                    continue
                info = query({'Request': 'QueryValue', 'QueryKey': 'HardwareInfo'}).get('HardwareInfo', {})
                model = kind.get('HardwareModel') or query({'Request': 'QueryValue', 'QueryKey': 'HardwareModel'}).get('HardwareModel', '')
                validate_device(kind, info, model, ecid, target)
                found.append({'device_id': device['DeviceID'], 'protocol': kind['RestoreProtocolVersion'],
                              'hardware_model': model, 'ecid': info['UniqueChipID']})
        except (OSError, ValueError, plistlib.InvalidFileException):
            continue
    require(len(found) == 1, 'Expected exactly one USB ' + str(target) + ' iOS 6 restored device matching --ecid')
    return found[0]


def validate_device(kind, info, model, ecid, target="N49AP"):
    expected = target_for(target)
    require(kind.get('Type') == 'com.apple.mobile.restored' and kind.get('RestoreProtocolVersion') == 12,
            'Expected iOS 6 restored protocol 12')
    require(str(model).lower() == expected['HardwareModel'].lower() and info.get('ChipID') == 0x8950 and info.get('BoardID') == expected['board_id']
            and info.get('UniqueChipID') == ecid and ecid > 0, 'Restored identity / ECID mismatch')


def check_ramdisk(data):
    image = parse_img3(data)
    require(image.image_type == 'rdsk', 'Restore ramdisk must be an rdsk IMG3')
    require(not any(tag.name == 'KBAG' for tag in image.tags),
            'Restore ramdisk has encryption tags on plaintext HFS; rebuild this session before booting')
    payloads = [tag for tag in image.tags if tag.name == 'DATA']
    require(len(payloads) == 1, 'Restore ramdisk must have exactly one DATA tag')
    payload = payloads[0].payload[:payloads[0].data_size]
    require(len(payload) >= 2048 and payload[1024:1028] in (b'H+\x00\x04', b'HX\x00\x05'),
            'Restore ramdisk DATA must contain a plaintext HFS volume')
    block_size, blocks = struct.unpack_from('>II', payload, 1064)
    require(block_size >= 512 and not block_size & (block_size - 1)
            and blocks > 0 and block_size * blocks <= len(payload) // 4096 * 4096,
            'Restore ramdisk HFS extent exceeds its memory-disk backing')
    signatures = [tag for tag in image.tags if tag.name == 'SHSH']
    require((not signatures and image.shsh_offset == 0) or
            (len(signatures) == 1 and signatures[0].offset == 20 + image.shsh_offset),
            'Restore ramdisk IMG3 signature offset is inconsistent')


def session(path):
    path = path.resolve()
    report = json.loads((path / 'restore.json').read_text())
    require('restored' in report, 'Session lacks the no-ticket restored patch; prepare a new session')
    require(report.get('boot_args') == BOOTARGS, 'Unexpected recovery boot arguments')
    target=target_for(report['target']); components=components_for(target)
    require(report.get('components',components)==components,'Unexpected target component layout')
    require(report['restore_options'] == dict(FLASH, SystemPartitionSize=report['restore_options']['SystemPartitionSize']),
            'Baseband transfer must be disabled; rebuild this restore session')
    check_ramdisk((path / components['ramdisk']).read_bytes())
    bb_files = report.get('baseband_files', [])
    require(set(bb_files) <= {'Firmware/Baseband/Mav7personalized.zip', 'Firmware/Baseband/personalization.json',
                            *('Firmware/Baseband/'+name for name in ['Baseband.bbfw','BuildManifest.plist','identity.plist','source.json'])}, 'Unexpected baseband artifact layout')
    for rel in [*components.values(), *bb_files, 'Restore.ipsw']:
        require((path / rel).is_file(), 'Missing restore component: ' + rel)
        require(digest(path / rel) == report['integrity_receipts'][rel], 'Generated artifact changed: ' + rel)
    if 'Firmware/Baseband/Mav7personalized.zip' in bb_files:
        patchctl.validate_baseband(path / 'Firmware/Baseband/Mav7personalized.zip')
        require(digest(path / 'Firmware/Baseband/Mav7personalized.zip') == report['baseband_firmware_sha256'], 'Bundled baseband differs from RootFS input')
    if report.get('baseband_native'):
        from baseband import native_source
        native = native_source(path/'Firmware/Baseband', target['ProductType'], report['baseband_ecid'])
        require(digest(path/'Firmware/Baseband/source.json') == report['baseband_source_sha256'], 'Native baseband source receipt changed')
        import copy
        expected = copy.deepcopy(native['identity'])
        expected['Manifest']['BasebandFirmware']['Info']['Path'] = 'Firmware/Baseband/Baseband.bbfw'
        require(plistlib.loads((path/'Restore.plist').read_bytes()).get('Project5CBasebandIdentity') == expected, 'Native baseband restore identity changed')
    check_components((path / components['kernel']).read_bytes(), (path / components['devicetree']).read_bytes(), target['HardwareModel'])
    if 'kernel-wifi-candidate' in report.get('selected_artifacts', []):
        from wifi import check as check_wifi
        check_wifi((path / components['kernel']).read_bytes(),
                   (path / components['devicetree']).read_bytes(),
                   target['ProductType'], report.get('wifi_firmware_files', []))
        require(bool(report.get('wifi_firmware_sha256')) and
                report.get('wifi_ramdisk_firmware_sha256') == report['wifi_firmware_sha256'],
                'Restore ramdisk lacks matching WiFi firmware; prepare a new session')
    return report


def boot(a):
    report = session(a.session)
    target = target_for(report['target']); components=components_for(target)
    bins = external_tools(a)
    def identify(mode):
        output = run(bins, 'irecovery', '-q').decode()
        fields = dict(re.findall(r'^([A-Z]+):\s*(.+)$', output, re.M))
        require(int(fields.get('ECID', '0'), 0) == a.ecid and int(fields.get('CPID', '0'), 0) == 0x8950
                and int(fields.get('BDID', '0'), 0) == target['board_id'] and fields.get('MODE', '').startswith(mode), 'USB ' + target['HardwareModel'] + ' identity mismatch')
        return fields
    commands = [['irecovery', '-f', str(a.session / components['ibec'])],
                ['irecovery', '-c', 'setenv boot-args ' + BOOTARGS]]
    for key, command in [('ramdisk', 'ramdisk'), ('devicetree', 'devicetree'), ('kernel', 'bootx')]:
        commands += [['irecovery', '-f', str(a.session / components[key])], ['irecovery', '-c', command]]
    if a.execute:
        with stage('Prepare DFU and upload matching iBSS'):
            prepare_pwned_ibss(bins, a.ecid, target, a.session / components['ibss'])
        for i, cmd in enumerate(commands):
            with stage(f'Restore boot [{i + 1}/{len(commands)}]: ' + ' '.join(cmd[1:])):
                run(bins, *cmd, timeout=60)
            time.sleep(2)
            if i == 0:
                identify('Recovery')
    return {'preview': not a.execute, 'nand_writes': False, 'tools_directory': str(bins), 'commands': commands}


def flash(a):
    report=session(a.session); target=target_for(report['target']); components=components_for(target)
    require(not report.get('baseband_ecid') or report['baseband_ecid'] == a.ecid, 'Personalized baseband belongs to another ECID')
    require(getattr(a, 'idevicerestore', None), '--idevicerestore is required; see README.md')
    host = Path(a.idevicerestore).resolve()
    command = [str(host), '-c', '-e', '-R', '-x', '-y',
               '-i', hex(a.ecid), '--cache-path', str(a.session / 'cache'), str(a.session / 'Restore.ipsw')]
    native_bb = bool(report['restore_options']['UpdateBaseband'])
    if native_bb:
        from baseband import TSS_URL
        command[1:1] = ['--server', TSS_URL]
    if not a.execute:
        return {'preview': True, 'erases_system_and_data': True, 'preserve_nor': True,
                'update_baseband': native_bb, 'command': command}
    require(a.erase, 'Actual restore requires --execute --erase (erases all System/Data and dual boot)')
    check_system_dmg(a.session / components['rootfs'])
    env = tool_env(host.parent)
    version = subprocess.check_output([str(host), '--version'], env=env, text=True, timeout=15)
    if target['HardwareModel']=='N48AP':require('1.0.0-native6-5c' in version,'N48 requires a newly built 5c restore host')
    require('1.0.0-native6' in version, 'Use the native6 host built by patches/host/build_restore_host.py')
    require('native6-5c-no-baseband' in version,
            'Use the updated restore host that blocks baseband transfer')
    probe = restored_probe(a.ecid, target['HardwareModel'])
    # -x remains a NOR guard; upstream's BasebandData handler is independent of it.
    logfile = a.session / 'restore.log'
    require(not logfile.exists(), 'A previous restore.log exists; preserve it and use a new session')
    saved_bb = a.session / 'personalized-baseband/Baseband.bbfw'
    if native_bb:
        saved_bb.parent.mkdir(exist_ok=True)
        require(not any(saved_bb.parent.iterdir()), 'Previous baseband signing output exists; use a new session')
    with logfile.open('x') as log:
        env = tool_env(host.parent)
        # Capture the exact bytes sent by the native handler, without another RD.
        env.pop('PROJECT5C_BB_SAVE', None)
        if native_bb:
            env['PROJECT5C_BB_SAVE'] = str(saved_bb)
        launch = (['stdbuf', '-oL', '-eL'] if shutil.which('stdbuf') else []) + command
        p = subprocess.Popen(launch, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            for line in p.stdout:
                log.write(line); log.flush(); print(line, end='', file=sys.stderr, flush=True)
            code = p.wait()
        finally:
            if p.poll() is None:
                p.terminate()
                try:
                    p.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    p.kill(); p.wait()
    text = logfile.read_text()
    finished = code == 0 and 'Status: Restore Finished' in text and 'Not sending NORData' not in text
    result = dict(returncode=code, restore_finished=finished, device_probe=probe,
                  physical_restore_verified=finished, normal_boot_verified=False,
                  activation_verified=False, tethered_boot_required=True,
                  baseband_update_requested=native_bb,
                  physical_baseband_update_verified=native_bb and finished and
                      'Updating Baseband completed.' in text and 'Done sending BasebandData' in text,
                  personalized_baseband_sha256=digest(saved_bb) if saved_bb.is_file() else None)
    (a.session / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    require(finished, 'Restore did not report final success; inspect local restore.log and result.json')
    require(not native_bb or result['physical_baseband_update_verified'],
            'Restore finished without verified native baseband update; inspect restore.log and result.json')
    return result


def install(a):
    """Boot a prepared restore session, wait for matching restored, then flash once."""
    report=session(a.session); target=target_for(report['target']); components=components_for(target)
    after_restore = 'Enter physical DFU again, then run patchctl.py ramboot with the matching bundle.'
    if not a.execute:
        return {'preview': True, 'erases_system_and_data': True, 'boot': boot(a), 'flash': flash(a),
                'after_restore': after_restore}
    require(a.erase, 'install requires --execute --erase before any USB operation')
    bins = external_tools(a)
    require_boot_tools(bins)
    host = a.idevicerestore.resolve()
    require_tools(host.parent, [host.name])
    check_system_dmg(a.session / components['rootfs'])
    require(not (a.session / 'restore.log').exists(), 'Previous restore log exists; preserve it and use a new session')
    env = tool_env(host.parent)
    version = subprocess.check_output([str(host), '--version'], env=env, text=True, timeout=15)
    if target['HardwareModel']=='N48AP':require('1.0.0-native6-5c' in version,'N48 requires a newly built 5c restore host')
    require('1.0.0-native6' in version, 'Expected the patched native6 restore host')
    require('native6-5c-no-baseband' in version,
            'Use the updated restore host that blocks baseband transfer')
    log('Starting restore ramdisk; no system image has been flashed yet.')
    boot(a)
    deadline = time.monotonic() + a.wait_seconds
    with stage(f'Wait for matching restored (timeout {a.wait_seconds}s)'):
        while True:
            try:
                restored_probe(a.ecid, target['HardwareModel'])
                break
            except (OSError, ValueError) as error:
                if time.monotonic() >= deadline:
                    raise ValueError('Restore environment did not become ready; no flash started: ' + str(error))
                time.sleep(1)
    log('Matching restored is ready; flashing System/Data once.')
    result = flash(a)
    return result | {'after_restore': after_restore}


def show_result(a, result):
    if a.command == 'prepare':
        log(f'Firmware prepared: {a.out / "Restore.ipsw"}; report: {a.out / "restore.json"}', 'DONE')
    elif result.get('preview'):
        log('Preview only; no USB writes performed.')
        if a.command == 'install':
            preview_commands(result['boot']['commands'])
            preview_commands([result['flash']['command']])
        elif a.command == 'flash':
            preview_commands([result['command']])
        else:
            preview_commands(result.get('commands', []))
    elif a.command in ('flash', 'install'):
        log(f'Restore finished; log: {a.session / "restore.log"}; report: {a.session / "result.json"}', 'DONE')
        log(result.get('after_restore', 'Enter physical DFU and run tethered boot.'))
    elif a.command == 'boot':
        log('Restore ramdisk boot commands sent; awaiting restored.', 'DONE')
    else:
        log(f'{a.command}: passed; target={result.get("target", "matching device")}', 'DONE')


def verify_session(a):
    with stage('Verify restore session images and receipts: ' + str(a.session)):
        report = session(a.session)
    return {'passed': True, 'target': report['target'], 'device_accessed': False}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest='command', required=True)
    q = sub.add_parser('prepare'); q.add_argument('--bundle', type=Path, required=True)
    q.add_argument('--activation', choices=['hacktivate', 'none'], default='hacktivate')
    q.add_argument('--jailbreak', choices=['yes', 'no'], default='yes')
    q.add_argument('--rootfs-hfs', type=Path, required=True); q.add_argument('--ramdisk-hfs', type=Path, required=True)
    q.add_argument('--ramdisk-template', type=Path, required=True); q.add_argument('--ibec-raw', type=Path, required=True); q.add_argument('--baseband-firmware', type=Path)
    q.add_argument('--baseband-ecid', type=lambda v: int(v, 0))
    q.add_argument('--baseband-source', type=Path, help='Original BBFW and manifest resources; modem transfer remains disabled')
    q.add_argument('--wifi-firmware-dir', type=Path, help='N49 donor usr/share/firmware/wifi/43342a0 directory; required for WiFi profile')
    q.add_argument('--out', type=Path, required=True)
    q.add_argument('--retry-incomplete', action='store_true', help='Rebuild incomplete generated output; completed sessions and unknown files are retained')
    group = q.add_mutually_exclusive_group(required=True)
    group.add_argument('--kit', type=Path, help='Use tools supplied by Legacy iOS Kit')
    group.add_argument('--tools-dir', type=Path, help='Standalone hfsplus, xpwntool, iBoot32Patcher directory')
    q.add_argument('--dmg-tool', type=Path, help='Explicit-zero xpwn DMG builder; see README.md')
    q = sub.add_parser('probe'); q.add_argument('--ecid', type=lambda v: int(v, 0), required=True); q.add_argument('--target', choices=['iPhone5,4','iPhone5,3'], default='iPhone5,4')
    q = sub.add_parser('verify'); q.add_argument('--session', type=Path, required=True)
    for name in ['boot', 'flash', 'install']:
        q = sub.add_parser(name); q.add_argument('--session', type=Path, required=True)
        if name in ['boot', 'install']:
            group = q.add_mutually_exclusive_group(required=True)
            group.add_argument('--kit', type=Path)
            group.add_argument('--tools-dir', type=Path, help='Standalone irecovery, a6meowing, gaster directory')
        else:
            q.add_argument('--kit', type=Path, help='Legacy argument accepted for compatibility; flash does not use Kit')
        q.add_argument('--ecid', type=lambda v: int(v, 0), required=True)
        q.add_argument('--execute', action='store_true'); q.add_argument('--lock', type=Path)
        if name in ['flash', 'install']:
            q.add_argument('--erase', action='store_true')
            q.add_argument('--idevicerestore', type=Path, required=True, help='Native restore host built by patches/host/build_restore_host.py')
        if name == 'install': q.add_argument('--wait-seconds', type=int, default=90, help='Bounded wait for restored after RAM boot (1-300 seconds)')
    for command_parser in sub.choices.values():
        command_parser.add_argument('--json', action='store_true', help='Print the full result report to stdout')
    a = p.parse_args()
    if getattr(a, 'ecid', 1) <= 0:
        p.error('Supply your own nonzero ECID')
    if not 1 <= getattr(a, 'wait_seconds', 90) <= 300: p.error('--wait-seconds must be 1-300')
    if hasattr(a, 'session'):
        a.session = a.session.resolve()
    try:
        handler = {'prepare': prepare, 'boot': boot, 'flash': flash, 'install': install,
                   'probe': lambda args: restored_probe(args.ecid,args.target),
                   'verify': verify_session}[a.command]
        if getattr(a, 'execute', False):
            lockpath = a.lock or Path.home() / '.cache/project5c-native6-device.lock'
            lockpath.parent.mkdir(parents=True,exist_ok=True)
            with lockpath.open('a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                result = handler(a)
        else:
            result = handler(a)
        if a.json:
            print(json.dumps(result, indent=2))
        else:
            show_result(a, result)
    except (OSError, ValueError, subprocess.SubprocessError, KeyError, patchctl.PatchError) as e:
        error_detail(e)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
