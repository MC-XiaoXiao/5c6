"""Resolve native macOS/Linux tools without requiring a Kit checkout."""
import os
import shutil
from pathlib import Path
import sys
import re
import subprocess
import time


def tool_directory(kit=None, tools_dir=None):
    if bool(kit) == bool(tools_dir):
        raise ValueError('Specify exactly one of --kit or --tools-dir')
    if tools_dir:
        if sys.platform not in ['linux', 'darwin']:
            raise ValueError('Native USB/restore tools require macOS or Linux')
        return Path(tools_dir).resolve()
    machine = {'x86_64': 'x86_64', 'aarch64': 'arm64', 'arm64': 'arm64'}.get(os.uname().machine)
    if sys.platform != 'linux' or not machine:
        raise ValueError('USB/restore tools require Linux x86_64 or arm64')
    return Path(tools_dir).resolve() if tools_dir else Path(kit).resolve() / 'bin/linux' / machine


def tool_env(directory):
    env = dict(os.environ)
    library = Path(directory) / 'lib'
    if library.is_dir():
        variable = 'DYLD_LIBRARY_PATH' if sys.platform == 'darwin' else 'LD_LIBRARY_PATH'
        env[variable] = str(library) + (':' + env[variable] if env.get(variable) else '')
    return env


def require_tools(directory, names):
    missing = [str(Path(directory) / name) for name in names
               if not (Path(directory) / name).is_file() or not os.access(Path(directory) / name, os.X_OK)]
    if missing:
        raise ValueError('Missing executable tools (no device operation started):\n' + '\n'.join(missing))


def exploit_command(directory):
    """Use Kit's A6 exploit choice for each host architecture."""
    directory = Path(directory)
    if sys.platform == 'darwin':
        if os.uname().machine == 'arm64':
            return [str(directory / 'ipwnder'), '-pv']
        return [str(directory / 'x86_64/ipwnder32'), '-p', '--noibss']
    command = [str(directory / 'a6meowing')]
    # Flush progress when the host tool is run through a shell pipe.
    if shutil.which('stdbuf'):
        command = [shutil.which('stdbuf'), '-oL', '-eL', *command]
    return command


def require_boot_tools(directory):
    command = exploit_command(directory)
    require_tools(directory, ['irecovery', 'gaster'])
    binary = Path(directory) / ('a6meowing' if sys.platform == 'linux' else
        'ipwnder' if os.uname().machine == 'arm64' else 'x86_64/ipwnder32')
    require_tools(binary.parent, [binary.name])


def dfu_stage(fields):
    """Distinguish ROM DFU and our RAM-loaded iBSS from current USB evidence."""
    if fields.get('MODE') != 'DFU':
        raise ValueError('Expected DFU before checkm8 / iBSS preparation')
    try:
        flags = int(fields.get('IBFL', '0'), 0)
    except ValueError:
        flags = 0
    if fields.get('SRTG') == 'N/A' and fields.get('SRNM') == 'N/A' and flags == 0x1b:
        return 'pwned-ibss'
    if not fields.get('SRTG') or fields['SRTG'] == 'N/A':
        raise ValueError('Unrecognized DFU stage; re-enter physical DFU and retry')
    if 'PWND' in fields or any('PWND:' in value for value in fields.values()):
        return 'pwned-dfu'
    return 'rom-dfu'


def prepare_pwned_ibss(directory, ecid, target, ibss):
    """Reuse detected pwned states, or exploit and verify the bundled iBSS."""
    directory = Path(directory)
    env = tool_env(directory)
    require_tools(directory, ['irecovery'])
    def identify():
        text = subprocess.check_output([str(directory / 'irecovery'), '-q'],
                                       env=env, text=True, timeout=15)
        fields = dict(re.findall(r'^([A-Z]+):[ \t]*(.+)$', text, re.M))
        if (int(fields.get('ECID', '0'), 0) != int(str(ecid), 0)
                or int(fields.get('CPID', '0'), 0) != 0x8950
                or int(fields.get('BDID', '0'), 0) != target['board_id']
                or fields.get('MODE') != 'DFU'):
            raise ValueError('Expected your ' + target['HardwareModel'] + ' in DFU; USB identity differs')
        return fields
    fields = identify()
    stage = dfu_stage(fields)
    if stage == 'pwned-ibss':
        print('Compatible pwned iBSS detected; skipping checkm8 and iBSS upload.', file=sys.stderr)
        return fields
    require_boot_tools(directory)
    try:
        if stage == 'pwned-dfu':
            print('Device already in checkm8 pwned DFU; skipping exploit.', file=sys.stderr)
        else:
            print('Running checkm8. If it fails, re-enter physical DFU and retry.', file=sys.stderr)
            subprocess.run(exploit_command(directory), cwd=directory, env=env, check=True, timeout=120)
            fields = identify()
            if dfu_stage(fields) != 'pwned-dfu':
                raise ValueError('checkm8 returned without a verified pwned DFU marker')
        subprocess.run([str(directory / 'gaster'), 'reset'], env=env, check=True, timeout=30)
        time.sleep(1)
        fields = identify()
        if dfu_stage(fields) != 'pwned-dfu':
            raise ValueError('checkm8 pwned DFU marker lost after reset')
        nonce = fields.get('NONC')
        if not nonce:
            raise ValueError('Nonce unavailable before iBSS upload')
        subprocess.run([str(directory / 'irecovery'), '-f', str(ibss)], env=env, check=True, timeout=60)
        time.sleep(2)
        fields = identify()
        if dfu_stage(fields) != 'pwned-ibss' or fields.get('NONC') != nonce:
            raise ValueError('Loaded iBSS / device nonce could not be verified; stopped before iBEC')
        return fields
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        raise ValueError('DFU preparation failed: ' + str(error)
                         + '. Re-enter physical DFU, then retry the same operation.') from error
