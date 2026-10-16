#include "p5.h"
#include <openssl/sha.h>
#include "media_payloads.h"
#include "media_audio_features.h"
#include "media_h4isp_profile.h"

static uint64_t u64(const unsigned char *p) {
    return (uint64_t)le32(p) | (uint64_t)le32(p + 4) << 32;
}
static int digest(Blob b, const char *wanted) {
    unsigned char bytes[32];
    SHA256(b.p, b.n, bytes);
    char *actual = hex((Blob){bytes, sizeof(bytes)});
    int same = !strcmp(actual, wanted);
    free(actual);
    return same;
}
static void match(Blob b, size_t off, const void *expected, size_t size) {
    need(off <= b.n && size <= b.n - off && !memcmp(b.p + off, expected, size),
         "Media patch preimage differs");
}
static void blank(Blob b, size_t off, size_t size) {
    need(off <= b.n && size <= b.n - off, "Media cavity exceeds file");
    for (size_t i = 0; i < size; i++) need(!b.p[off + i], "Media cavity is not zero padding");
}
static void branch(unsigned char *out, uint32_t site, uint32_t target, int link) {
    int64_t delta = (int64_t)target - site - 4;
    need(!(delta & 1) && delta >= -16777216 && delta < 16777216, "Media branch exceeds range");
    uint32_t bits = (uint32_t)delta;
    unsigned s = (bits >> 24) & 1, i1 = (bits >> 23) & 1, i2 = (bits >> 22) & 1;
    uint16_t first = 0xf000 | (s << 10) | ((bits >> 12) & 1023);
    uint16_t second = (link ? 0xd000 : 0x9000) | ((! (i1 ^ s)) << 13) |
                      ((! (i2 ^ s)) << 11) | ((bits >> 1) & 2047);
    out[0] = first; out[1] = first >> 8; out[2] = second; out[3] = second >> 8;
}
/* Both supported media images have a zero executable header gap. No segment,
 * section, import or relocation command is changed by these patches. */
static void cavity(Blob b, size_t header, uint32_t address, size_t offset, size_t size) {
    need(header <= b.n && b.n - header >= 28 && le32(b.p + header) == 0xfeedface &&
         le32(b.p + header + 4) == 12 && le32(b.p + header + 8) == 11,
         "Expected armv7s media image");
    size_t count = le32(b.p + header + 16), bytes = le32(b.p + header + 20), pos = header + 28;
    need(count <= 100 && bytes <= b.n - pos && offset >= pos + bytes, "Invalid media load commands/cavity");
    uint32_t first = UINT32_MAX;
    int executable = 0;
    for (size_t i = 0; i < count; i++) {
        need(pos + 8 <= header + 28 + bytes, "Truncated media command");
        uint32_t cmd = le32(b.p + pos), length = le32(b.p + pos + 4);
        need(length >= 8 && length <= header + 28 + bytes - pos, "Invalid media command");
        if (cmd == 1) {
            need(length >= 56, "Short media segment");
            uint32_t vm = le32(b.p + pos + 24), fs = le32(b.p + pos + 36), sections = le32(b.p + pos + 48);
            need(sections <= (length - 56) / 68, "Media sections exceed command");
            if ((le32(b.p + pos + 44) & 4) && address >= vm && size <= fs && address - vm <= fs - size)
                executable = 1;
            for (size_t j = 0; j < sections; j++) {
                size_t section = pos + 56 + j * 68;
                uint32_t va = le32(b.p + section + 32);
                if (va >= address && va < first && le32(b.p + section + 36)) first = va;
            }
        }
        pos += length;
    }
    need(pos == header + 28 + bytes && executable && size <= first - address,
         "Media cavity overlaps section or is not executable");
    blank(b, offset, size);
}
static void audio(Blob b) {
    need(digest(b, "7e5d5193316ede9fd2932efec8acca2974a18f1381473f0ceae7b8fc240be1ba") ||
         digest(b, "7f3c1ceed5c178ca91df2a8a7271858be8f278aa3b643a4f9a25013d3a8879d8"),
         "Unsupported original VirtualAudio");
    cavity(b, 0, 0xc00, 0xc00, sizeof(virtualaudio_model_code));
    match(b, 0x1d16b6, "\x57\xf0\x94\xec", 4);
    match(b, 0x18451e, audio_uid_before, sizeof(audio_uid_before));
    match(b, 0x1846f4, audio_setup_before, sizeof(audio_setup_before));
    memcpy(b.p + 0xc00, virtualaudio_model_code, sizeof(virtualaudio_model_code));
    branch(b.p + 0x1d16b6, 0x1d16b6, 0xc00, 1);
    b.p[0x184520] = 0x2e;
    memcpy(b.p + 0x1846f4, "\x00\xbf\x00\xbf", 4);
}
static size_t mapped(Blob b, uint32_t address, size_t length) {
    need(b.n >= 48 && !memcmp(b.p, "dyld_v1", 7), "Expected legacy dyld shared cache");
    size_t start = le32(b.p + 16), count = le32(b.p + 20);
    need(start <= b.n && count > 0 && count <= 32 && count <= (b.n - start) / 32, "Invalid cache mappings");
    size_t found = SIZE_MAX;
    for (size_t i = 0; i < count; i++) {
        const unsigned char *row = b.p + start + i * 32;
        uint64_t vm = u64(row), size = u64(row + 8), file = u64(row + 16);
        need(file <= b.n && size <= b.n - file && vm + size >= vm, "Cache mapping exceeds file");
        if (address >= vm && length <= size && address - vm <= size - length) {
            need(found == SIZE_MAX, "Overlapping cache mappings");
            found = file + address - vm;
        }
    }
    need(found != SIZE_MAX, "Media address outside cache");
    return found;
}
static size_t h4isp_image(Blob b) {
    size_t start = le32(b.p + 24), count = le32(b.p + 28), found = SIZE_MAX;
    need(start <= b.n && count <= 4096 && count <= (b.n - start) / 32, "Invalid cache images");
    for (size_t i = 0; i < count; i++) {
        const unsigned char *row = b.p + start + i * 32;
        size_t path = le32(row + 24);
        need(path < b.n && memchr(b.p + path, 0, b.n - path), "Invalid cache image path");
        if (!strcmp((const char *)b.p + path, "/System/Library/MediaCapture/H4ISP.mediacapture")) {
            need(found == SIZE_MAX && u64(row) == 0x33556000, "Unsupported/duplicate H4ISP mapping");
            found = mapped(b, (uint32_t)u64(row), 28);
        }
    }
    need(found != SIZE_MAX, "H4ISP missing from shared cache");
    return found;
}
static void camera(Blob b, Blob setfile) {
    need(setfile.n == 0x578c && digest(setfile, "a18119fd0028919b0ed97d3678fe5433752c7b84e26bdce392cc79babd7fb409"),
         "OV9762 requires the verified 7652 setfile");
    /* Validate cache header before h4isp_image reads its image table. */
    mapped(b, 0x33556000, 28);
    size_t header = h4isp_image(b), code = mapped(b, 0x33556b98, 173064);
    need(digest((Blob){b.p + code, 173064}, "58832c0e4400f37129383a5d091aebd3dc36fe448df6045c880a128bd5515a15"),
         "Unsupported H4ISP code");
    size_t table = mapped(b, 0x33584f80, sizeof(profile));
    need(digest((Blob){b.p + table, sizeof(profile)}, "66f4637587726565be9c90e57011351bc944045194d98d9bd539a291fc48f534"),
         "Unsupported H4ISP profile table");
    size_t cave = mapped(b, 0x33556a00, sizeof(h4isp_selector_code));
    cavity(b, header, 0x33556a00, cave, sizeof(h4isp_selector_code));
    size_t selector = mapped(b, 0x33576850, 8), whitelist = mapped(b, 0x33561cb2, 4), model = mapped(b, 0x3356207c, 4);
    match(b, selector, "\x90\xb5\x01\xaf\x82\xb0\xd7\xf8", 8);
    match(b, whitelist, "\x49\xf2\x60\x71", 4);
    match(b, model, "\x49\xf2\x60\x71", 4);
    memcpy(b.p + cave, h4isp_selector_code, sizeof(h4isp_selector_code));
    branch(b.p + selector, 0x33576850, 0x33556a00, 0);
    b.p[whitelist + 2] = 0x62;
    b.p[model + 2] = 0x62;
    memcpy(b.p + table, profile, sizeof(profile));
}
int media_main(int argc, char **argv) {
    if (!strcmp(argv[1], "media-audio")) {
        need(argc == 4, "media-audio ORIGINAL_VIRTUALAUDIO OUTPUT");
        Blob b = read_file(argv[2]);
        audio(b);
        write_file(argv[3], b);
        free(b.p);
        puts("{\"module\":\"VirtualAudio\",\"model_query_local\":true,\"codec_route\":true,\"new_imports\":false}");
    } else if (!strcmp(argv[1], "media-h4isp")) {
        need(argc == 5, "media-h4isp SENSOR_PATCHED_CACHE SETFILE OUTPUT");
        Blob b = read_file(argv[2]), setfile = read_file(argv[3]);
        camera(b, setfile);
        write_file(argv[4], b);
        free(b.p); free(setfile.p);
        puts("{\"module\":\"H4ISP\",\"sensor\":\"OV9762\",\"revision\":32,\"native_file_loader\":true,\"new_imports\":false}");
    } else return 0;
    return 1;
}
