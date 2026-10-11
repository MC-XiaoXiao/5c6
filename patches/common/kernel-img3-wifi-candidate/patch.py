"""Patch definition: common/kernel-img3-wifi-candidate."""

PATCH = {
    'kind': 'container',
    'input': None,
    'core': 'kernel-wifi-candidate',
    'destination': 'boot/kernelcache.img3',
    'mode': 0o644,
    'template_file': 'common/kernel-img3-wifi-candidate/template.img3',
    'compression_header_file': 'common/kernel-img3-wifi-candidate/compression-header.bin',
}
