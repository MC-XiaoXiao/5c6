"""Create a checked tethered jailbreak bootstrap tar for the System image."""
import hashlib
import io
import json
from integrity import declaration
from pathlib import Path, PurePosixPath
import posixpath
import tarfile

PATCHES = Path(__file__).resolve().parents[2] / 'patches/jailbreak'


def bootstrap(destination):
    spec = declaration(PATCHES / 'bootstrap.py', 'BOOTSTRAP')
    files = {}
    for row in spec['archives']:
        path = PATCHES / row['path']
        if path.parent != PATCHES or path.stat().st_size != row['bytes'] or hashlib.sha256(path.read_bytes()).hexdigest() != row['sha256']:
            raise ValueError('Jailbreak archive integrity mismatch')
        with tarfile.open(path) as archive:
            for member in archive:
                name = member.name.removeprefix('./').rstrip('/')
                if name in ['', '.']:
                    continue
                parts = PurePosixPath(name).parts
                if name.startswith('/') or '..' in parts or not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
                    raise ValueError('Unsupported jailbreak archive member')
                if member.issym() and not member.linkname.startswith('/'):
                    target = posixpath.normpath(posixpath.join(posixpath.dirname(name), member.linkname))
                    if target.startswith('../'):
                        raise ValueError('Jailbreak symlink escapes image')
                hardlink = member.islnk()
                if hardlink and (member.linkname.startswith('/') or '..' in PurePosixPath(member.linkname).parts):
                    raise ValueError('Unsafe bootstrap hardlink')
                data = archive.extractfile(member).read() if member.isfile() or hardlink else None
                if hardlink:
                    member.type = tarfile.REGTYPE
                    member.linkname = ''
                    member.size = len(data)
                # Data is reformatted by restored. Keep its seed on System until first boot.
                if name == 'private/var' or name.startswith('private/var/'):
                    if not (name == 'private/var/lib' or name.startswith('private/var/lib/') or name == 'private/var/root/Media/Cydia' or name.startswith('private/var/root/Media/Cydia/')):
                        continue
                    name = name.replace('private/var', 'private/project5c-jailbreak/seed', 1)
                if name == 'Library/LaunchDaemons/com.saurik.Cydia.Startup.plist':
                    continue
                member.name = name
                files[name] = (member, data)
    essential = ['Applications/Cydia.app/Cydia', 'bin/bash', 'usr/bin/dpkg', 'usr/libexec/cydia/startup', 'private/project5c-jailbreak/seed/lib/dpkg/status']
    if any(name not in files for name in essential):
        raise ValueError('Jailbreak bootstrap lacks essential files')
    # Preserve package ownership and modes, including required setuid bits.
    with tarfile.open(destination, 'w', format=tarfile.USTAR_FORMAT) as output:
        for name, (member, data) in sorted(files.items()):
            member.uname = member.gname = ''
            member.mtime = 0
            output.addfile(member, io.BytesIO(data) if data is not None else None)
    return {'kind': spec['kind'], 'archive_sha256': hashlib.sha256(Path(destination).read_bytes()).hexdigest(), 'files': len(files), 'tethered': True, 'data_seed': '/private/project5c-jailbreak/seed', 'essential_paths': essential, 'essential_sha256': {name: hashlib.sha256(files[name][1]).hexdigest() for name in essential}}
