"""Select source-board patch data independently of the target 5c model."""
from pathlib import Path
import plistlib

from integrity import declaration, load_json


def source_identity(inputs):
    from features import FeatureError, parse_tree
    inputs = Path(inputs)
    trees = [(prefix, inputs / (prefix + '-devicetree.dtb'))
             for prefix in ['n41', 'n42']]
    trees = [(prefix, path) for prefix, path in trees if path.is_file()]
    if not trees:
        if any(inputs.glob('n41-*')):
            raise FeatureError('N41 inputs require their source DeviceTree and SystemVersion.plist')
        return None  # Older, partial N42 feature-only inputs.
    if len(trees) != 1:
        raise FeatureError('Mixed source DeviceTrees; select one source input directory')
    prefix, path = trees[0]
    props = {p['name']: bytes.fromhex(p['value'])
             for p in parse_tree(path.read_bytes())['properties']}
    models = {'n41ap': 'iPhone5,1', 'n42ap': 'iPhone5,2'}
    board = next((board for board, model in models.items()
                  if props.get('model') == (model + '\0').encode()
                  and (board.upper() + '\0').encode() in props.get('compatible', b'')), None)
    if board is None or (prefix == 'n41' and board != 'n41ap'):
        raise FeatureError('Source DeviceTree identity differs from its input family')
    version_path = inputs / 'SystemVersion.plist'
    if not version_path.is_file():
        raise FeatureError('Source DeviceTree requires SystemVersion.plist')
    version = plistlib.loads(version_path.read_bytes())
    builds = {'6.1.3': '10B329', '6.1.4': '10B350'}
    if (version.get('ProductVersion') not in builds
            or version.get('ProductBuildVersion') != builds[version['ProductVersion']]):
        raise FeatureError('Unsupported source firmware version/build')
    return {'board': board, 'product': models[board],
            'version': version['ProductVersion'], 'build': version['ProductBuildVersion'],
            'input_prefix': prefix}


def source_spec(directory, spec, model, source):
    """Keep historical aliases readable, but use explicit N41 operation data."""
    from features import FeatureError
    if source is None or source['board'] != 'n41ap' or not (spec.get('input') or '').startswith('n42-'):
        return spec
    variants = declaration(Path(directory) / 'catalog.py', 'SOURCE_VARIANTS')
    base = variants.get(source['board'], {}).get(source['version'])
    if base is None:
        raise FeatureError('No patch data for selected source firmware')
    board = {'iPhone5,3': 'n48', 'iPhone5,4': 'n49'}[model]
    packet = load_json(Path(directory) / base / board / (spec['id'] + '.json'))
    provenance = packet['source']
    if (provenance['board'] != source['board'] or provenance['version'] != source['version']
            or provenance['build'] != source['build'] or packet['target'] != model
            or packet['id'] != spec['id'] or packet['kind'] != spec['kind']
            or packet['input']['id'] != 'n41' + spec['input'][3:]):
        raise FeatureError('Source patch data identity differs')
    result = {**spec, **packet['operation']}
    result['input'] = source['input_prefix'] + spec['input'][3:]
    return result
