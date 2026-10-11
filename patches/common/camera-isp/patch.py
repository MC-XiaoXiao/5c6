"""Patch definition: common/camera-isp. Binary operation data stays in data.json."""

PATCH = {
    'kind': 'edits',
    'input': 'n49-isp.bin',
    'baseline_output_sha256': '565250b0dcab05f840adf12907615707ac9d6a0999be5778ee94b382d549465e',
    'destination': 'rootfs/usr/local/share/firmware/isp/h4_isp_fw.bin',
    'mode': 0o644,
    'data': 'common/camera-isp/data.json',
}
