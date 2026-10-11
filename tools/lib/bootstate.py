#!/usr/bin/env python3
"""Resolve the installed boot bundle for the connected device, without a version prompt."""
import argparse
import json
import os
from pathlib import Path
import sys

import patchctl
from targets import components_for, target_for


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['check', 'record', 'resolve'])
    parser.add_argument('--state', type=Path, required=True)
    parser.add_argument('--model', choices=['iPhone5,3', 'iPhone5,4'], required=True)
    parser.add_argument('--ecid', type=lambda value: int(value, 0), required=True)
    parser.add_argument('--work', type=Path)
    args = parser.parse_args()
    if args.ecid <= 0:
        raise ValueError('Invalid device ECID')
    state = args.state.resolve()
    receipt = state / (hex(args.ecid) + '.json')
    saved = None
    if args.command == 'resolve' and receipt.is_file():
        saved = json.loads(receipt.read_text())
        if saved['model'] != args.model or saved['ecid'] != args.ecid:
            raise ValueError('Saved boot identity differs from the connected device')
    if args.command in ['check', 'record']:
        if not args.work:
            raise ValueError('Recording requires a firmware workspace')
        work = args.work.resolve()
    elif saved:
        work = (state / saved['workspace']).resolve()
        if args.work and args.work.resolve() != work:
            raise ValueError('Requested workspace differs from this device\'s last successful restore: ' + str(work))
    elif args.work:
        work = args.work.resolve()
    else:
        raise ValueError('No installed boot bundle for this device. Flash first, or supply --work.')
    report = patchctl.verify_bundle(work / 'bundle', boot_only=args.command == 'resolve')
    target = report['target']
    board = {'iPhone5,3': 'N48AP', 'iPhone5,4': 'N49AP'}[args.model]
    if target.get('ProductType') != args.model or target.get('HardwareModel') != board:
        raise ValueError('Boot bundle does not match the connected model')
    if target.get('ProductVersion') not in ['6.1.3', '6.1.4']:
        raise ValueError('Unsupported boot firmware')
    if args.command in ['check', 'record'] or saved:
        session = json.loads((work / 'session/restore.json').read_text())
        if session['target'] != board or session['source_version']['ProductVersion'] != target['ProductVersion']:
            raise ValueError('Restored firmware differs from the boot bundle')
        components = components_for(target_for(board))
        for name, filename in [('kernel', 'kernelcache.img3'), ('devicetree', 'DeviceTree.img3')]:
            if patchctl.sha(work / 'bundle/boot' / filename) != session['integrity_receipts'][components[name]]:
                raise ValueError('Restored boot component differs from the boot bundle: ' + name)
    boot_hashes = {name: patchctl.sha(work / 'bundle/boot' / name)
                   for name in ['iBSS.dfu', 'iBEC.dfu', 'DeviceTree.img3', 'kernelcache.img3']}
    if args.command == 'record':
        result = json.loads((work / 'session/result.json').read_text())
        if not result.get('physical_restore_verified') or not result.get('restore_finished') or result.get('returncode') != 0:
            raise ValueError('Boot registration requires a successful restore')
        restored_ecid = result.get('device_probe', {}).get('ecid')
        if restored_ecid is not None and restored_ecid != args.ecid:
            raise ValueError('Successful restore belongs to a different device ECID')
        state.mkdir(parents=True, exist_ok=True)
        data = {'model': args.model, 'ecid': args.ecid,
                'workspace': os.path.relpath(work, state),
                'version': target['ProductVersion'], 'boot_sha256': boot_hashes}
        temporary = receipt.with_suffix('.tmp')
        temporary.write_text(json.dumps(data, indent=2) + '\n')
        temporary.replace(receipt)
    elif saved:
        if saved['version'] != target['ProductVersion']:
            raise ValueError('Saved firmware differs from the boot bundle')
        if saved.get('boot_sha256') and saved['boot_sha256'] != boot_hashes:
            raise ValueError('Boot files changed since this device\'s last successful restore')
    print(work)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, patchctl.PatchError) as error:
        print('Boot selection failed: ' + str(error), file=sys.stderr)
        sys.exit(2)
