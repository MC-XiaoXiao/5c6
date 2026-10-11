"""Patch definition: common/kernel-img3-validated."""

PATCH = {
    'kind': 'container',
    'input': None,
    'core': 'kernel-validated',
    'destination': 'boot/kernelcache.img3',
    'mode': 0o644,
    'template_file': 'common/kernel-img3-validated/template.img3',
    'compression_header_file': 'common/kernel-img3-validated/compression-header.bin',
}
