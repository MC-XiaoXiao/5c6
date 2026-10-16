#!/usr/bin/env bash
# Cross-build the native restore compatibility library; link stubs stay on the host.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/../../lib/common.sh"
p5_args "$@"; p5_required linker out
LINKER=$(p5_abs "$(p5_get linker)"); OUT=$(p5_abs "$(p5_get out)")
SOURCE="$P5_ROOT/src/baseband/compat.c"
p5_temp
LIBS=()
stub() {
    local install=$1 symbol index=${#LIBS[@]} asm obj dll; shift
    asm="$P5_TMP/stub-$index.S"; obj="$P5_TMP/stub-$index-exit-asm.o"; dll="$P5_TMP/stub-$index.dylib"
    # ld64's bootstrap exception permits constructing the host-only libSystem stub.
    {
        printf '.syntax unified\n.text\n.thumb\n'
        for symbol in "$@"; do printf '.globl _%s\n.thumb_func _%s\n_%s:\n bx lr\n' "$symbol" "$symbol" "$symbol"; done
        printf '.align 2\n.globl dyld_stub_binder\ndyld_stub_binder:\n bx lr\n'
    } > "$asm"
    clang -target armv7-apple-ios6.0 -c "$asm" -o "$obj"
    "$LINKER" -arch armv7 -dylib -iphoneos_version_min 6.0 -install_name "$install" "$obj" ${LIBS[@]+"${LIBS[@]}"} -o "$dll"
    LIBS+=("$dll")
}
stub /usr/lib/libSystem.B.dylib dlsym sysctlbyname pthread_create pthread_detach socket bind listen accept close setsockopt send recv write malloc free mkdir strcmp memcmp strlen memset statfs64 mount open unlink _Unwind_SjLj_Register _Unwind_SjLj_Unregister _Unwind_SjLj_Resume
stub /System/Library/Frameworks/CoreFoundation.framework/CoreFoundation kCFBooleanTrue kCFBooleanFalse kCFTypeDictionaryKeyCallBacks kCFTypeDictionaryValueCallBacks CFStringCreateWithCString CFStringGetCString CFDictionaryCreateMutable CFDictionaryGetValue CFDictionarySetValue CFNumberCreate CFNumberGetValue CFDataCreate CFDataGetBytePtr CFDataGetLength CFPropertyListCreateData CFPropertyListCreateWithData CFGetTypeID CFDictionaryGetTypeID CFDataGetTypeID CFBooleanGetTypeID CFNumberGetTypeID CFBooleanGetValue CFEqual CFCopyDescription CFRelease CFErrorGetCode
stub /usr/lib/libMobileGestalt.dylib MGCopyAnswer
stub /usr/lib/libstdc++.6.dylib __gxx_personality_sj0 __cxa_begin_catch __cxa_end_catch _ZSt9terminatev
stub /System/Library/Frameworks/IOKit.framework/Versions/A/IOKit IOServiceMatching IOServiceGetMatchingService IOObjectRelease IORegistryEntryFromPath IORegistryEntryCreateCFProperty
LANGUAGE=(-x c++ -fexceptions -fcxx-exceptions)
clang -target armv7-apple-ios6.0 -mthumb -Os -fno-stack-protector -fno-builtin -Wall -Wextra -Werror ${LANGUAGE[@]+"${LANGUAGE[@]}"} -c "$SOURCE" -o "$P5_TMP/agent.o"
OBJECTS=("$P5_TMP/agent.o")
mkdir -p "$(dirname -- "$OUT")"
"$LINKER" -arch armv7 -dylib -iphoneos_version_min 6.0 -install_name /usr/local/lib/project5c-baseband.dylib "${OBJECTS[@]}" "${LIBS[@]}" -o "$OUT"
