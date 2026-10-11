"""Load model-specific original resources from the shared Python resource list."""
import hashlib
from integrity import declaration, checked
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2] / 'donor'


class MissingDonorResources(ValueError):
    """The package lacks verified donor resources for the selected model."""


REQUIRED = {
    'iPhone5,4': {'n49-ibss.bin', 'n49-ibec.bin', 'n49-bluetool', 'n49-mtprops',
                  'n49-isp.bin', 'n49-setfile.dat', 'iBSS.n49.dfu', 'iBEC.n49.dfu'},
    'iPhone5,3': {'iBSS.n48.dfu', 'iBEC.n48.dfu', 'DeviceTree.n48.img3',
                  'N48.mtprops', 'n49-bluetool', 'n49-isp.bin', 'n49-setfile.dat'},
}


def resources(model, require_complete=True):
    if model not in ['iPhone5,3', 'iPhone5,4']:
        raise ValueError('Unsupported donor model')
    manifest = ROOT / 'resources.py'
    if not manifest.is_file():
        raise ValueError('Pre-extracted donor resources are missing for ' + model)
    spec = declaration(manifest, 'MODELS')[model]
    board = 'N48AP' if model == 'iPhone5,3' else 'N49AP'
    if (spec['build'] != '11A470a'
            or spec['board'] != board or spec['version'] != '7.0.1'):
        raise ValueError('Donor identity/build mismatch')
    output = {}
    for row in spec['resources']:
        path = ROOT / row['path']
        if path.is_symlink() or not path.resolve().is_relative_to(ROOT.resolve()):
            raise ValueError('Donor resource path escapes package')
        if path.parts[len(ROOT.parts)] not in ['common', model]:
            raise ValueError('Donor resource belongs to another model')
        data = checked(path)
        if row['name'] in output:
            raise ValueError('Duplicate donor resource name')
        output[row['name']] = data
    missing = REQUIRED[model] - output.keys()
    if require_complete and missing:
        raise MissingDonorResources('Packaged donor resources are incomplete for ' + model
                                    + ': ' + ', '.join(sorted(missing)))
    return output
