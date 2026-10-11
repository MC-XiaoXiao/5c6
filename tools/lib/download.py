#!/usr/bin/env python3
"""Download original Apple source firmware and verify it before publication."""
import argparse
import hashlib
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import urllib.request
import zipfile

# Original N42 firmware is the source for BOTH 5c models. Metadata from IPSW.me;
# downloads go directly to Apple. Pinning avoids a runtime metadata dependency.
FIRMWARE = {
    '6.1.3': {
        'build': '10B329', 'size': 1037889939,
        'sha256': 'e704280a907ba4fd1b0ded4227282428582047c376436f526f5b5f420d861320',
        'url': 'https://secure-appldnld.apple.com/iOS6.1/091-2516.20130319.7164R/iPhone5,2_6.1.3_10B329_Restore.ipsw',
    },
    '6.1.4': {
        'build': '10B350', 'size': 1037923480,
        'sha256': '44d55c73fc7375449119cbf117b2ea3fb63a62422289f31823fe02190e43810b',
        'url': 'https://secure-appldnld.apple.com/iOS6.1/091-3423.20130502.Tr3Lz/iPhone5,2_6.1.4_10B350_Restore.ipsw',
    },
}

# Original N41 IPSWs accepted locally. Metadata is pinned from IPSW.me, like N42.
N41_FIRMWARE = {
    '6.1.3': {
        'size': 1037540044,
        'sha256': '1128ca371623fc2bdbc5e3d705dda890de73271d4667eb49926495815a08ccd5',
    },
    '6.1.4': {
        'size': 1037550400,
        'sha256': '02f6073dbef688185f721455b795efd9501babd2976c8d2def70fdd9abadf20e',
    },
}


def source_manifest(path, version):
    with zipfile.ZipFile(path) as archive:
        manifest = plistlib.loads(archive.read('BuildManifest.plist'))
    boards = {row['Info']['DeviceClass'].lower() for row in manifest['BuildIdentities']}
    models = {'n41ap': 'iPhone5,1', 'n42ap': 'iPhone5,2'}
    supported = set(manifest.get('SupportedProductTypes', []))
    if (manifest.get('ProductVersion') != version
            or manifest.get('ProductBuildVersion') != FIRMWARE[version]['build']
            or len(boards) != 1 or not boards <= models.keys()
            or models[next(iter(boards))] not in supported
            or not supported <= {models[next(iter(boards))], 'iFPGA'}):
        raise ValueError('Select original iPhone 5 firmware matching iOS ' + version)
    return manifest


def validate_source(path, version):
    """Require the complete original IPSW, including components not patched later."""
    path = Path(path)
    manifest = source_manifest(path, version)
    board = manifest['BuildIdentities'][0]['Info']['DeviceClass'].lower()
    spec = N41_FIRMWARE[version] if board == 'n41ap' else FIRMWARE[version]
    if not verified(path, spec):
        raise ValueError('Local IPSW size/SHA-256 mismatch. Select an unmodified original iPhone 5 IPSW matching iOS ' + version)
    return manifest


def verified(path, spec):
    if not path.is_file() or path.stat().st_size != spec['size']:
        return False
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest() == spec['sha256']


def download(version, directory):
    spec = FIRMWARE[version]
    directory = Path(directory).resolve()
    directory.mkdir(parents=True, exist_ok=True)
    destination = directory / spec['url'].rsplit('/', 1)[-1]
    if destination.exists():
        if not verified(destination, spec):
            raise ValueError('Cached IPSW is invalid; move or remove it before retrying: ' + str(destination))
        source_manifest(destination, version)
        return destination
    partial = destination.with_suffix('.ipsw.part')
    # Keep a lock and incomplete downloads in the cache, never in published inputs.
    lock = destination.with_suffix('.ipsw.lock')
    try:
        with lock.open('x'):
            pass
    except FileExistsError:
        raise ValueError('Download already running (after an interrupted process, remove ' + str(lock) + ')') from None
    try:
        axel = shutil.which('axel')
        state = partial.with_name(partial.name + '.st')
        resume = bool(axel and partial.exists() and state.exists())
        if not resume:
            partial.unlink(missing_ok=True)
            state.unlink(missing_ok=True)
        remaining = max(0, spec['size'] - (partial.stat().st_size if resume else 0))
        if shutil.disk_usage(directory).free < remaining + 64 * 1024 * 1024:
            raise ValueError('Not enough disk space for firmware download')
        print('Downloading original iPhone 5 iOS ' + version + ' from Apple (~1 GB).', file=sys.stderr)
        if axel:
            subprocess.run([axel, '-n', '4', '-o', str(partial), spec['url']], stdout=sys.stderr, check=True)
        else:
            # Standard-library fallback: always restart to avoid mixing ranges.
            request = urllib.request.Request(spec['url'], headers={'User-Agent': 'iPhone5c-iOS6-Tool/1.0'})
            with urllib.request.urlopen(request, timeout=60) as response, partial.open('wb') as output:
                if not response.url.startswith('https://'):
                    raise ValueError('Insecure firmware redirect')
                copied = 0
                next_report = 64 * 1024 * 1024
                while True:
                    block = response.read(4 * 1024 * 1024)
                    if not block:
                        break
                    copied += len(block)
                    if copied > spec['size']:
                        raise ValueError('Firmware exceeds expected size')
                    output.write(block)
                    if copied >= next_report:
                        print(f'Download: {copied * 100 // spec["size"]}%', file=sys.stderr)
                        next_report += 64 * 1024 * 1024
        print('Checking firmware size, SHA-256 and identity…', file=sys.stderr)
        if not verified(partial, spec):
            partial.unlink(missing_ok=True)
            partial.with_name(partial.name + '.st').unlink(missing_ok=True)
            raise ValueError('Firmware download integrity check failed; retry the download')
        source_manifest(partial, version)
        partial.replace(destination)
        partial.with_name(partial.name + '.st').unlink(missing_ok=True)
        return destination
    finally:
        lock.unlink(missing_ok=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', choices=list(FIRMWARE), required=True)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--out', type=Path)
    source.add_argument('--check', type=Path)
    args = parser.parse_args()
    try:
        if args.check:
            print('Checking original firmware size, SHA-256 and identity…', file=sys.stderr)
            validate_source(args.check, args.version)
            print(args.check.resolve())
        else:
            print(download(args.version, args.out))
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, plistlib.InvalidFileException, subprocess.SubprocessError) as error:
        parser.exit(2, 'Firmware: ' + str(error) + '\n')
    except KeyboardInterrupt:
        parser.exit(130, 'Download interrupted; incomplete firmware has not been published.\n')
