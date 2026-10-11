"""Apply checked standalone lockdownd replacement deltas."""
import hashlib
import json
from pathlib import Path

PATCHES = Path(__file__).resolve().parents[2] / 'patches/activation'


def patch(data, version):
    if version not in ['6.1.3', '6.1.4']:
        raise ValueError('Unsupported hacktivation version')
    spec = json.loads((PATCHES / ('lockdownd-' + version + '.json')).read_text())
    if len(data) != spec['source']['size'] or hashlib.sha256(data).hexdigest() != spec['source']['sha256']:
        raise ValueError('Hacktivation requires the original supported lockdownd for ' + version)
    payload_path = PATCHES / spec['payload']['path']
    if payload_path.parent != PATCHES:
        raise ValueError('Invalid activation payload path')
    payload = payload_path.read_bytes()
    if hashlib.sha256(payload).hexdigest() != spec['payload']['sha256']:
        raise ValueError('Activation delta hash mismatch')
    if len(payload) != spec['payload']['size']:
        raise ValueError('Activation delta size mismatch')
    output = bytearray()
    for op in spec['operations']:
        if op['kind'] not in ['literal', 'copy']:
            raise ValueError('Invalid activation operator')
        source = payload if op['kind'] == 'literal' else data
        offset, length = op['offset'], op['length']
        if offset < 0 or length <= 0 or offset + length > len(source):
            raise ValueError('Invalid activation range')
        output.extend(source[offset:offset + length])
    result = bytes(output)
    if len(result) != spec['output']['size'] or hashlib.sha256(result).hexdigest() != spec['output']['sha256']:
        raise ValueError('Patched lockdownd integrity mismatch')
    return result, {'version': version, 'source_sha256': spec['source']['sha256'], 'output_sha256': spec['output']['sha256'], 'path': 'usr/libexec/lockdownd'}
