/* iPwnder's A6 IMG3 handoff, using the bundled libirecovery at runtime.
 * Ordinary Linux boot and format operations do not load this library.
 */
#include "p5.h"
#include <dlfcn.h>
#include <strings.h>
#include <unistd.h>

enum { RECOVERY_NO_DEVICE = -1, RECOVERY_TIMEOUT = -11 };

/* Stable libirecovery device-info ABI prefix through serial_string. Keeping
 * this prefix here avoids requiring development headers or a link-time USB
 * dependency for the format helper. The bundled dylib is pinned in tools.tsv.
 */
typedef struct {
  unsigned int cpid, cprv, cpfm, scep, bdid;
  uint64_t ecid;
  unsigned int ibfl;
  char *srnm, *imei, *srtg, *serial_string;
} RecoveryInfo;
typedef struct {
  void *library, *client;
  int (*open)(void **client, uint64_t ecid);
  int (*close)(void *client);
  int (*reset)(void *client);
  int (*mode)(void *client, int *mode);
  const RecoveryInfo *(*info)(void *client);
  int (*control)(void *client, uint8_t type, uint8_t request, uint16_t value,
                 uint16_t index, unsigned char *data, uint16_t length,
                 unsigned int timeout);
} Recovery;

static void *symbol(void *library, const char *name) {
  void *address = dlsym(library, name);
  if (!address)
    die("Missing libirecovery symbol %s: %s", name, dlerror());
  return address;
}
static void release(Recovery *r) {
  if (r->client)
    r->close(r->client);
  dlclose(r->library);
}
static void checked(Recovery *r, int ok, const char *message) {
  if (!ok) {
    release(r);
    die("%s", message);
  }
}
static void transfer(Recovery *r, uint8_t type, uint8_t request,
                     unsigned char *data, uint16_t length,
                     unsigned int timeout, const char *step) {
  int result = r->control(r->client, type, request, 0, 0, data, length, timeout);
  if (result != length) {
    release(r);
    if (result < 0)
      die("iPwnder %s failed: libirecovery error %d%s (expected %u bytes)",
          step, result, result == RECOVERY_TIMEOUT ? " / timeout" : "", length);
    die("iPwnder %s returned %d bytes (expected %u)", step, result, length);
  }
}
static void open_device(Recovery *r, uint64_t ecid, unsigned int board,
                         unsigned int attempts) {
  int result = RECOVERY_NO_DEVICE;
  for (unsigned int attempt = 0; attempt < attempts; attempt++) {
    result = r->open(&r->client, ecid);
    if (!result && r->client)
      break;
    if (r->client) {
      r->close(r->client);
      r->client = NULL;
    }
    if (attempt + 1 < attempts)
      sleep(1);
  }
  if (result || !r->client) {
    release(r);
    die("Cannot open iPwnder device for ECID 0x%llx (%d); re-enter physical DFU",
        (unsigned long long)ecid, result);
  }
  int mode = 0;
  const RecoveryInfo *info = r->info(r->client);
  checked(r, !r->mode(r->client, &mode) && mode == 0x1227 && info &&
                 info->ecid == ecid && info->cpid == 0x8950 &&
                 info->bdid == board && info->srtg &&
                 !strcmp(info->srtg, "iBoot-1145.3"),
          "iPwnder DFU device identity differs");
  const char *marker = info->serial_string ? strstr(info->serial_string, "PWND:[") : NULL;
  checked(r, marker && !strncasecmp(marker + 6, "ipwnder]", 8),
          "Expected iPwnder's A6 DFU request handler");
}
static void check_image(Blob image, unsigned int board) {
  need(image.n >= 20 && image.n <= 256 * 1024 &&
           le32(image.p) == 0x496d6733 && le32(image.p + 4) == image.n &&
           le32(image.p + 8) == image.n - 20 &&
           le32(image.p + 16) == 0x69627373,
       "Expected a packed iBSS IMG3");
  unsigned int seen = 0;
  for (size_t at = 20; at < image.n;) {
    need(image.n - at >= 12, "Truncated iBSS IMG3 tag");
    size_t total = le32(image.p + at + 4), size = le32(image.p + at + 8);
    need(total >= 12 && total <= image.n - at && size <= total - 12,
         "Invalid iBSS IMG3 extent");
    unsigned char *data = image.p + at + 12;
    unsigned int bit = 0;
    switch (le32(image.p + at)) {
    case 0x44415441:
      bit = 1;
      need(size > 512 && !(size % 16), "Invalid encrypted iBSS DATA");
      break;
    case 0x54595045:
      bit = 2;
      need(size == 4 && le32(data) == 0x69627373, "Wrong iBSS IMG3 TYPE");
      break;
    case 0x43484950:
      bit = 4;
      need(size == 4 && le32(data) == 0x8950, "Wrong iBSS IMG3 chip");
      break;
    case 0x424f5244:
      bit = 8;
      need(size == 4 && le32(data) == board, "Wrong iBSS IMG3 board");
      break;
    case 0x4b424147:
      /* iPwnder decrypts using the first KBAG, which must be production GID. */
      if (!(seen & 16)) {
        bit = 16;
        need(size == 56 && le32(data) == 1 && le32(data + 4) == 256,
             "iPwnder requires an encrypted iBSS with a production KBAG");
      }
      break;
    }
    need(!bit || !(seen & bit), "Duplicate iBSS IMG3 tag");
    seen |= bit;
    at += total;
  }
  need(seen == 31, "iBSS IMG3 is missing required identity/encryption tags");
}
int usb_main(int argc, char **argv) {
  if (strcmp(argv[1], "ipwnder-ibss"))
    return 0;
  need(argc == 6, "ipwnder-ibss LIBIRECOVERY ECID BOARD_ID IMG3");
  char *end;
  errno = 0;
  uint64_t ecid = strtoull(argv[3], &end, 0);
  need(*argv[3] && argv[3][0] != '-' && !*end && !errno && ecid,
       "Invalid iPwnder ECID");
  errno = 0;
  unsigned long board = strtoul(argv[4], &end, 0);
  need(*argv[4] && !*end && !errno && (board == 10 || board == 14),
       "Expected N48/N49 board ID");
  Blob image = read_file(argv[5]);
  check_image(image, board);
  need(argv[2][0] == '/', "libirecovery path must be absolute");
  Recovery r = {0};
  r.library = dlopen(argv[2], RTLD_NOW | RTLD_LOCAL);
  if (!r.library)
    die("Cannot load libirecovery %s: %s", argv[2], dlerror());
  r.open = (int (*)(void **, uint64_t))symbol(r.library, "irecv_open_with_ecid");
  r.close = (int (*)(void *))symbol(r.library, "irecv_close");
  r.reset = (int (*)(void *))symbol(r.library, "irecv_reset");
  r.mode = (int (*)(void *, int *))symbol(r.library, "irecv_get_mode");
  r.info = (const RecoveryInfo *(*)(void *))symbol(r.library, "irecv_get_device_info");
  r.control = (int (*)(void *, uint8_t, uint8_t, uint16_t, uint16_t,
                      unsigned char *, uint16_t, unsigned int))
      symbol(r.library, "irecv_usb_control_transfer");
  open_device(&r, ecid, board, 1);
  for (unsigned int attempt = 1; attempt <= 2; attempt++) {
    /* Match ipwnder_lite's exec_payload: reset/re-enumerate and reopen before
     * the 16-byte primer. A PWND serial alone does not establish USB readiness.
     * Never reset an unverified device or reuse a handle across the reset.
     */
    fprintf(stderr, "iPwnder: reset and reopen DFU for iBSS (attempt %u/2)\n", attempt);
    int result = r.reset(r.client);
    if (result) {
      release(&r);
      die("iPwnder DFU reset failed: libirecovery error %d", result);
    }
    r.close(r.client);
    r.client = NULL;
    sleep(1);
    open_device(&r, ecid, board, 5);

    unsigned char blank[16] = {0};
    transfer(&r, 0x21, 1, blank, 16, 5000, "DFU preparation");
    transfer(&r, 0x21, 1, NULL, 0, 100, "DFU preparation finish");
    transfer(&r, 0xa1, 3, blank, 6, 100, "first DFU status");
    transfer(&r, 0xa1, 3, blank, 6, 100, "second DFU status");
    size_t at = 0;
    while (at < image.n) {
      size_t count = image.n - at;
      if (count > 0x800)
        count = 0x800;
      result = r.control(r.client, 0x21, 1, 0, 0, image.p + at, count, 5000);
      if (result != (int)count) {
        /* A timed-out OUT request may have delivered a partial chunk. Reset
         * and replay the whole primer/image once; never resend just that chunk.
         */
        if (result == RECOVERY_TIMEOUT && attempt == 1) {
          fprintf(stderr, "iPwnder: iBSS upload timed out at offset 0x%zx/%zu "
                          "(%zu-byte chunk); restarting the full upload\n",
                  at, image.n, count);
          break;
        }
        release(&r);
        if (result < 0)
          die("iPwnder iBSS upload failed at offset 0x%zx/%zu: libirecovery "
              "error %d%s (expected %zu bytes); re-enter physical DFU and retry",
              at, image.n, result, result == RECOVERY_TIMEOUT ? " / timeout" : "", count);
        die("iPwnder iBSS upload was short at offset 0x%zx/%zu: %d of %zu bytes; "
            "re-enter physical DFU and retry", at, image.n, result, count);
      }
      at += count;
    }
    if (at < image.n)
      continue;
    result = r.control(r.client, 0xa1, 2, 0xffff, 0, NULL, 0, 5000);
    /* The handler jumps into iBSS without completing the control request. The
     * macOS backend can return NO_DEVICE or TIMEOUT at that boundary. Do not
     * replay the upload here: Bash verifies the DFU identity and unchanged nonce.
     */
    if (result != 0 && result != RECOVERY_NO_DEVICE && result != RECOVERY_TIMEOUT) {
      release(&r);
      die("iPwnder execute request failed: libirecovery error %d", result);
    }
    release(&r);
    printf("{\"ipwnder_execute_requested\":true,\"bytes\":%zu,\"control_result\":%d}\n",
           image.n, result);
    free(image.p);
    return 1;
  }
  die("iPwnder iBSS upload attempts exhausted");
  return 0;
}
