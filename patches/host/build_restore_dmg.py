#!/usr/bin/env python3
"""Build an xpwn DMG writer that explicitly writes zero regions during ASR."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import shlex


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source', type=Path, required=True, help='xpwn source tree')
    p.add_argument('--build', type=Path, required=True, help='Matching compiled xpwn static libraries')
    p.add_argument('--out', type=Path, required=True, help='New private output directory')
    p.add_argument('--cc', default='cc')
    a = p.parse_args()
    source, build, out = a.source.resolve(), a.build.resolve(), a.out.resolve()
    text = (source / 'dmg/io.c').read_text()
    pattern = r'(?m)^#define USE_IGNORE_BLOCKS 1(?=\s|$)'
    if len(re.findall(pattern, text)) != 1:
        p.error('Expected one xpwn USE_IGNORE_BLOCKS=1 feature; unsupported or already modified source')
    libraries = [build / rel for rel in ['dmg/libdmg.a', 'hfs/libhfs.a', 'common/libcommon.a']]
    for path in [source / 'dmg/dmg.c', source / 'includes/dmg/dmg.h', *libraries]:
        if not path.is_file():
            p.error('Missing xpwn source/library: ' + str(path))
    if out.exists():
        p.error('--out must be a new directory')
    out.mkdir(parents=True)
    patched = out / 'io-explicit-zero.c'
    patched.write_text(re.sub(pattern, '#define USE_IGNORE_BLOCKS 0', text))
    crypto_cflags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', 'openssl'], text=True))
    crypto_libraries = shlex.split(subprocess.check_output(['pkg-config', '--libs', 'openssl', 'zlib'], text=True))
    flags = ['-O2', '-DHAVE_CRYPT', '-I' + str(source / 'includes'), *crypto_cflags]
    obj = out / 'io-explicit-zero.o'
    with (out / 'build.log').open('w') as log:
        subprocess.run([a.cc, *flags, '-c', str(patched), '-o', str(obj)],
                       check=True, stdout=log, stderr=subprocess.STDOUT)
        # Supply io.c first; the archive's original io.o is consequently not linked.
        subprocess.run([a.cc, *flags, str(source / 'dmg/dmg.c'), str(obj),
                        *map(str, libraries), *crypto_libraries, '-o', str(out / 'dmg')],
                       check=True, stdout=log, stderr=subprocess.STDOUT)
    receipt = dict(zero_regions_written=True, change='USE_IGNORE_BLOCKS: 1 -> 0',
                   source_feature='one exact macro definition',
                   builder_sha256=hashlib.sha256((out / 'dmg').read_bytes()).hexdigest())
    (out / 'build.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print('Built explicit-zero DMG tool:', out / 'dmg')


if __name__ == '__main__':
    main()
