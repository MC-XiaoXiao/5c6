#!/usr/bin/env python3
"""Generate N41 operation data from extracted, verified original source inputs.

Run once per version. Existing address-bearing edits
are reused only after layout, unique-anchor and every preimage check succeeds.
No address relocation or inferred replacement instructions are performed.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path

import features
import patchctl
from sourcepatches import source_identity


def generate(inputs, output):
    inputs, output = Path(inputs), Path(output)
    source = source_identity(inputs)
    if source is None or source['board'] != 'n41ap':
        raise ValueError('Expected extracted N41 source inputs')
    report = {'source': source, 'patches': []}
    for model, board in [('iPhone5,3', 'n48'), ('iPhone5,4', 'n49')]:
        catalog = features.feature_catalog(patchctl.PORTABLE, model)
        for ident in catalog['recipes']:
            spec = features.load_spec(patchctl.PORTABLE, ident, model, catalog)
            if not (spec.get('input') or '').startswith('n42-'):
                continue
            input_id = source['input_prefix'] + spec['input'][3:]
            data = (inputs / input_id).read_bytes()
            if spec['kind'] == 'edits':
                expected, evidence = features.apply_edits(data, spec)
                operation = {key: copy.deepcopy(spec[key]) for key in
                             ['layout', 'input_size', 'edits', 'keep_size', 'tail', 'resign']}
                # Record the checked N41 bytes, rather than copying an unchecked table.
                for row in operation['edits']:
                    start = features.locate(data, bytes.fromhex(row['anchor'])) + row['relative_offset']
                    row['before'] = data[start:start + len(bytes.fromhex(row['before']))].hex()
                actual, _ = features.apply_edits(data, operation)
                if actual != expected:
                    raise ValueError('Generated operation differs: ' + ident)
                outputs = {'all_profiles': hashlib.sha256(actual).hexdigest()}
            elif spec['kind'] == 'tree':
                operation = {key: copy.deepcopy(spec.get(key, {} if key in
                             ['property_order', 'profile_properties'] else [])) for key in
                             ['node_additions', 'properties', 'property_order', 'profile_properties']}
                base, _ = features.apply_tree(data, {'node_additions': operation['node_additions'], 'properties': []})
                for row in operation['properties']:
                    node = features.tree_nodes(features.parse_tree(base))[row['node']]
                    found = next((p for p in node['properties'] if p['name'] == row['name']), None)
                    if found not in row['accepted']:
                        raise ValueError('N41 tree preimage differs: ' + row['name'])
                    row['accepted'] = [copy.deepcopy(found)]
                    base, _ = features.apply_tree(base, {'properties': [row]})
                outputs = {}
                for profile in ['native6-validated', 'native6-wifi-candidate']:
                    extra = operation['profile_properties'].get(profile, [])
                    current = base
                    for row in extra:
                        node = features.tree_nodes(features.parse_tree(current))[row['node']]
                        found = next((p for p in node['properties'] if p['name'] == row['name']), None)
                        if found not in row['accepted']:
                            raise ValueError('N41 profile tree preimage differs: ' + row['name'])
                        row['accepted'] = [copy.deepcopy(found)]
                        current, _ = features.apply_tree(current, {'properties': [row]})
                    actual, evidence = features.apply_tree(data, {**operation, 'properties': operation['properties'] + extra})
                    expected, _ = features.apply_tree(data, {**spec, 'properties': spec['properties'] + spec.get('profile_properties', {}).get(profile, [])})
                    if actual != expected:
                        raise ValueError('Generated tree differs: ' + profile)
                    outputs[profile] = hashlib.sha256(actual).hexdigest()
            else:
                raise ValueError('Unsupported source patch operation: ' + ident)
            packet = {'schema': 1, 'id': ident, 'kind': spec['kind'], 'target': model,
                      'source': {k: source[k] for k in ['board', 'product', 'version', 'build']},
                      'input': {'id': 'n41' + spec['input'][3:], 'size': len(data),
                                'sha256': hashlib.sha256(data).hexdigest()},
                      'operation': operation, 'output_sha256': outputs}
            path = output / board / (ident + '.json')
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(packet, separators=(',', ':')) + '\n')
            report['patches'].append({'target': model, 'id': ident, 'input': packet['input'],
                                      'output_sha256': outputs, 'evidence': evidence})
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inputs', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    report = generate(args.inputs, args.output)
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    print('Generated', len(report['patches']), 'checked N41 patch tables for', report['source']['version'])
