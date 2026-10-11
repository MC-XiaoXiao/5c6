#!/usr/bin/env python3
"""N48 donor identity and boot encryption helpers used by the unified builder."""
import hashlib
from pathlib import Path
import subprocess
import tempfile
import patchctl as ctl
from features import parse_tree, load_spec, check_prelink
from firmware import extract_img3_data, parse_img3
from hosttools import require_tools, tool_env

BOOTARGS = 'rd=disk0s1s1 -v debug=0x2014e wdt=-1 pio-error=0 amfi=0xff cs_enforcement_disable=1'
N48_CORE = {
    'kernel-validated', 'kernel-img3-validated', 'touch-firmware',
    'devicetree', 'devicetree-img3', 'ibss', 'ibec', 'sensors-cache',
    'locationd-heading', 'bluetooth', 'camera-isp', 'camera-setfile',
    'camera-runtime', 'autolock-runtime', 'microphone-runtime',
}
N48_UNSUPPORTED = {'gps-runtime'}


def load_feature(ident):
    return load_spec(ctl.PORTABLE, ident, 'iPhone5,3')


def verify_package():
    from features import verify_catalog
    return verify_catalog(ctl)['iPhone5,3']


def check_touch_kernel(data):
    return check_prelink(data, load_feature('touch-kernel'))


def identity(data):
    tree = parse_tree(data)
    props = {p['name']: bytes.fromhex(p['value']) for p in tree['properties']}
    if props.get('model') != b'iPhone5,3\0' or b'N48AP\0' not in props.get('compatible', b'').split(b'AppleARM')[0]:
        raise ValueError('Expected original N48 / iPhone5,3 DeviceTree')
    return tree


def patch_boot(source, keys, tools, kind, stage, spec=None):
    spec = load_feature(kind.lower()) if spec is None else spec
    template = source.read_bytes(); material = keys[kind]
    original = extract_img3_data(template, material['iv'], material['key'])
    if spec['match']['marker'].encode() not in original or b'iBoot-' not in original:
        raise ValueError('Expected N48 7.0.1 decrypted ' + kind + '; do not use N49 components')
    raw = stage / (kind + '.raw'); raw.write_bytes(original)
    patched = stage / (kind + '.patched')
    flags = spec['flags']
    result = subprocess.run([str(tools / 'iBoot32Patcher'), str(raw), str(patched), *flags],
                            env=tool_env(tools), capture_output=True, timeout=60)
    if result.returncode not in (0, 1) or b'main: Quitting' not in result.stdout + result.stderr or not patched.exists():
        raise ValueError('N48 boot patcher failed: ' + kind)
    data = patched.read_bytes()
    if len(data) != len(original) or data == original: raise ValueError('Invalid boot patch size/change: ' + kind)
    if kind == 'iBEC' and BOOTARGS.encode() + b'\0' not in data: raise ValueError('Missing normal boot arguments')
    output = stage / (kind + '.dfu')
    # Keys stay in local memory/child arguments; exceptions never print the command.
    result = subprocess.run([str(tools / 'xpwntool'), str(patched), str(output), '-t', str(source),
                             '-iv', material['iv'], '-k', material['key']], env=tool_env(tools), capture_output=True, timeout=60)
    if result.returncode or not output.exists(): raise ValueError('N48 IMG3 encryption failed: ' + kind)
    blob = output.read_bytes()
    if extract_img3_data(blob, material['iv'], material['key']) != data: raise ValueError('Encrypted boot round-trip mismatch')
    before, after = parse_img3(template), parse_img3(blob)
    if before.image_type != after.image_type: raise ValueError('Boot IMG3 type changed')
    return blob, {'donor_sha256': ctl.sha(source), 'raw_sha256': hashlib.sha256(original).hexdigest(),
                  'raw_size': len(original), 'output_sha256': hashlib.sha256(blob).hexdigest(),
                  'encrypted_round_trip': True, 'model': 'N48AP',
                  'recipe_sha256': ctl.sha(ctl.PORTABLE / 'n48' / kind.lower() / 'patch.py')}


