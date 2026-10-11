"""Patch definition: n49/microphone-runtime."""

PATCH = {
    'kind': 'feature-runtime',
    'input': None,
    'payload': 'n49/microphone-runtime/payload',
    'destination': 'rootfs/usr/local/lib/native6-microphone-fix.dylib',
    'mode': 0o755,
    'sources': [
        'common/microphone-runtime/src/audio_features.h',
        'common/microphone-runtime/src/native6_audio_codec_route.c',
        'common/microphone-runtime/src/native6_audio_microphone_fix.c',
        'n49/microphone-runtime/src/native6_audio_model_alias.c',
        'common/microphone-runtime/src/native6_audio_route_trace.c',
    ],
}
