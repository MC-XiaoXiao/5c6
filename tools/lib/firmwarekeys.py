"""Retrieve firmware decryption material from AppleWiki without bundled keys."""
import re
import urllib.error
import urllib.parse
import urllib.request


class FirmwareKeyError(ValueError):
    """AppleWiki could not supply validated material for the selected firmware."""


def fetch(model, version, build, components, rootfs=False):
    codenames = {'10B329': 'BrightonMaps', '10B350': 'BrightonMaps', '11A470a': 'Innsbruck'}
    if build not in codenames or model not in ['iPhone5,1', 'iPhone5,2', 'iPhone5,3', 'iPhone5,4']:
        raise FirmwareKeyError('No AppleWiki page mapping for this firmware identity')
    title = 'Keys:' + codenames[build] + '_' + build + '_(' + model + ')'
    url = 'https://theapplewiki.com/wiki/' + urllib.parse.quote(title, safe=':(),_') + '?action=raw'
    request = urllib.request.Request(url, headers={'User-Agent': 'Project5C6/1.0 firmware keys client'})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                final = urllib.parse.urlparse(response.url)
                if final.scheme != 'https' or final.hostname not in ['theapplewiki.com', 'www.theapplewiki.com']:
                    raise FirmwareKeyError('AppleWiki redirected outside its HTTPS domain')
                raw = response.read(262145)
            if len(raw) > 262144:
                raise FirmwareKeyError('AppleWiki response exceeds the size limit')
            text = raw.decode('utf-8')
            break
        except (OSError, UnicodeError, urllib.error.URLError) as error:
            permanent = isinstance(error, urllib.error.HTTPError) and error.code in [400, 404, 410]
            if permanent or attempt == 2:
                raise FirmwareKeyError('Cannot retrieve decryption material from AppleWiki; check the connection and retry') from None
    fields = {}
    for line in text.splitlines():
        match = re.match(r'^\s*\|\s*([A-Za-z0-9]+)\s*=\s*(.*?)\s*$', line)
        if match:
            name, value = match.groups()
            if name in fields:
                raise FirmwareKeyError('AppleWiki contains duplicate firmware fields')
            fields[name] = value
    if any(fields.get(name) != value for name, value in [('Device', model), ('Version', version), ('Build', build)]):
        raise FirmwareKeyError('AppleWiki firmware identity does not match the selected IPSW')

    def hex_field(name, lengths):
        value = fields.get(name, '').strip()
        if len(value) not in lengths or not re.fullmatch('[0-9a-fA-F]+', value):
            raise FirmwareKeyError('AppleWiki lacks valid decryption material for ' + name.removesuffix('Key').removesuffix('IV'))
        return value.lower()

    names = {'KernelCache': 'Kernelcache', 'RestoreRamDisk': 'RestoreRamdisk'}
    material = {}
    for component in components:
        name = names.get(component, component)
        material[component] = {'iv': hex_field(name + 'IV', {32}), 'key': hex_field(name + 'Key', {32, 64})}
    if rootfs:
        material['rootfs'] = hex_field('RootFSKey', {72})
    return material


def source(manifest):
    boards = {row['Info']['DeviceClass'].lower() for row in manifest['BuildIdentities']}
    models = {'n41ap': 'iPhone5,1', 'n42ap': 'iPhone5,2'}
    if len(boards) != 1 or not boards <= models.keys():
        raise FirmwareKeyError('Expected an iPhone 5 source firmware identity')
    return {'source': fetch(models[next(iter(boards))], manifest['ProductVersion'],
                            manifest['ProductBuildVersion'], ['KernelCache', 'DeviceTree', 'RestoreRamDisk'], rootfs=True)}
