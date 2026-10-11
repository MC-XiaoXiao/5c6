#!/usr/bin/env python3
"""Fetch pinned macOS/Linux tools and build custom restore tools; never access USB."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import urllib.error
import patchctl
from progress import log as progress_log
from hosttools import tool_directory, tool_env, require_tools, require_boot_tools
ROOT = Path(__file__).resolve().parent
PACKAGE = ROOT.parents[1]


def download(spec, target):
    target = Path(target)
    if target.is_symlink(): raise ValueError('Symlink download target refused')
    if target.exists():
        if target.stat().st_size != spec['bytes'] or patchctl.sha(target) != spec['sha256']:
            raise ValueError('Existing download differs: ' + str(target))
        return
    if not spec['url'].startswith('https://'): raise ValueError('Expected HTTPS')
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            request = urllib.request.Request(spec['url'], headers={'User-Agent': 'Project5C-tools/1'})
            for attempt in range(3):
                stream.seek(0); stream.truncate()
                try:
                    with urllib.request.urlopen(request, timeout=30) as response:
                        if not response.url.startswith('https://'): raise ValueError('Insecure redirect')
                        total = 0
                        while True:
                            block = response.read(min(1024 * 1024, spec['bytes'] + 1 - total))
                            if not block: break
                            total += len(block)
                            if total > spec['bytes']: raise ValueError('Download exceeds pinned size')
                            stream.write(block)
                    if total != spec['bytes']:
                        raise OSError('Truncated tool download')
                    stream.flush()
                    break
                except OSError as error:
                    permanent = isinstance(error, urllib.error.HTTPError) and error.code in [400, 404, 410]
                    if permanent or attempt == 2:
                        raise
            if total != spec['bytes'] or patchctl.sha(temporary) != spec['sha256']:
                raise ValueError('Download hash/size mismatch: ' + spec['url'])
            temporary.chmod(spec.get('mode', 0o644)); os.link(temporary, target)
        finally: temporary.unlink(missing_ok=True)


def build_dependencies():
    subprocess.run(['bash', str(PACKAGE / 'tools/dependencies.sh'), 'build'], check=True)
    if sys.platform == 'darwin' and shutil.which('brew'):
        paths = []
        for name in ['openssl@3', 'zlib', 'curl', 'libzip']:
            prefix = subprocess.check_output(['brew', '--prefix', name], text=True).strip()
            paths.append(str(Path(prefix) / 'lib/pkgconfig'))
        os.environ['PKG_CONFIG_PATH'] = ':'.join(paths + [os.environ.get('PKG_CONFIG_PATH', '')])
    missing = [n for n in ['git', 'cmake', 'cc', 'make', 'autoreconf', 'pkg-config'] if not shutil.which(n)]
    if missing: raise ValueError('Install build programs: ' + ', '.join(missing))
    packages = ['openssl', 'zlib', 'libimobiledevice-1.0', 'libirecovery-1.0', 'libimobiledevice-glue-1.0',
                'libtatsu-1.0', 'libusbmuxd-2.0', 'libplist-2.0', 'libzip', 'libcurl']
    missing = [n for n in packages if subprocess.run(['pkg-config', '--exists', n], capture_output=True).returncode]
    if missing: raise ValueError('Install development libraries (pkg-config): ' + ', '.join(missing))


def extract_source(archive, destination):
    destination.mkdir(parents=True, exist_ok=False)
    with tarfile.open(archive) as tar:
        for member in tar.getmembers():
            parts = Path(member.name).parts
            if len(parts) < 2: continue
            member.name = str(Path(*parts[1:])); tar.extract(member, destination, filter='data')


def custom_receipt(out):
    receipt = out / 'custom-tools.json'
    builders={name:patchctl.sha((PACKAGE/'patches/host'/Path(name).name)) for name in ['maintenance/build_restore_host.py','maintenance/build_restore_dmg.py','19-host-tools/patches/xpwn.patch']}
    if receipt.exists():
        report = patchctl.json_read(receipt)
        if (set(report.get('files', {})) != {'dmg', 'idevicerestore'}
                or report.get('explicit_zero_dmg') is not True
                or report.get('native6_restore_host') is not True):
            raise ValueError('Incomplete custom restore receipt')
        if report['source_lock_sha256'] != patchctl.sha(PACKAGE / 'tools/locks/third-party-tools.json') or report.get('builders')!=builders:
            raise ValueError('Source lock changed; use a new tools directory')
        for name, expected in report['files'].items():
            if patchctl.sha(patchctl.relative(out, name)) != expected: raise ValueError('Custom tool changed: ' + name)
        return report
    return None


def build_custom(out, lock):
    report = custom_receipt(out)
    if report is not None:
        return report
    if sys.version_info < (3, 12):
        raise ValueError('Building custom restore tools requires Python 3.12+ for safe source extraction')
    build_dependencies()
    for name, spec in lock['sources'].items():
        progress_log('Downloading/checking source: ' + name)
        download(spec, out / 'sources' / (name + '.tar.gz'))
    work = out / 'build'; work.mkdir(exist_ok=True)
    source = work / 'xpwn-source'
    if source.exists(): raise ValueError('Incomplete build retained; use a new --out directory')
    extract_source(out / 'sources/xpwn.tar.gz', source)
    log = work / 'build.log'
    # Keep system package discovery consistent with the dependency check, including Homebrew keg paths.
    env = dict(os.environ); env.pop('LD_LIBRARY_PATH', None)
    commands = [
        ['git', 'apply', str(PACKAGE / 'patches/host/xpwn.patch')],
        ['cmake', '-S', str(source), '-B', str(work / 'xpwn-build'), '-DCMAKE_POLICY_VERSION_MINIMUM=3.5'],
        ['cmake', '--build', str(work / 'xpwn-build'), '--target', 'dmg-bin', '-j2'],
        [sys.executable, '-B', str(PACKAGE / 'patches/host/build_restore_dmg.py'), '--source', str(source),
         '--build', str(work / 'xpwn-build'), '--out', str(work / 'explicit-zero-dmg')],
        [sys.executable, '-B', str(PACKAGE / 'patches/host/build_restore_host.py'), '--source-archive',
         str(out / 'sources/idevicerestore.tar.gz'), '--out', str(work / 'restore-host')],
    ]
    with log.open('x') as stream:
        for command in commands:
            progress_log('Building: ' + Path(command[0]).name + '; log: ' + str(log))
            subprocess.run(command, cwd=source, env=env, check=True, stdout=stream, stderr=subprocess.STDOUT)
    files = {'dmg': work / 'explicit-zero-dmg/dmg', 'idevicerestore': work / 'restore-host/src/idevicerestore'}
    for name, source in files.items():
        target = out / name
        if target.exists(): raise ValueError('Refusing to overwrite: ' + name)
        shutil.copyfile(source, target); target.chmod(0o755)
    builders={name:patchctl.sha(PACKAGE/'patches/host'/Path(name).name) for name in ['maintenance/build_restore_host.py','maintenance/build_restore_dmg.py','19-host-tools/patches/xpwn.patch']}
    report = {'builders':builders, 'source_lock_sha256': patchctl.sha(PACKAGE / 'tools/locks/third-party-tools.json'),
              'files': {n: patchctl.sha(out / n) for n in files}, 'explicit_zero_dmg': True,
              'native6_restore_host': True, 'device_accessed': False}
    patchctl.json_write(receipt, report); return report


def setup(out, arch, custom=True, detection_only=False, platform=None):
    out = Path(out).resolve(); tool_directory(tools_dir=out)
    lock = patchctl.json_read(PACKAGE / 'tools/locks/third-party-tools.json')
    platform = platform or ('macos' if sys.platform == 'darwin' else 'linux')
    variants = lock['macos'] if platform == 'macos' else lock['architectures']
    if arch not in variants: raise ValueError('Unsupported tool architecture')
    rows = variants[arch]
    if detection_only:
        rows = [row for row in rows if row['path'] in ['irecovery', 'ideviceinfo'] or row['path'].startswith('lib/')]
    for row in rows:
        progress_log('Downloading/checking: ' + row['path'])
        download(row, patchctl.relative(out, row['path']))
    patchctl.json_write(out / 'upstream-tools.json', {'architecture': arch, 'upstream_commit': lock['upstream_commit'],
                      'platform': platform, 'files': rows, 'source_repositories': lock['source_repositories']})
    if custom: build_custom(out, lock)
    return {'passed': True, 'tools_directory': str(out), 'architecture': arch,
            'custom_restore_tools': custom, 'device_accessed': False, 'firmware_downloaded': False}


def check(out, scope='restore'):
    """Check tool availability and custom receipts; probes never access USB."""
    out = Path(out).resolve()
    if scope == 'detection':
        return {'passed': True, 'scope': scope}
    require_boot_tools(out)
    if scope == 'restore':
        require_tools(out, ['hfsplus', 'xpwntool', 'iBoot32Patcher', 'dmg', 'idevicerestore'])
        if custom_receipt(out) is None:
            raise ValueError('Custom restore receipt missing; run tools.py setup with a new tools directory')
        result = subprocess.run([str(out / 'idevicerestore'), '--version'], env=tool_env(out),
                                capture_output=True, text=True, timeout=15)
        if result.returncode or '1.0.0-native6-5c' not in result.stdout:
            raise ValueError('The bundled restore host cannot run. Check README.md for runtime requirements.\n' + result.stderr.strip())
    return {'passed': True, 'scope': scope, 'device_accessed': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['setup', 'fetch', 'detection', 'check'])
    parser.add_argument('--platform', choices=['linux', 'macos'], help='Target platform for fetch only')
    parser.add_argument('--scope', choices=['detection', 'boot', 'restore'], default='restore')
    native = {'x86_64': 'x86_64', 'aarch64': 'arm64', 'arm64': 'arm64'}.get(os.uname().machine)
    default = PACKAGE / 'tools/bin/macos' if sys.platform == 'darwin' else PACKAGE / 'tools/bin/linux' / (native or os.uname().machine)
    parser.add_argument('--out', type=Path, default=default)
    parser.add_argument('--arch', choices=['x86_64', 'arm64'], default=native)
    parser.add_argument('--json', action='store_true', help='Print the full tool report to stdout')
    args = parser.parse_args()
    if args.platform and args.command != 'fetch': parser.error('--platform is for fetch only')
    if args.command == 'setup' and args.arch != native: parser.error('setup builds for this host; use fetch for other architectures')
    try:
        report = check(args.out, args.scope) if args.command == 'check' else setup(args.out, args.arch, args.command == 'setup', args.command == 'detection', args.platform)
        if args.json:
            print(json.dumps(report, indent=2))
        else:
            progress_log(f'Host tools {args.command} complete: {args.out} (scope: {args.scope})', 'DONE')
    except (OSError, ValueError, subprocess.SubprocessError) as error: parser.exit(2, 'tools.py: ' + str(error) + '\n')


if __name__ == '__main__': main()
