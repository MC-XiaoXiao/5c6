#include "p5.h"
#include <openssl/sha.h>

static uint64_t uleb(Blob b, size_t *at) {
  uint64_t v = 0;
  for (unsigned shift = 0; shift < 64; shift += 7) {
    need(*at < b.n, "Truncated export ULEB");
    unsigned char c = b.p[(*at)++];
    need(shift < 63 || (c & 0x7f) <= 1, "Export ULEB overflow");
    v |= (uint64_t)(c & 0x7f) << shift;
    if (!(c & 0x80)) return v;
  }
  die("Export ULEB overflow");
  return 0;
}
static uint32_t exported(Blob trie, const char *symbol) {
  size_t at = 0, matched = 0;
  for (unsigned depth = 0; depth < 1024; depth++) {
    size_t p = at;
    uint64_t size = uleb(trie, &p);
    need(size <= trie.n - p, "Export terminal outside trie");
    if (!symbol[matched]) {
      need(size != 0, "Required exported symbol missing");
      Blob terminal = {trie.p + p, (size_t)size};
      size_t q = 0;
      need(uleb(terminal, &q) == 0, "Unsupported export flags");
      uint64_t address = uleb(terminal, &q);
      need(address <= UINT32_MAX, "Export address overflow");
      return (uint32_t)address;
    }
    p += size;
    need(p < trie.n, "Truncated export children");
    unsigned count = trie.p[p++];
    int found = 0;
    for (unsigned i = 0; i < count; i++) {
      size_t start = p;
      while (p < trie.n && trie.p[p]) p++;
      need(p < trie.n && p > start, "Invalid export edge");
      size_t length = p++ - start;
      uint64_t next = uleb(trie, &p);
      need(next < trie.n, "Export child outside trie");
      if (!found && strlen(symbol + matched) >= length &&
          !memcmp(symbol + matched, trie.p + start, length)) {
        at = next;
        matched += length;
        found = 1;
        break;
      }
    }
    need(found, "Required exported symbol missing");
  }
  die("Cyclic export trie");
  return 0;
}
static unsigned char *unique_string(Blob b, const char *s) {
  size_t n = strlen(s) + 1;
  unsigned char *found = NULL;
  for (size_t i = 0; i + n <= b.n; i++)
    if (!memcmp(b.p + i, s, n)) {
      need(!found, "Ambiguous baseband string");
      found = b.p + i;
    }
  need(found != NULL, "Baseband string missing");
  return found;
}
static void thumb_branch(unsigned char *p, size_t from, size_t to) {
  int64_t delta = (int64_t)to - (int64_t)from - 4;
  need(!(delta & 1) && delta >= -16777216 && delta < 16777216,
       "Thumb branch out of range");
  uint32_t bits = (uint32_t)delta;
  unsigned s=(bits>>24)&1, i1=(bits>>23)&1, i2=(bits>>22)&1;
  unsigned a=0xf000|(s<<10)|((bits>>12)&1023);
  unsigned b=0x9000|((!(i1^s))<<13)|((!(i2^s))<<11)|((bits>>1)&2047);
  p[0]=a; p[1]=a>>8; p[2]=b; p[3]=b>>8;
}
int macho_main(int argc, char **argv) {
  if (strcmp(argv[1], "baseband-image")) return 0;
  need(argc == 4, "baseband-image ORIGINAL_RESTORED OUTPUT");
  Blob b = read_file(argv[2]);
  unsigned char digest[32];
  SHA256(b.p, b.n, digest);
  char *sha = hex((Blob){digest, sizeof(digest)});
  /* The N48 and N49 11A470a restore ramdisks carry the same native updater.
   * Refuse other versions even if their exported symbol names match. */
  int ios6 = !strcmp(sha, "ba0f626e42d66b0de6caf35ba07bf012ac19eaa132ec7aff25ecefae5ae2b82b");
  need(ios6 || !strcmp(sha, "b796e43c6b8aa77d7a257bb53a2d746b58092ce147e32c8d820b5f5a7d117a40"),
       "Unsupported original restored image (iOS 6 libBBUpdater-128 / 11A470a)");
  free(sha);
  need(b.n >= 28 && le32(b.p) == 0xfeedface && le32(b.p + 4) == 12 &&
           le32(b.p + 12) == 2, "Expected ARM executable");
  size_t count = le32(b.p + 16), bytes = le32(b.p + 20), p = 28;
  need(bytes <= b.n - 28 && count <= 4096, "Invalid Mach-O commands");
  Blob trie = {0};
  size_t first = b.n;
  uint32_t base = 0;
  for (size_t i = 0; i < count; i++) {
    need(p + 8 <= 28 + bytes, "Truncated load command");
    uint32_t cmd = le32(b.p + p), size = le32(b.p + p + 4);
    need(size >= 8 && size <= 28 + bytes - p, "Invalid load command");
    if (cmd == 0x80000022 || cmd == 0x22) {
      need(size >= 48, "Short dyld command");
      size_t off = le32(b.p + p + 40), n = le32(b.p + p + 44);
      need(off <= b.n && n <= b.n - off && n, "Invalid export trie extent");
      trie = (Blob){b.p + off, n};
    }
    if (cmd == 1) {
      need(size >= 56, "Short segment command");
      uint32_t sections = le32(b.p + p + 48);
      need(sections <= (size - 56) / 68, "Invalid section count");
      if (!memcmp(b.p + p + 8, "__TEXT\0", 7)) {
        need(le32(b.p + p + 32) == 0, "Unsupported TEXT mapping");
        base = le32(b.p + p + 24);
      }
      for (unsigned j = 0; j < sections; j++) {
        size_t q = p + 56 + 68 * j;
        size_t off = le32(b.p + q + 40);
        if (off && off < first) first = off;
      }
    }
    p += size;
  }
  need(p == 28 + bytes && trie.n && base == 0x1000, "Unsupported native Mach-O layout");
  const char *symbols[] = {"__ZN21BBUpdaterPersonalized13fusingAllowedEv",
      "__ZN21BBUpdaterPersonalized17getShouldEraseEFSEv",
      "__ZN21BBUpdaterPersonalized19getNVRestoreSettingEv"};
  const unsigned char before[3][4] = {{0xb0,0xb5,2,0xaf},{0xf0,0xb5,3,0xaf},{0xb0,0xb5,2,0xaf}};
  for (unsigned i = 0; i < 3; i++) {
    /* Export addresses are image-relative; Thumb bit is part of the export. */
    size_t off = exported(trie, symbols[i]) & ~1u;
    need(off <= b.n && b.n - off >= 4 && !memcmp(b.p + off, before[i], 4),
         "Native baseband guard preimage differs");
    b.p[off] = i == 2 ? 3 : 0;
    b.p[off+1] = 0x20; b.p[off+2] = 0x70; b.p[off+3] = 0x47;
  }
  if (ios6) {
    /* The iOS 6 EUR4 loader already implements the Mav7 wire protocol.
     * Adapt its USB IDs, retaining all ticket/hash authentication code. */
    size_t off = exported(trie, "_TelephonyCapabilitiesRadioProgrammerProductID") & ~1u;
    need(off + 4 <= b.n && !memcmp(b.p + off, "\x80\xb5\x6f\x46", 4),
         "iOS 6 programmer PID preimage differs");
    memcpy(b.p + off, "\x03\x20\x70\x47", 4);
    off = exported(trie, "_TelephonyCapabilitiesRadioDIAGGetBootedProductID") & ~1u;
    need(off + 6 <= b.n && !memcmp(b.p + off, "\x80\xb5\x6f\x46\xff\xf7", 6),
         "iOS 6 runtime PID preimage differs");
    memcpy(b.p + off, "\x49\xf2\x33\x00\x70\x47", 6);
    const char *path = "/usr/local/standalone/firmware/Baseband/Mav5";
    unsigned char *hit = unique_string(b, path);
    const char *runtime = "/usr/local/share/project5c/Mav7";
    memset(hit, 0, strlen(path));
    memcpy(hit, runtime, strlen(runtime));
    const char *prefix = "Mav5-";
    hit = unique_string(b, prefix);
    /* Mav7 matches the stock Mav7Mav8- package name. */
    memcpy(hit, "Mav7\0\0", 6);
  }
  const char *install = "/usr/local/lib/project5c-baseband.dylib";
  size_t length = (24 + strlen(install) + 1 + 3) & ~(size_t)3;
  need(p <= first && length <= first - p, "No room for plugin load command");
  for (size_t i = 0; i < length; i++) need(!b.p[p+i], "Nonzero Mach-O header padding");
  putle(b.p + p, 0xc); putle(b.p + p + 4, length); putle(b.p + p + 8, 24);
  memcpy(b.p + p + 24, install, strlen(install) + 1);
  putle(b.p + 16, count + 1); putle(b.p + 20, bytes + length);
  if (ios6) {
    /* The no-argument factory overwrites the compatibility profile with the
     * real N48/N49 model before constructing its controller. Use its original
     * WithParameters path to retain the initialized N42 transport profile.
     * ADR and relative branches keep this bridge independent of ASLR. */
    size_t stub=(p+length+3)&~(size_t)3, factory=0x1cec4;
    const char *resolver="project5c_native_factory";
    size_t literal=(stub+24+strlen(resolver)+1+3)&~(size_t)3;
    need(literal+4 <= first, "No room for native factory bridge");
    for(size_t i=p+length;i<literal+4;i++)need(!b.p[i],"Nonzero factory bridge padding");
    need(!memcmp(b.p+factory,"\x00\x20\x00\xf0\x01\xb8\x00\xbf",8),
         "Native factory preimage differs");
    const unsigned char code[]={0xb0,0xb5,1,0x20,0xc0,0x43,4,0xa1,
        0,0x4b,0x7b,0x44,0x98,0x47,0,0xb1,0x80,0x47,0xb0,0xbd,
        0,0xbf,0,0xbf};
    memcpy(b.p+stub,code,sizeof(code));
    b.p[stub+8]=(literal-(stub+12))/4;
    memcpy(b.p+stub+24,resolver,strlen(resolver)+1);
    /* PIC address of the original ARM dlsym import stub; BLX interworks. */
    putle(b.p+literal,(uint32_t)(0xd8df0-(stub+14)));
    thumb_branch(b.p+factory,factory,stub);
    memcpy(b.p+factory+4,"\x00\xbf\x00\xbf",4);
  }
  write_file(argv[3], b);
  free(b.p);
  printf("{\"native_build\":\"%s\",\"fusing\":false,\"erase_efs\":false,\"nv_restore_setting\":3,\"main_preserved\":true,\"authentication_modified\":false,\"factory_preserves_transport_profile\":%s,\"factory_reports_initialization_errors\":%s}\n",
         ios6 ? "ios6-libbbu128" : "11A470a",ios6?"true":"false",ios6?"true":"false");
  return 1;
}
