/* Bounded binary format operations. Firmware-specific patch rules live in Bash.
 */
#include "p5.h"
#include <bzlib.h>
#include <openssl/evp.h>
#include <openssl/sha.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>
#define LIMIT ((size_t)1024 * 1024 * 1024)
void die(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  fputs("p5: ", stderr);
  vfprintf(stderr, fmt, ap);
  va_end(ap);
  fputc('\n', stderr);
  exit(2);
}
void need(int ok, const char *s) {
  if (!ok)
    die("%s", s);
}
void *alloc(size_t n) {
  need(n <= LIMIT, "Binary allocation exceeds limit");
  void *p = calloc(n ? n : 1, 1);
  if (!p)
    die("Out of memory");
  return p;
}
Blob read_file(const char *name) {
  FILE *f = fopen(name, "rb");
  if (!f)
    die("Cannot read %s: %s", name, strerror(errno));
  need(!fseeko(f, 0, SEEK_END), "Seek failed");
  off_t n = ftello(f);
  need(n >= 0 && (uint64_t)n <= LIMIT, "Input exceeds binary limit");
  rewind(f);
  Blob b = {alloc(n), (size_t)n};
  need(fread(b.p, 1, b.n, f) == b.n, "Truncated file");
  fclose(f);
  return b;
}
void write_file(const char *name, Blob b) {
  FILE *f = fopen(name, "wb");
  if (!f)
    die("Cannot write %s", name);
  need(fwrite(b.p, 1, b.n, f) == b.n && !fclose(f), "Write failed");
}
uint32_t le32(const unsigned char *p) {
  return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 |
         (uint32_t)p[3] << 24;
}
uint32_t be32(const unsigned char *p) {
  return (uint32_t)p[3] | (uint32_t)p[2] << 8 | (uint32_t)p[1] << 16 |
         (uint32_t)p[0] << 24;
}
uint64_t be64(const unsigned char *p) {
  return (uint64_t)be32(p) << 32 | be32(p + 4);
}
void putle(unsigned char *p, uint32_t n) {
  for (int i = 0; i < 4; i++)
    p[i] = (unsigned char)(n >> (i * 8));
}
void putbe(unsigned char *p, uint32_t n) {
  for (int i = 0; i < 4; i++)
    p[3 - i] = (unsigned char)(n >> (i * 8));
}
Blob unhex(const char *s) {
  size_t n = strlen(s);
  need(!(n % 2), "Odd hex length");
  Blob b = {alloc(n / 2), n / 2};
  for (size_t i = 0; i < b.n; i++) {
    unsigned v = 0;
    char pair[3] = {s[2 * i], s[2 * i + 1], 0};
    need(strspn(pair, "0123456789abcdefABCDEF") == 2 &&
             sscanf(pair, "%x", &v) == 1,
         "Invalid hexadecimal");
    b.p[i] = v;
  }
  return b;
}
char *hex(Blob b) {
  char *s = alloc(b.n * 2 + 1);
  for (size_t i = 0; i < b.n; i++)
    sprintf(s + 2 * i, "%02x", b.p[i]);
  return s;
}
static int64_t offtin(unsigned char *p) {
  uint64_t n = p[7] & 127;
  for (int i = 6; i >= 0; i--)
    n = (n << 8) | p[i];
  need(n <= INT64_MAX, "BSDIFF integer overflow");
  return p[7] & 128 ? -(int64_t)n : (int64_t)n;
}
static Blob bunzip(Blob in, size_t cap) {
  need(cap < UINT32_MAX && in.n < UINT32_MAX, "BSDIFF stream too large");
  Blob out = {alloc(cap), cap};
  bz_stream z = {0};
  z.next_in = (char *)in.p;
  z.avail_in = in.n;
  z.next_out = (char *)out.p;
  z.avail_out = cap;
  need(BZ2_bzDecompressInit(&z, 0, 0) == BZ_OK, "bzip init failed");
  int ret = BZ2_bzDecompress(&z);
  need(ret == BZ_STREAM_END && !z.avail_in,
       "Invalid or oversized BSDIFF stream");
  out.n = cap - z.avail_out;
  BZ2_bzDecompressEnd(&z);
  return out;
}
static void bspatch(const char *a, const char *b, const char *c) {
  Blob old = read_file(a), patch = read_file(b);
  need(patch.n >= 32 && !memcmp(patch.p, "BSDIFF40", 8), "Expected BSDIFF40");
  int64_t cs = offtin(patch.p + 8), ds = offtin(patch.p + 16),
          ns = offtin(patch.p + 24);
  need(cs >= 0 && ds >= 0 && ns >= 0 && (uint64_t)ns <= LIMIT &&
           (uint64_t)cs + ds <= patch.n - 32,
       "Invalid BSDIFF header");
  Blob ctrl = bunzip((Blob){patch.p + 32, cs}, 64 * 1024 * 1024),
       diff = bunzip((Blob){patch.p + 32 + cs, ds}, ns + 1),
       extra = bunzip((Blob){patch.p + 32 + cs + ds, patch.n - 32 - cs - ds},
                      ns + 1),
       out = {alloc(ns), ns};
  need(!(ctrl.n % 24), "Invalid BSDIFF controls");
  int64_t op = 0, np = 0;
  size_t dp = 0, ep = 0;
  for (size_t i = 0; i < ctrl.n; i += 24) {
    int64_t x = offtin(ctrl.p + i), y = offtin(ctrl.p + i + 8),
            z = offtin(ctrl.p + i + 16);
    need(x >= 0 && y >= 0 && x <= ns - np && y <= ns - np - x &&
             (uint64_t)x <= diff.n - dp && (uint64_t)y <= extra.n - ep,
         "Invalid BSDIFF extent");
    need(op >= INT64_MIN + x && op <= INT64_MAX - x, "BSDIFF seek overflow");
    for (int64_t j = 0; j < x; j++)
      out.p[np + j] =
          diff.p[dp + j] +
          (op + j >= 0 && (uint64_t)(op + j) < old.n ? old.p[op + j] : 0);
    np += x;
    op += x;
    need((z >= 0 && op <= INT64_MAX - z) || (z < 0 && op >= INT64_MIN - z),
         "BSDIFF seek overflow");
    op += z;
    dp += x;
    memcpy(out.p + np, extra.p + ep, y);
    np += y;
    ep += y;
  }
  need(np == ns && dp == diff.n && ep == extra.n, "Incomplete BSDIFF output");
  write_file(c, out);
}
static size_t find(Blob b, Blob p) {
  need(p.n > 0 && p.n <= b.n, "Feature not found");
  size_t found = SIZE_MAX;
  for (size_t i = 0; i <= b.n - p.n; i++)
    if (b.p[i] == p.p[0] && !memcmp(b.p + i, p.p, p.n)) {
      need(found == SIZE_MAX, "Ambiguous binary feature");
      found = i;
    }
  need(found != SIZE_MAX, "Binary feature not found");
  return found;
}
static size_t image_data(Blob b, size_t *used) {
  need(b.n >= 20 && le32(b.p) == 0x496d6733 && le32(b.p + 4) == b.n,
       "Invalid IMG3 header");
  size_t data = 0;
  for (size_t p = 20; p < b.n;) {
    need(b.n - p >= 12, "Truncated IMG3 tag");
    size_t full = le32(b.p + p + 4), n = le32(b.p + p + 8);
    need(full >= 12 && full <= b.n - p && n <= full - 12,
         "Invalid IMG3 extent");
    if (le32(b.p + p) == 0x44415441) {
      need(!data, "Multiple IMG3 DATA tags");
      data = p;
      *used = n;
    }
    p += full;
  }
  need(data > 0, "Missing IMG3 DATA");
  return data;
}
static Blob imgdata(Blob b, const char *iv, const char *key) {
  size_t n;
  size_t p = image_data(b, &n);
  size_t padded = le32(b.p + p + 4) - 12;
  Blob out = {alloc(padded), n};
  if (iv) {
    Blob v = unhex(iv), k = unhex(key);
    need(v.n == 16 && (k.n == 16 || k.n == 24 || k.n == 32) && !(padded % 16),
         "Invalid AES material/extent");
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    need(ctx != NULL, "AES context failed");
    need(EVP_DecryptInit_ex(ctx,
                            k.n == 16   ? EVP_aes_128_cbc()
                            : k.n == 24 ? EVP_aes_192_cbc()
                                        : EVP_aes_256_cbc(),
                            NULL, k.p, v.p) == 1,
         "AES init failed");
    EVP_CIPHER_CTX_set_padding(ctx, 0);
    int count = 0, tail = 0;
    need(EVP_DecryptUpdate(ctx, out.p, &count, b.p + p + 12, padded) == 1 &&
             EVP_DecryptFinal_ex(ctx, out.p + count, &tail) == 1 &&
             (size_t)(count + tail) == padded,
         "AES decryption failed");
    EVP_CIPHER_CTX_free(ctx);
    free(v.p);
    free(k.p);
  } else
    memcpy(out.p, b.p + p + 12, n);
  return out;
}
static Blob wrap(Blob templ, Blob payload, int plaintext) {
  size_t unused;
  image_data(templ, &unused);
  Blob out = {alloc(templ.n + payload.n + 32), 20};
  memcpy(out.p, templ.p, 20);
  uint32_t signature_offset = 0;
  for (size_t p = 20; p < templ.n;) {
    size_t full = le32(templ.p + p + 4);
    uint32_t tag = le32(templ.p + p);
    if (plaintext && tag == 0x4b424147) {
      p += full;
      continue;
    }
    if (tag == 0x44415441) {
      size_t padded = (payload.n + 15) & ~(size_t)15;
      putle(out.p + out.n, tag);
      putle(out.p + out.n + 4, 12 + padded);
      putle(out.p + out.n + 8, payload.n);
      memcpy(out.p + out.n + 12, payload.p, payload.n);
      out.n += 12 + padded;
    } else {
      if (tag == 0x53485348)
        signature_offset = (uint32_t)(out.n - 20);
      memcpy(out.p + out.n, templ.p + p, full);
      out.n += full;
    }
    p += full;
  }
  putle(out.p + 4, out.n);
  putle(out.p + 8, out.n - 20);
  putle(out.p + 12, signature_offset);
  image_data(out, &unused);
  return out;
}
static Blob lzss_unpack(Blob b) {
  need(b.n >= 384 && !memcmp(b.p, "complzss", 8), "Invalid LZSS header");
  size_t size = be32(b.p + 12), packed = be32(b.p + 16);
  need(packed <= b.n - 384 && size <= LIMIT, "Invalid LZSS length");
  Blob out = {alloc(size), size};
  unsigned char ring[4096];
  memset(ring, 0, sizeof(ring));
  memset(ring, ' ', 4096 - 18);
  size_t rp = 4096 - 18, at = 384, end = 384 + packed, pos = 0;
  unsigned flags = 0;
  while (pos < size) {
    flags >>= 1;
    if (!(flags & 256)) {
      need(at < end, "Truncated LZSS flags");
      flags = b.p[at++] | 0xff00;
    }
    if (flags & 1) {
      need(at < end, "Truncated LZSS literal");
      unsigned char c = b.p[at++];
      out.p[pos++] = c;
      ring[rp] = c;
      rp = (rp + 1) & 4095;
    } else {
      need(end - at >= 2, "Truncated LZSS match");
      unsigned q = b.p[at++], k = b.p[at++];
      q |= (k & 0xf0) << 4;
      k = (k & 15) + 3;
      need(k <= size - pos, "LZSS output overflow");
      for (unsigned i = 0; i < k; i++) {
        unsigned char c = ring[(q + i) & 4095];
        out.p[pos++] = c;
        ring[rp] = c;
        rp = (rp + 1) & 4095;
      }
    }
  }
  need(at == end && adler32(1, out.p, out.n) == be32(b.p + 8),
       "LZSS length/checksum mismatch");
  return out;
}
static unsigned hash3(unsigned char *p) {
  return ((unsigned)p[0] * 251 * 251 + (unsigned)p[1] * 251 + p[2]) & 65535;
}
static Blob lzss_pack(Blob data, Blob templ) {
  need(templ.n >= 384 && !memcmp(templ.p, "complzss", 8),
       "Invalid LZSS template");
  Blob out = {alloc(data.n + data.n / 8 + 400), 384};
  memcpy(out.p, templ.p, 384);
  int64_t *prev = alloc((data.n ? data.n : 1) * sizeof(*prev));
  int64_t heads[65536];
  for (int i = 0; i < 65536; i++)
    heads[i] = -1;
  size_t p = 0;
  while (p < data.n) {
    size_t flag = out.n++;
    unsigned flags = 0;
    for (int bit = 0; bit < 8 && p < data.n; bit++) {
      size_t best = 0, dist = 0, limit = data.n - p < 18 ? data.n - p : 18;
      if (limit >= 3) {
        unsigned h = hash3(data.p + p);
        int seen = 0;
        for (int64_t q = heads[h]; q >= 0 && p - (size_t)q <= 4096;
             q = prev[q]) {
          if (memcmp(data.p + q, data.p + p, 3))
            continue;
          if (++seen > 24)
            break;
          size_t k = 3;
          while (k < limit && data.p[q + k] == data.p[p + k])
            k++;
          if (k > best) {
            best = k;
            dist = p - q;
          }
          if (k == limit)
            break;
        }
      }
      size_t take = best >= 3 ? best : 1;
      if (take == 1) {
        flags |= 1u << bit;
        out.p[out.n++] = data.p[p];
      } else {
        unsigned ring = (4096 - 18 + p - dist) & 4095;
        out.p[out.n++] = ring & 255;
        out.p[out.n++] = ((ring >> 4) & 0xf0) | (take - 3);
      }
      for (size_t i = p; i < p + take; i++) {
        prev[i] = -1;
        if (i + 3 <= data.n) {
          unsigned h = hash3(data.p + i);
          prev[i] = heads[h];
          heads[h] = i;
        }
      }
      p += take;
    }
    out.p[flag] = flags;
  }
  putbe(out.p + 8, adler32(1, data.p, data.n));
  putbe(out.p + 12, data.n);
  putbe(out.p + 16, out.n - 384);
  Blob check = lzss_unpack(out);
  need(check.n == data.n && !memcmp(check.p, data.p, data.n),
       "LZSS round trip failed");
  free(check.p);
  free(prev);
  return out;
}
static void signature(Blob b, int write) {
  size_t sig = 0;
  if (b.n >= 48 && !memcmp(b.p, "dyld_v1", 7)) {
    sig = (uint64_t)le32(b.p + 40) | ((uint64_t)le32(b.p + 44) << 32);
  } else {
    need(b.n >= 28 && le32(b.p) == 0xfeedface, "Expected ARM Mach-O");
    size_t n = le32(b.p + 16), bytes = le32(b.p + 20), p = 28;
    need(n <= 4096 && bytes <= b.n - 28, "Invalid Mach-O commands");
    for (size_t i = 0; i < n; i++) {
      need(p + 8 <= 28 + bytes, "Truncated Mach-O command");
      size_t cmd = le32(b.p + p), length = le32(b.p + p + 4);
      need(length >= 8 && length <= 28 + bytes - p, "Invalid Mach-O command");
      if (cmd == 0x1d) {
        need(length >= 16, "Short signature command");
        sig = le32(b.p + p + 8);
      }
      p += length;
    }
    need(p == 28 + bytes, "Mach-O command size mismatch");
  }
  if (!sig) {
    puts("0");
    return;
  }
  need(sig <= b.n && b.n - sig >= 12, "Signature outside image");
  size_t total = be32(b.p + sig + 4), count = be32(b.p + sig + 8);
  need(be32(b.p + sig) == 0xfade0cc0 && count <= 64 && total <= b.n - sig &&
           12 + 8 * count <= total,
       "Invalid signature superblob");
  for (size_t i = 0; i < count; i++) {
    size_t ix = sig + 12 + i * 8;
    if (be32(b.p + ix))
      continue;
    size_t cd = sig + be32(b.p + ix + 4);
    need(cd <= b.n && b.n - cd >= 40, "Invalid CodeDirectory");
    size_t n = be32(b.p + cd + 4), hoff = be32(b.p + cd + 16),
           slots = be32(b.p + cd + 28), limit = be32(b.p + cd + 32);
    need(be32(b.p + cd) == 0xfade0c02 && b.p[cd + 36] == 20 &&
             b.p[cd + 37] == 1 && b.p[cd + 39] == 12 && limit == sig &&
             slots == (limit + 4095) / 4096 && n <= b.n - cd && hoff <= n &&
             slots <= (n - hoff) / 20,
         "Unsupported CodeDirectory");
    for (size_t j = 0; j < slots; j++) {
      unsigned char digest[20];
      size_t sz = limit - j * 4096 < 4096 ? limit - j * 4096 : 4096;
      SHA1(b.p + j * 4096, sz, digest);
      if (write)
        memcpy(b.p + cd + hoff + j * 20, digest, 20);
      else
        need(!memcmp(b.p + cd + hoff + j * 20, digest, 20),
             "Invalid code page signature");
    }
    printf("%zu\n", slots);
    return;
  }
  die("CodeDirectory missing");
}
static plist_t tree_node(Blob b, size_t *at, unsigned depth) {
  need(depth < 64 && *at <= b.n && b.n - *at >= 8, "Invalid DeviceTree node");
  size_t count = le32(b.p + *at), children = le32(b.p + *at + 4);
  *at += 8;
  need(count <= 8192 && children <= 8192, "DeviceTree counts exceed limit");
  plist_t node = plist_new_dict(), props = plist_new_array(),
          kids = plist_new_array(), names = plist_new_dict();
  for (size_t i = 0; i < count; i++) {
    need(*at <= b.n && b.n - *at >= 36, "Truncated DeviceTree property");
    unsigned char *p = b.p + *at;
    size_t n = le32(p + 32) & 0x7fffffff, flags = le32(p + 32) & 0x80000000;
    char name[33];
    memcpy(name, p, 32);
    name[32] = 0;
    need(!plist_dict_get_item(names, name), "Duplicate DeviceTree property");
    plist_dict_set_item(names, name, plist_new_bool(1));
    *at += 36;
    need(n <= b.n - *at && ((n + 3) & ~(size_t)3) <= b.n - *at,
         "Invalid DeviceTree extent");
    plist_t prop = plist_new_dict();
    plist_dict_set_item(prop, "name", plist_new_string(name));
    char *value = hex((Blob){b.p + *at, n});
    plist_dict_set_item(prop, "value", plist_new_string(value));
    free(value);
    plist_dict_set_item(prop, "flags", plist_new_uint(flags));
    plist_array_append_item(props, prop);
    *at += (n + 3) & ~(size_t)3;
  }
  for (size_t i = 0; i < children; i++)
    plist_array_append_item(kids, tree_node(b, at, depth + 1));
  plist_dict_set_item(node, "properties", props);
  plist_dict_set_item(node, "children", kids);
  plist_free(names);
  return node;
}
static Blob macho_section(Blob b, const char *segment, const char *section) {
  need(b.n >= 28 && le32(b.p) == 0xfeedface, "Expected Mach-O");
  size_t count = le32(b.p + 16), bytes = le32(b.p + 20), p = 28;
  Blob result = {0};
  need(count <= 4096 && bytes <= b.n - 28, "Invalid Mach-O commands");
  for (size_t i = 0; i < count; i++) {
    need(p + 8 <= 28 + bytes, "Truncated command");
    size_t cmd = le32(b.p + p), n = le32(b.p + p + 4);
    need(n >= 8 && n <= 28 + bytes - p, "Invalid command extent");
    if (cmd == 1) {
      need(n >= 56, "Short segment");
      size_t ns = le32(b.p + p + 48);
      need(ns <= (n - 56) / 68, "Truncated sections");
      for (size_t j = 0; j < ns; j++) {
        unsigned char *s = b.p + p + 56 + j * 68;
        if (!strncmp((char *)s, section, 16) &&
            !strncmp((char *)s + 16, segment, 16)) {
          size_t len = le32(s + 36), offset = le32(s + 40);
          need(offset <= b.n && len <= b.n - offset, "Section outside Mach-O");
          need(!result.p, "Duplicate Mach-O section");
          result = (Blob){b.p + offset, len};
        }
      }
    }
    p += n;
  }
  need(p == 28 + bytes, "Mach-O command size mismatch");
  need(result.p != NULL, "Mach-O section missing");
  return result;
}
static void hfs_copy(const char *source, const char *dest) {
  FILE *f = fopen(source, "rb");
  if (!f)
    die("Cannot open HFS");
  need(!fseeko(f, 0, SEEK_END), "HFS seek failed");
  uint64_t size = ftello(f), offset = 0, length = size;
  unsigned char header[4096] = {0};
  rewind(f);
  need(fread(header, 1, size < 4096 ? size : 4096, f) >= 2048,
       "Truncated HFS source");
  const char *kind = "raw-hfs";
  if (memcmp(header + 1024, "H+", 2) && memcmp(header + 1024, "HX", 2)) {
    need(!memcmp(header, "ER", 2), "Expected HFS or Apple partition map");
    unsigned block = header[2] * 256 + header[3];
    need(block == 512 || block == 1024 || block == 2048 || block == 4096,
         "Invalid partition block");
    fseeko(f, block, SEEK_SET);
    need(fread(header, 1, 512, f) == 512 && !memcmp(header, "PM", 2),
         "Missing partition map");
    unsigned count = be32(header + 4), found = 0;
    need(count >= 1 && count <= 128 && (uint64_t)(count + 1) * block <= size,
         "Invalid partition count");
    for (unsigned i = 1; i <= count; i++) {
      fseeko(f, (uint64_t)i * block, SEEK_SET);
      need(fread(header, 1, 512, f) == 512 && !memcmp(header, "PM", 2),
           "Invalid partition entry");
      if (!strncmp((char *)header + 48, "Apple_HFS", 32) ||
          !strncmp((char *)header + 48, "Apple_HFSX", 32)) {
        offset = (uint64_t)be32(header + 8) * block;
        length = (uint64_t)be32(header + 12) * block;
        need(offset >= (uint64_t)(count + 1) * block && length >= 2048 &&
                 offset <= size && length <= size - offset,
             "Partition outside file");
        found++;
      }
    }
    need(found == 1, "Expected one HFS partition");
    kind = "apple-partition-map";
  }
  fseeko(f, offset + 1024, SEEK_SET);
  need(fread(header, 1, 2, f) == 2 &&
           (!memcmp(header, "H+", 2) || !memcmp(header, "HX", 2)),
       "HFS signature absent");
  fseeko(f, offset, SEEK_SET);
  FILE *out = fopen(dest, "wb");
  need(out != NULL, "Cannot write HFS");
  unsigned char *buffer = alloc(1024 * 1024);
  uint64_t remain = length;
  while (remain) {
    size_t n = remain < 1024 * 1024 ? remain : 1024 * 1024;
    if (fread(buffer, 1, n, f) != n)
      die("HFS read failed: %s: %s", source,
          ferror(f) ? strerror(errno) : "Unexpected end of file");
    if (fwrite(buffer, 1, n, out) != n)
      die("HFS write failed: %s: %s", dest, strerror(errno));
    remain -= n;
  }
  if (fclose(out))
    die("HFS write failed: %s: %s", dest, strerror(errno));
  fclose(f);
  printf("{\"container\":\"%s\",\"offset\":%llu,\"length\":%llu}\n", kind,
         (unsigned long long)offset, (unsigned long long)length);
  free(buffer);
}
static void dmg_check(const char *path) {
  FILE *f = fopen(path, "rb");
  need(f != NULL, "Cannot open DMG");
  fseeko(f, 0, SEEK_END);
  uint64_t size = ftello(f);
  need(size >= 512, "Short DMG");
  fseeko(f, -512, SEEK_END);
  unsigned char footer[512];
  need(fread(footer, 1, 512, f) == 512 && !memcmp(footer, "koly", 4),
       "DMG footer missing");
  uint64_t off = be64(footer + 216), len = be64(footer + 224);
  need(len > 0 && len <= 16 * 1024 * 1024 && off <= size - 512 &&
           len <= size - 512 - off,
       "Invalid DMG resource");
  Blob xml = {alloc(len), len};
  fseeko(f, off, SEEK_SET);
  need(fread(xml.p, 1, len, f) == len, "Truncated DMG XML");
  fclose(f);
  plist_t p = parse_plist(xml),
          rows = plist_dict_get_item(plist_dict_get_item(p, "resource-fork"),
                                     "blkx");
  need(rows && plist_get_node_type(rows) == PLIST_ARRAY,
       "DMG block table missing");
  unsigned found = 0, runs = 0;
  for (uint32_t i = 0; i < plist_array_get_size(rows); i++) {
    plist_t row = plist_array_get_item(rows, i);
    char *name = pstr(plist_dict_get_item(row, "Name"));
    if (!strstr(name, "Apple_HFS")) {
      free(name);
      continue;
    }
    free(name);
    uint64_t n = 0;
    const char *d = plist_get_data_ptr(plist_dict_get_item(row, "Data"), &n);
    need(d && n >= 204 && !memcmp(d, "mish", 4), "Invalid HFS block table");
    unsigned count = be32((unsigned char *)d + 200);
    need(count > 0 && count <= 100000 && n == 204 + (uint64_t)count * 40,
         "Invalid HFS block runs");
    for (unsigned j = 0; j < count; j++)
      need(be32((unsigned char *)d + 204 + 40 * j) != 2,
           "HFS DMG has skip-write runs; use explicit-zero dmg");
    runs = count;
    found++;
  }
  need(found == 1, "Expected one HFS DMG volume");
  printf("{\"hfs_runs\":%u,\"hfs_skip_write_runs\":0,\"zero_regions_written\":"
         "true}\n",
         runs);
  plist_free(p);
  free(xml.p);
}
int main(int argc, char **argv) {
  need(argc >= 2, "Expected an operation; see src/native/README.md");
  const char *cmd = argv[1];
  if (!strcmp(cmd, "apply")) {
    need(argc == 5, "apply SOURCE PATCH OUTPUT");
    bspatch(argv[2], argv[3], argv[4]);
  } else if (!strcmp(cmd, "locate")) {
    need(argc == 4, "locate FILE HEX");
    Blob b = read_file(argv[2]), p = unhex(argv[3]);
    printf("%zu\n", find(b, p));
  } else if (!strcmp(cmd, "edit")) {
    need(argc == 6, "edit INPUT OUTPUT OFFSET HEX");
    Blob b = read_file(argv[2]), p = unhex(argv[5]);
    char *end;
    unsigned long long at = strtoull(argv[4], &end, 0);
    need(*argv[4] && !*end && at <= b.n && p.n <= b.n - at,
         "Binary edit outside file");
    memcpy(b.p + at, p.p, p.n);
    write_file(argv[3], b);
  } else if (!strcmp(cmd, "hex-write")) {
    need(argc == 4, "hex-write HEX OUTPUT");
    write_file(argv[3], unhex(argv[2]));
  } else if (!strcmp(cmd, "hex-range")) {
    need(argc == 5, "hex-range FILE OFFSET LENGTH");
    Blob b = read_file(argv[2]);
    size_t at = strtoull(argv[3], NULL, 0), n = strtoull(argv[4], NULL, 0);
    need(at <= b.n && n <= b.n - at, "Range outside file");
    puts(hex((Blob){b.p + at, n}));
  } else if (!strcmp(cmd, "img3-data")) {
    need(argc == 4 || argc == 6, "img3-data INPUT OUTPUT [IV KEY]");
    write_file(argv[3], imgdata(read_file(argv[2]), argc == 6 ? argv[4] : NULL,
                                argc == 6 ? argv[5] : NULL));
  } else if (!strcmp(cmd, "img3-wrap")) {
    need(argc == 5 || argc == 6,
         "img3-wrap TEMPLATE PAYLOAD OUTPUT [plaintext]");
    write_file(argv[4],
               wrap(read_file(argv[2]), read_file(argv[3]), argc == 6));
  } else if (!strcmp(cmd, "lzss-unpack")) {
    need(argc == 4, "lzss-unpack INPUT OUTPUT");
    write_file(argv[3], lzss_unpack(read_file(argv[2])));
  } else if (!strcmp(cmd, "lzss-pack")) {
    need(argc == 5, "lzss-pack INPUT TEMPLATE OUTPUT");
    write_file(argv[4], lzss_pack(read_file(argv[2]), read_file(argv[3])));
  } else if (!strcmp(cmd, "signature")) {
    need(argc == 3 || argc == 4, "signature INPUT [OUTPUT]");
    Blob b = read_file(argv[2]);
    signature(b, argc == 4);
    if (argc == 4)
      write_file(argv[3], b);
  } else if (!strcmp(cmd, "tree-json") || !strcmp(cmd, "tree-trim")) {
    need(argc == 3 || argc == 4, "tree-json FILE / tree-trim INPUT OUTPUT");
    Blob b = read_file(argv[2]);
    if (b.n >= 4 && le32(b.p) == 0x496d6733)
      b = imgdata(b, NULL, NULL);
    size_t at = 0;
    plist_t t = tree_node(b, &at, 0);
    for (size_t i = at; i < b.n; i++)
      need(!b.p[i], "Nonzero trailing DeviceTree data");
    if (!strcmp(cmd, "tree-json"))
      print_json(t);
    else {
      need(argc == 4, "tree-trim INPUT OUTPUT");
      write_file(argv[3], (Blob){b.p, at});
    }
    plist_free(t);
  } else if (!strcmp(cmd, "prelink")) {
    need(argc == 3, "prelink KERNEL");
    Blob b = read_file(argv[2]);
    if (b.n >= 4 && le32(b.p) == 0x496d6733)
      b = imgdata(b, NULL, NULL);
    if (b.n >= 8 && !memcmp(b.p, "complzss", 8))
      b = lzss_unpack(b);
    Blob xml = macho_section(b, "__PRELINK_INFO", "__info");
    while (xml.n && xml.p[xml.n - 1] == 0)
      xml.n--;
    print_json(parse_prelink(xml));
  } else if (!strcmp(cmd, "macho-section")) {
    need(argc == 6, "macho-section INPUT SEGMENT SECTION OUTPUT");
    write_file(argv[5], macho_section(read_file(argv[2]), argv[3], argv[4]));
  } else if (!strcmp(cmd, "kext-extract")) {
    need(argc == 5, "kext-extract KERNEL BUNDLE OUTPUT");
    Blob b = read_file(argv[2]);
    plist_t meta = parse_prelink(macho_section(b, "__PRELINK_INFO", "__info")),
            rows = plist_dict_get_item(meta, "_PrelinkInfoDictionary");
    uint64_t start = 0, size = 0;
    unsigned found = 0;
    for (uint32_t i = 0; rows && i < plist_array_get_size(rows); i++) {
      plist_t row = plist_array_get_item(rows, i);
      char *id = pstr(plist_dict_get_item(row, "CFBundleIdentifier"));
      if (!strcmp(id, argv[3])) {
        start = puint(plist_dict_get_item(row, "_PrelinkExecutableSourceAddr"));
        size = puint(plist_dict_get_item(row, "_PrelinkExecutableSize"));
        found++;
      }
      free(id);
    }
    need(found == 1 && size > 0, "Kext executable metadata missing");
    size_t count = le32(b.p + 16), p = 28;
    for (size_t i = 0; i < count; i++) {
      size_t cmd = le32(b.p + p), n = le32(b.p + p + 4);
      if (cmd == 1) {
        need(n >= 56, "Invalid segment");
        uint64_t vm = le32(b.p + p + 24), off = le32(b.p + p + 32),
                 length = le32(b.p + p + 36);
        if (start >= vm && start - vm <= length &&
            size <= length - (start - vm)) {
          need(off + start - vm <= b.n && size <= b.n - (off + start - vm),
               "Kext mapping outside file");
          write_file(argv[4], (Blob){b.p + off + start - vm, size});
          found = 0;
          break;
        }
      }
      p += n;
    }
    need(!found, "Kext outside kernel mappings");
    plist_free(meta);
  } else if (!strcmp(cmd, "hfs-copy")) {
    need(argc == 4, "hfs-copy INPUT OUTPUT");
    hfs_copy(argv[2], argv[3]);
  } else if (!strcmp(cmd, "dmg-check")) {
    need(argc == 3, "dmg-check FILE");
    dmg_check(argv[2]);
  } else if (!strcmp(cmd, "ramdisk-check")) {
    need(argc == 3, "ramdisk-check IMG3");
    Blob b = read_file(argv[2]);
    size_t used, at = image_data(b, &used);
    need(le32(b.p + 16) == 0x7264736b, "Expected rdsk IMG3");
    unsigned sigs = 0;
    for (size_t p = 20; p < b.n; p += le32(b.p + p + 4)) {
      uint32_t tag = le32(b.p + p);
      need(tag != 0x4b424147, "Plaintext ramdisk has KBAG encryption tag");
      if (tag == 0x53485348) {
        sigs++;
        need(p == 20 + le32(b.p + 12), "IMG3 signature offset differs");
      }
    }
    need((sigs == 0 && !le32(b.p + 12)) || sigs == 1,
         "Invalid IMG3 signature layout");
    unsigned char *h = b.p + at + 12;
    need(used >= 2048 && (!memcmp(h + 1024, "H+\000\004", 4) ||
                          !memcmp(h + 1024, "HX\000\005", 4)),
         "Ramdisk must contain plaintext HFS");
    uint64_t block = be32(h + 1064), blocks = be32(h + 1068);
    need(block >= 512 && !(block & (block - 1)) && blocks > 0 &&
             block * blocks <= used / 4096 * 4096,
         "Ramdisk exceeds memory-disk backing");
    puts("{\"plaintext_hfs\":true,\"encryption_tags\":false}");
  } else if (!strcmp(cmd, "version")) {
    puts("project5c-native 1");
  } else if (plist_main(argc, argv) || zip_main(argc, argv) ||
             mux_main(argc, argv) || archive_main(argc, argv) ||
             process_main(argc, argv) || macho_main(argc, argv) || media_main(argc, argv) || kernel_main(argc, argv)) {
  } else
    die("Unknown operation: %s", cmd);
  return 0;
}
