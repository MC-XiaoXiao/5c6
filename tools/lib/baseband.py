#!/usr/bin/env python3
"""Fetch Apple modem firmware and personalize it for the selected 5c."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import tempfile
import re
import ssl
import subprocess
import urllib.parse
import urllib.request
import uuid
import zipfile

from targets import target_for

TSS_URL = 'https://gs.apple.com/TSS/controller?action=2'
MAX_MEMBER = 64 * 1024 * 1024


def sha(data):
    return hashlib.sha256(data).hexdigest()


def apple_url(url):
    value = urllib.parse.urlparse(url)
    if value.hostname == 'appldnld.apple.com' and value.scheme == 'http':
        value = value._replace(scheme='https', netloc='secure-appldnld.apple.com')
    if (value.scheme != 'https' or not value.hostname
            or not (value.hostname.endswith('.apple.com') or value.hostname == 'apple.com')
            or value.username or value.password or value.port not in (None, 443)):
        raise ValueError('Firmware download must use Apple HTTPS')
    return urllib.parse.urlunparse(value)


class RemoteIPSW(io.RawIOBase):
    """Seekable ZIP access; never download the multi-GB root filesystem."""
    def __init__(self, spec):
        self.url = apple_url(spec['url'])
        self.size = spec['filesize']
        self.position = 0

    def seekable(self):
        return True

    def tell(self):
        return self.position

    def seek(self, offset, whence=0):
        self.position = offset + (0 if whence == 0 else self.position if whence == 1 else self.size)
        if not 0 <= self.position <= self.size:
            raise ValueError('Invalid IPSW seek')
        return self.position

    def read(self, size=-1):
        size = min(self.size - self.position, size if size >= 0 else self.size)
        if not 0 <= size <= MAX_MEMBER:
            raise ValueError('IPSW range exceeds component limit')
        if not size:
            return b''
        start, end = self.position, self.position + size - 1
        request = urllib.request.Request(self.url, headers={
            'Range': f'bytes={start}-{end}', 'Accept-Encoding': 'identity',
            'User-Agent': 'Project5C6/1.0'})
        with urllib.request.urlopen(request, timeout=45) as response:
            apple_url(response.url)
            if (response.status != 206 or response.headers.get('Content-Range')
                    != f'bytes {start}-{end}/{self.size}'):
                raise ValueError('Apple CDN did not return the exact requested IPSW range')
            data = response.read(size + 1)
        if len(data) != size:
            raise ValueError('Truncated or oversized Apple IPSW range')
        self.position += size
        return data


def latest(model):
    url = f'https://api.ipsw.me/v4/device/{model}?type=ipsw'
    with urllib.request.urlopen(url, timeout=20) as response:
        final = urllib.parse.urlparse(response.url)
        if final.scheme != 'https' or final.hostname != 'api.ipsw.me':
            raise ValueError('Invalid firmware metadata redirect')
        raw = response.read(2 * 1024 * 1024 + 1)
    if len(raw) > 2 * 1024 * 1024:
        raise ValueError('Oversized firmware metadata')
    metadata = json.loads(raw)
    if metadata['identifier'] != model:
        raise ValueError('Firmware metadata belongs to another model')
    rows = [row for row in metadata['firmwares'] if row.get('signed') is True
            and row.get('identifier') == model]
    if not rows:
        raise ValueError('No currently signed firmware found for ' + model)
    spec = max(rows, key=lambda row: tuple(int(n) for n in row['version'].split('.')))
    spec = dict(spec, url=apple_url(spec['url']))
    if not re.fullmatch('[A-Za-z0-9]+', spec['buildid']):
        raise ValueError('Invalid firmware build identifier')
    if not isinstance(spec['filesize'], int) or not 0 < spec['filesize'] < 16 * 1024**3:
        raise ValueError('Invalid IPSW size')
    return spec


def identity(manifest, spec, model):
    target = target_for(model)
    if (model not in manifest.get('SupportedProductTypes', [])
            or manifest['ProductVersion'] != spec['version']
            or manifest['ProductBuildVersion'] != spec['buildid']):
        raise ValueError('Latest firmware manifest identity mismatch')
    found = [row for row in manifest['BuildIdentities']
             if row['Info']['DeviceClass'].lower() == target['HardwareModel'].lower()
             and row['Info'].get('RestoreBehavior') == 'Erase']
    if len(found) != 1:
        raise ValueError('Expected one model-matched erase identity')
    row = found[0]
    if (int(row['ApBoardID'], 0) != target['board_id']
            or int(row['ApChipID'], 0) != 0x8950 or int(row['BbChipID'], 0) != 0x6f20e1):
        raise ValueError('Unsupported 5c modem/board identity')
    path = row['Manifest']['BasebandFirmware']['Info']['Path']
    if not path.startswith('Firmware/Mav7Mav8-') or not path.endswith('.bbfw'):
        raise ValueError('Expected Mav7/Mav8 firmware for iPhone 5c')
    return row


def member(archive, name):
    path = PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts:
        raise ValueError('Unsafe IPSW member path')
    info = archive.getinfo(name)
    if not 0 < info.file_size <= MAX_MEMBER or info.compress_size > MAX_MEMBER:
        raise ValueError('Invalid component size')
    return archive.read(info)  # zipfile verifies the member CRC.


def fetch(spec, model, directory):
    """Publish manifest and BBFW together, with hashes for every cache reuse."""
    directory = Path(directory).resolve()
    directory.mkdir(parents=True, exist_ok=True)
    destination = directory / (model + '-' + spec['buildid'])
    if destination.exists():
        report = json.loads((destination / 'download.json').read_text())
        if report['spec'] != spec:
            raise ValueError('Cached firmware metadata changed; use a new download cache')
        for name, expected in report['files'].items():
            if sha((destination / name).read_bytes()) != expected:
                raise ValueError('Cached baseband resource changed: ' + name)
        manifest = plistlib.loads((destination / 'BuildManifest.plist').read_bytes())
        row = identity(manifest, spec, model)
        return destination, row
    with tempfile.TemporaryDirectory(prefix='.baseband-', dir=directory) as temporary:
        stage = Path(temporary)
        print('Fetching latest Apple baseband: ' + spec['version'] + ' / ' + spec['buildid'], file=__import__('sys').stderr)
        with RemoteIPSW(spec) as source, zipfile.ZipFile(source) as archive:
            raw = member(archive, 'BuildManifest.plist')
            row = identity(plistlib.loads(raw), spec, model)
            firmware = member(archive, row['Manifest']['BasebandFirmware']['Info']['Path'])
        (stage / 'BuildManifest.plist').write_bytes(raw)
        (stage / 'Baseband.bbfw').write_bytes(firmware)
        # The current final 5c release has also been independently pinned locally.
        if spec['buildid'] == '14G60' and sha(firmware) != '36fecf09057f5d618a3ccf3466c9e93985c6ebaa8fb42adce921d660784175b6':
            raise ValueError('14G60 baseband SHA-256 mismatch')
        report = {'spec': spec, 'files': {'BuildManifest.plist': sha(raw), 'Baseband.bbfw': sha(firmware)}}
        (stage / 'download.json').write_text(json.dumps(report, indent=2) + '\n')
        os.rename(stage, destination)
    return destination, row


def query_parameters(query, model, ecid):
    if query.get('ProductType') != model or query.get('UniqueChipID') != ecid or ecid <= 0:
        raise ValueError('Baseband query model/ECID differs from connected device')
    result = query.get('Baseband', query.get('FirmwarePreflightInfo', query))
    chip = result.get('ChipID', result.get('BasebandChipID'))
    serial = result.get('ChipSerialNo', result.get('BasebandSerialNumber'))
    cert = result.get('CertID', result.get('BasebandCertId'))
    if chip != 0x6f20e1 or not isinstance(serial, bytes) or len(serial) != 4 or not isinstance(cert, int):
        raise ValueError('Incomplete Mav7 signing parameters from modem query')
    params = {'BbChipID': chip, 'BbSNUM': serial, 'BbGoldCertId': cert & 0xffffffff}
    nonce = result.get('Nonce', result.get('BasebandNonce'))
    if nonce is not None:
        if not isinstance(nonce, bytes) or len(nonce) != 20:
            raise ValueError('Invalid baseband nonce; AP nonce cannot be substituted')
        params['BbNonce'] = nonce
    return params


def ticket_request(row, query, model, ecid):
    request = {'@HostPlatformInfo': 'mac', '@VersionInfo': 'libauthinstall-973.0.1',
               '@UUID': str(uuid.uuid4()).upper(), '@BBTicket': True, 'ApECID': ecid,
               'UniqueBuildID': row['UniqueBuildID'],
               'BasebandFirmware': {k: v for k, v in row['Manifest']['BasebandFirmware'].items() if k != 'Info'},
               **query_parameters(query, model, ecid)}
    for name in ['ApChipID', 'ApBoardID', 'ApSecurityDomain']:
        request[name] = int(row[name], 0)
    for name in ['BbProvisioningManifestKeyHash', 'BbActivationManifestKeyHash', 'BbCalibrationManifestKeyHash']:
        request[name] = row[name]
    return plistlib.dumps(request)


def request_ticket(row, query, model, ecid):
    raw = ticket_request(row, query, model, ecid)
    req = urllib.request.Request(TSS_URL, data=raw, headers={
        'Content-Type': 'text/xml; charset="utf-8"', 'User-Agent': 'InetURL/1.0'})
    from integrity import checked
    # gs.apple.com chains to Apple's private PKI, absent from many Linux stores.
    # The public root is published at https://www.apple.com/certificateauthority/.
    pem = checked(Path(__file__).resolve().parents[1] / 'AppleRootCA.pem').decode('ascii')
    context = ssl.create_default_context()
    context.load_verify_locations(cadata=pem)
    with urllib.request.urlopen(req, timeout=30, context=context) as response:
        if urllib.parse.urlparse(response.url).hostname != 'gs.apple.com' or not response.url.startswith('https://'):
            raise ValueError('Invalid TSS redirect')
        data = response.read(4 * 1024 * 1024 + 1)
    if len(data) > 4 * 1024 * 1024 or not data.startswith(b'STATUS=0&MESSAGE=SUCCESS&') or b'<?xml' not in data:
        raise ValueError('Apple rejected baseband signing or returned an invalid response')
    return raw, plistlib.loads(data[data.index(b'<?xml'):])


def personalize(stock, response, destination):
    ticket = response.get('BBTicket')
    if not isinstance(ticket, bytes) or len(ticket) < 500 or ticket[0] != 0x30:
        raise ValueError('TSS response lacks a valid DER BBTicket')
    with zipfile.ZipFile(stock) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError('Duplicate BBFW members')
        entries = {name: member(archive, name) for name in names if name.endswith('.mbn')}
    required = {'apps.mbn', 'dsp1.mbn', 'dsp2.mbn', 'dsp3.mbn', 'rpm.mbn', 'sbl1.mbn', 'sbl2.mbn', 'restoresbl1.mbn'}
    if entries.keys() != required:
        raise ValueError('Incomplete or unsupported Mav7 firmware component set')
    for key, name in [('SBL1-Blob', 'sbl1.mbn'), ('RestoreSBL1-Blob', 'restoresbl1.mbn')]:
        blob = response.get('BasebandFirmware', {}).get(key)
        raw = entries[name]
        if not isinstance(blob, bytes) or not 0 < len(blob) < len(raw):
            raise ValueError('Missing or oversized TSS signature for ' + name)
        # Same tail stitching as idevicerestore's mbn_stitch, including Apple padding.
        entries[name] = raw[:-len(blob)] + blob
    entries['bbticket.der'] = ticket
    with zipfile.ZipFile(destination, 'x', compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in entries.items():
            archive.writestr(zipfile.ZipInfo(name, date_time=(2017, 7, 15, 16, 28, 58)), data, compress_type=zipfile.ZIP_DEFLATED)
    from patchctl import validate_baseband
    validate_baseband(destination)


def receipt(path, model, ecid):
    path = Path(path)
    report = json.loads((path.parent / 'personalization.json').read_text())
    if (report['model'] != model or report['ecid'] != ecid
            or report['package_sha256'] != sha(path.read_bytes())):
        raise ValueError('Personalized baseband device identity or hash mismatch')
    from patchctl import validate_baseband
    validate_baseband(path)
    return report


def native_source(directory, model, ecid=None):
    """Verify a latest-release source for idevicerestore's own BasebandData path."""
    directory = Path(directory)
    report = json.loads((directory / 'source.json').read_text())
    if (report.get('schema') != 1 or report.get('signing') != 'idevicerestore-BasebandData'
            or set(report.get('files', {})) != {'Baseband.bbfw', 'BuildManifest.plist', 'identity.plist'}):
        raise ValueError('Incomplete native baseband source receipt')
    if report['model'] != model or (ecid is not None and report['ecid'] != ecid):
        raise ValueError('Native baseband source device binding differs')
    for name, expected in report['files'].items():
        if sha((directory / name).read_bytes()) != expected:
            raise ValueError('Native baseband source changed: ' + name)
    manifest = plistlib.loads((directory / 'BuildManifest.plist').read_bytes())
    row = identity(manifest, report['spec'], model)
    if row != plistlib.loads((directory / 'identity.plist').read_bytes()):
        raise ValueError('Native baseband identity differs from Apple manifest')
    return report | {'identity': row}


def stage_native(model, ecid, directory, cache):
    """Download only. Modem parameters and signing belong to the normal restore."""
    directory = Path(directory).resolve()
    if ecid <= 0:
        raise ValueError('Native baseband source requires a nonzero ECID')
    if directory.exists():
        native_source(directory, model, ecid)
        return directory
    spec = latest(model)
    resources, row = fetch(spec, model, cache)
    directory.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.native-baseband-', dir=directory.parent) as temporary:
        stage = Path(temporary)
        files = {}
        for name in ['Baseband.bbfw', 'BuildManifest.plist']:
            raw = (resources / name).read_bytes()
            (stage / name).write_bytes(raw)
            files[name] = sha(raw)
        # plist-compatible identity is stored separately; JSON cannot encode DATA.
        (stage / 'identity.plist').write_bytes(plistlib.dumps(row))
        files['identity.plist'] = sha((stage / 'identity.plist').read_bytes())
        report = {'schema': 1, 'model': model, 'ecid': ecid, 'spec': spec,
                  'files': files, 'signing': 'idevicerestore-BasebandData'}
        (stage / 'source.json').write_text(json.dumps(report, indent=2) + '\n')
        os.rename(stage, directory)
    native_source(directory, model, ecid)
    return directory


def prepare(model, ecid, tools, bundle, mode, directory, cache, query_path=None):
    directory = Path(directory).resolve()
    destination = directory / 'Mav7personalized.zip'
    if destination.exists():
        receipt(destination, model, ecid)
        return destination
    spec = latest(model)
    resources, row = fetch(spec, model, cache)
    if query_path:
        query = plistlib.loads(Path(query_path).read_bytes())
    else:
        if mode != 'Normal':
            raise ValueError('Use the normal restore BasebandData signing flow; no extra query ramdisk is started')
        from baseband_query import normal_query
        query = normal_query(model, ecid, tools)
    params = query_parameters(query, model, ecid)
    request, response = request_ticket(row, query, model, ecid)
    directory.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.personalized-', dir=directory.parent) as temporary:
        stage = Path(temporary)
        personalize(resources / 'Baseband.bbfw', response, stage / destination.name)
        (stage / 'request.plist').write_bytes(request)
        (stage / 'response.plist').write_bytes(plistlib.dumps(response))
        (stage / 'query.plist').write_bytes(plistlib.dumps(query))
        (stage / 'BuildManifest.plist').write_bytes((resources / 'BuildManifest.plist').read_bytes())
        report = {'schema': 1, 'model': model, 'ecid': ecid, 'ios_version': spec['version'],
                  'build': spec['buildid'], 'firmware_path': row['Manifest']['BasebandFirmware']['Info']['Path'],
                  'source_package_sha256': sha((resources / 'Baseband.bbfw').read_bytes()),
                  'package_sha256': sha((stage / destination.name).read_bytes()),
                  'request_sha256': sha(request), 'query_source': 'exported-plist' if query_path else mode,
                  'query_sha256': sha(plistlib.dumps(query)), 'nonce_bound': 'BbNonce' in params,
                  'apple_tss_ticket_received': True, 'modem_acceptance_verified': False}
        (stage / 'personalization.json').write_text(json.dumps(report, indent=2) + '\n')
        os.rename(stage, directory)
    return destination


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model', choices=['iPhone5,3', 'iPhone5,4'], required=True)
    parser.add_argument('--ecid', type=lambda v: int(v, 0), required=True)
    parser.add_argument('--mode', required=True)
    for name in ['tools-dir', 'bundle', 'out', 'cache']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--query', type=Path)
    parser.add_argument('--native-source', action='store_true', help='Stage latest BBFW/manifest; sign using idevicerestore during restore')
    args = parser.parse_args()
    try:
        # Keep every subprocess progress line off the shell's captured path output.
        saved_stdout = os.dup(1)
        try:
            os.dup2(2, 1)
            destination = (stage_native(args.model, args.ecid, args.out, args.cache) if args.native_source else
                           prepare(args.model, args.ecid, args.tools_dir, args.bundle, args.mode,
                                   args.out, args.cache, args.query))
        finally:
            os.dup2(saved_stdout, 1)
            os.close(saved_stdout)
        print(destination)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, plistlib.InvalidFileException, subprocess.SubprocessError) as error:
        parser.exit(2, 'Baseband: ' + str(error) + '\n')
