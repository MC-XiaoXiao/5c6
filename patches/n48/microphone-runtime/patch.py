"""Patch definition: n48/microphone-runtime."""

PATCH = {
    'kind': 'feature-runtime',
    'input': None,
    'payload': 'n48/microphone-runtime/payload',
    'model': 'N48AP',
    'destination': 'rootfs/usr/local/lib/native6-microphone-fix.dylib',
    'match': {'model': 'N48AP'},
    'mode': 0o755,
    'sources': [
        'common/microphone-runtime/src/audio_features.h',
        'common/microphone-runtime/src/native6_audio_codec_route.c',
        'common/microphone-runtime/src/native6_audio_microphone_fix.c',
        'n48/microphone-runtime/src/native6_audio_model_alias.c',
        'common/microphone-runtime/src/native6_audio_route_trace.c',
    ],
}
