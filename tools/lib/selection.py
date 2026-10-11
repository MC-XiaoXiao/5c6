#!/usr/bin/env python3
"""Validate selected firmware identity before image generation or device access."""
import argparse
import json
from pathlib import Path
import plistlib
import sys


def normalize_extras(value):
    groups = list(filter(None, value.split(',')))
    if any(group not in ['gps', 'baseband'] for group in groups):
        raise ValueError('Runtime extras must be gps and/or baseband')
    return ','.join(sorted(set(groups)))


def runtime_policy(args):
    """Validate runtime resources even when a completed workspace is reused."""
    from patchctl import choose, registry, sha, validate_baseband
    from restore6 import wifi_files
    args.extras = normalize_extras(args.extras)
    if args.model == 'iPhone5,3' and 'gps' in args.extras.split(','):
        raise ValueError('GPS runtime currently requires iPhone5,4 / N49')
    active, _, _ = choose(registry(), args.profile, args.extras)
    receipt = {'model': args.model, 'version': args.version, 'activation': args.activation,
               'jailbreak': args.jailbreak == 'yes'}
    # Preserve legacy selection receipts for the unchanged baseline policy.
    if args.profile != 'native6-validated' or args.extras:
        receipt.update(profile=args.profile, extras=args.extras.split(',') if args.extras else [])
    if getattr(args, 'identity_only', False):
        return set(active), receipt
    if args.profile == 'native6-wifi-candidate':
        directory = args.wifi_firmware_dir or Path(__file__).resolve().parents[2] / ('donor/'+args.model+'/wifi/43342a0')
        receipt['wifi_firmware_sha256'] = {rel: sha(path) for rel, path in wifi_files(directory,args.model)}
    elif args.wifi_firmware_dir:
        raise ValueError('Wi-Fi firmware requires the Wi-Fi candidate profile')
    if 'baseband' in args.extras.split(','):
        source = getattr(args, 'baseband_source', None)
        if not args.baseband_firmware and not source:
            raise ValueError('CommCenter requires the latest native baseband source or a personalized ZIP')
        if args.baseband_firmware:
            validate_baseband(args.baseband_firmware)
            receipt['baseband_firmware_sha256'] = sha(args.baseband_firmware)
        if source:
            from baseband import native_source
            native_source(source, args.model, getattr(args, 'ecid', None))
            receipt['baseband_source_sha256'] = sha(source / 'source.json')
        if getattr(args, 'ecid', None):
            receipt['baseband_ecid'] = args.ecid
    elif args.baseband_firmware or getattr(args, 'baseband_source', None):
        raise ValueError('Baseband firmware requires the baseband runtime extra')
    return set(active), receipt


def main():
    if len(sys.argv) == 3 and sys.argv[1] == '--normalize-extras':
        print(normalize_extras(sys.argv[2]))
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', choices=['6.1.3', '6.1.4'], required=True)
    parser.add_argument('--model', choices=['iPhone5,3', 'iPhone5,4'], required=True)
    parser.add_argument('--ecid', type=lambda v: int(v, 0))
    parser.add_argument('--identity-only', action='store_true', help='Only check original input identity before modem signing')
    parser.add_argument('--activation', choices=['hacktivate', 'none'], default='hacktivate')
    parser.add_argument('--jailbreak', choices=['yes', 'no'], default='yes')
    parser.add_argument('--profile', choices=['native6-validated', 'native6-wifi-candidate'], default='native6-validated')
    parser.add_argument('--extras', default='')
    parser.add_argument('--wifi-firmware-dir', type=Path)
    parser.add_argument('--baseband-firmware', type=Path)
    parser.add_argument('--baseband-source', type=Path)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--inputs', type=Path)
    source.add_argument('--bundle', type=Path)
    source.add_argument('--session', type=Path)
    source.add_argument('--policy-only', action='store_true')
    parser.add_argument('--record', action='store_true')
    args = parser.parse_args()
    if args.identity_only and not args.inputs:
        parser.error('--identity-only requires --inputs; it cannot validate a completed bundle/session')
    selected, wanted_receipt = runtime_policy(args)
    if args.policy_only:
        if args.record:
            raise ValueError('--record requires --session')
        return
    board = {'iPhone5,3': 'N48AP', 'iPhone5,4': 'N49AP'}[args.model]
    if args.inputs:
        metadata = plistlib.loads((args.inputs / 'SystemVersion.plist').read_bytes())
    elif args.bundle:
        report = json.loads((args.bundle / 'build.json').read_text())
        metadata = report['target']
        if {row['id'] for row in report['files']} != selected:
            raise ValueError('Bundle patch profile/extras differ from the selection; choose a new workspace')
        if metadata.get('ProductType') != args.model or metadata.get('HardwareModel') != board:
            raise ValueError('Bundle model does not match the selected device')
    else:
        report = json.loads((args.session / 'restore.json').read_text())
        metadata = report['source_version']
        if report['target'] != board:
            raise ValueError('Restore session does not match the selected device')
        if bool(report.get('activation')) != (args.activation == 'hacktivate'):
            raise ValueError('Restore image activation policy differs from the selection')
        if bool(report.get('jailbreak')) != (args.jailbreak == 'yes'):
            raise ValueError('Restore image jailbreak policy differs from the selection')
        if set(report.get('selected_artifacts', [])) != selected:
            raise ValueError('Restore image patch profile/extras differ from the selection; choose a new workspace')
        for name in ['wifi_firmware_sha256', 'baseband_firmware_sha256', 'baseband_ecid', 'baseband_source_sha256']:
            if name in wanted_receipt and report.get(name) != wanted_receipt[name]:
                raise ValueError('Restore image runtime firmware differs from the selection: ' + name)
        if set(report.get('wifi_firmware_files', [])) != set(wanted_receipt.get('wifi_firmware_sha256', {})):
            raise ValueError('Restore image Wi-Fi firmware differs from the selection')
        if not args.record:
            receipt = json.loads((args.session / 'selection.json').read_text())
            if receipt != wanted_receipt:
                raise ValueError('Session selections differ; prepare a new session')
    if metadata.get('ProductVersion') != args.version:
        raise ValueError('Firmware version differs from the selection. Supply the matching original SystemVersion.plist.')
    if args.record:
        if not args.session:
            raise ValueError('--record requires --session')
        target = args.session / 'selection.json'
        with target.open('x') as stream:
            json.dump(wanted_receipt, stream, indent=2)
            stream.write('\n')
    print('Firmware identity checked: ' + args.model + ' / ' + args.version)


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, ValueError, KeyError, plistlib.InvalidFileException) as error:
        print('Selection check failed: ' + str(error), file=sys.stderr)
        sys.exit(2)
