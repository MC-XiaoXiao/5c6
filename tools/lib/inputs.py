#!/usr/bin/env python3
"""Extract the selected source IPSW using verified, packaged 5c donor resources."""
import argparse
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import subprocess
import sys
import tempfile
import zipfile
import patchctl as ctl
from progress import log, stage as progress_stage, error_detail
import n48
from donor import resources, MissingDonorResources
from firmwarekeys import source as source_keys, fetch as fetch_keys, FirmwareKeyError
from firmware import extract_img3_data, decompress_complzss
from features import parse_tree, serialize_tree
from hosttools import require_tools, tool_env
from download import validate_source


def extract(source, keyfile, tools, work, model, version):
    tools = Path(tools).resolve()
    work = Path(work).resolve()
    require_tools(tools, ['dmg', 'hfsplus'])
    work.mkdir(parents=True, exist_ok=True)
    out = work / 'firmware'
    inputs = work / 'inputs'
    if out.exists() or inputs.exists():
        raise ValueError('Firmware/input destinations already exist; choose a new workspace')
    donor_resources = resources(model)
    with tempfile.TemporaryDirectory(prefix='.firmware-', dir=work) as temporary:
        stage = Path(temporary)
        prepared = stage / 'firmware'
        prepared.mkdir()
        common = stage / 'inputs'
        common.mkdir()
        with zipfile.ZipFile(source) as original:
            with progress_stage('Check source IPSW size, SHA-256 and identity: ' + str(source)):
                source_manifest = validate_source(source, version)
            with progress_stage('Load firmware decryption material'):
                keys = json.loads(Path(keyfile).read_text()) if keyfile else source_keys(source_manifest)
            source_identity = next(x for x in source_manifest['BuildIdentities'] if x['Info'].get('RestoreBehavior') == 'Erase')
            source_board = source_identity['Info']['DeviceClass'].lower()[:-2]
            def member_name(identity, component):
                name = identity['Manifest'][component]['Info']['Path']
                if PurePosixPath(name).is_absolute() or '..' in PurePosixPath(name).parts:
                    raise ValueError('Unsafe IPSW component path')
                return name
            def read_member(archive, identity, component):
                return archive.read(member_name(identity, component))
            def decrypt(archive, identity, component, material):
                return extract_img3_data(read_member(archive, identity, component), material['iv'], material['key'])
            def rootfs(archive, identity, material, prefix):
                encrypted = prepared / (prefix + '-rootfs.dmg')
                # Rootfs images exceed a GB; stream them instead of loading into RAM.
                with archive.open(member_name(identity, 'OS')) as source_image, encrypted.open('wb') as output:
                    shutil.copyfileobj(source_image, output, length=1024 * 1024)
                partition = prepared / (prefix + '-rootfs.raw')
                # Key-bearing commands and tool output are never printed.
                result = subprocess.run([str(tools / 'dmg'), 'extract', str(encrypted), str(partition), '-k', material['rootfs']], env=tool_env(tools), capture_output=True, timeout=1800)
                if result.returncode or not partition.is_file():
                    raise ValueError('Root filesystem decryption failed: ' + prefix)
                encrypted.unlink()
                from restore6 import copy_hfs
                hfs = prepared / (prefix + '-rootfs.hfs')
                copy_hfs(partition, hfs)
                partition.unlink()
                return hfs
            with progress_stage('Extract and decrypt source RootFS (large image)'):
                source_hfs = rootfs(original, source_identity, keys['source'], 'source')
            with progress_stage('Decode source kernel and DeviceTree'):
                kernel = decrypt(original, source_identity, 'KernelCache', keys['source']['KernelCache'])
                if not kernel.startswith(b'complzss'):
                    raise ValueError('Expected compressed source kernel')
                decoded, _ = decompress_complzss(kernel)
                import struct
                common.joinpath(source_board + '-kernel.complzss').write_bytes(kernel[:0x180 + struct.unpack_from('>I', kernel, 16)[0]])
                common.joinpath(source_board + '-kernel.macho').write_bytes(decoded)
                tree = decrypt(original, source_identity, 'DeviceTree', keys['source']['DeviceTree'])
                common.joinpath(source_board + '-devicetree.dtb').write_bytes(serialize_tree(parse_tree(tree)))
            with progress_stage('Extract original runtime files from RootFS'):
                ctl.extract_rootfs(source_board, source_hfs, tools / 'hfsplus', common)
            with progress_stage('Prepare restore ramdisk and model-matched donor files: ' + model):
                ramdisk_template = read_member(original, source_identity, 'RestoreRamDisk')
                prepared.joinpath('restore-ramdisk.img3').write_bytes(ramdisk_template)
                ramdisk = decrypt(original, source_identity, 'RestoreRamDisk', keys['source']['RestoreRamDisk'])
                raw = stage / 'ramdisk.raw'; raw.write_bytes(ramdisk)
                from restore6 import copy_hfs
                copy_hfs(raw, prepared / 'restore-ramdisk.hfs')
                # Both models feed the same input directory and feature builder.
                for name, data in donor_resources.items():
                    common.joinpath(name).write_bytes(data)
                if model == 'iPhone5,4':
                    prepared.joinpath('donor-ibec.bin').write_bytes(common.joinpath('n49-ibec.bin').read_bytes())
                else:
                    donor_keys = keys.get('donor') or fetch_keys(model, '7.0.1', '11A470a', ['iBSS', 'iBEC', 'DeviceTree'])
                    for kind in ['iBSS', 'iBEC']:
                        data = donor_resources[kind + '.n48.dfu']
                        material = donor_keys[kind]
                        plain = extract_img3_data(data, material['iv'], material['key'])
                        if (kind + ' for n48ap').encode() not in plain: raise ValueError('Wrong N48 boot donor')
                        if kind == 'iBEC':
                            common.joinpath('iBEC.n48.bin').write_bytes(plain)
                            prepared.joinpath('donor-ibec.bin').write_bytes(plain)
                    material = donor_keys['DeviceTree']
                    tree = extract_img3_data(donor_resources['DeviceTree.n48.img3'], material['iv'], material['key'])
                    n48.identity(tree)
                    common.joinpath('DeviceTree.n48.dtb').write_bytes(tree)
            metadata = plistlib.loads(common.joinpath('SystemVersion.plist').read_bytes())
            if metadata['ProductVersion'] != version: raise ValueError('Extracted rootfs version mismatch')
            # Publish only after extraction has succeeded; original IPSWs remain untouched.
            os.rename(prepared, out)
            os.rename(common, inputs)
    return {'source_version': version, 'source_board': source_board + 'ap',
            'source_product': {'n41': 'iPhone5,1', 'n42': 'iPhone5,2'}[source_board],
            'source_build': source_manifest['ProductBuildVersion'],
            'model': model, 'device_accessed': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--keys', type=Path, help='Optional decryption JSON override')
    for name in ['source-ipsw','tools-dir','work']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--model', choices=['iPhone5,3','iPhone5,4'], required=True)
    parser.add_argument('--version', choices=['6.1.3','6.1.4'], required=True)
    parser.add_argument('--json', action='store_true', help='Print the full extraction report to stdout')
    args = parser.parse_args()
    try:
        result = extract(args.source_ipsw, args.keys, args.tools_dir, args.work, args.model, args.version)
        report = args.work / 'extraction.json'
        ctl.json_write(report, result)
        if args.json:
            print(json.dumps(result, indent=2))
        else:
            log(f'Inputs ready: {args.work / "inputs"}; source iOS {result["source_version"]} ({result["source_build"]}); report: {report}', 'DONE')
    except (MissingDonorResources, FirmwareKeyError) as error:
        parser.exit(2, str(error) + '\n')
    except (OSError, ValueError, KeyError, StopIteration, ctl.PatchError, subprocess.SubprocessError) as error:
        error_detail(error, include_output=False)
        parser.exit(2, 'Firmware extraction failed. Check the source IPSW, packaged donor, keys and tools; no key material is printed.\n')
