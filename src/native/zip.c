#include "p5.h"
#include <curl/curl.h>
#include <limits.h>
#include <time.h>
#include <zip.h>
#define MAX_MEMBER (64 * 1024 * 1024)
#define RANGE_CACHE (1024 * 1024)
static void safe_member(const char *name) {
  need(name[0] != '/' && !strstr(name, "../") && strcmp(name, "..") &&
           strlen(name) > 0,
       "Unsafe ZIP member path");
}
static void extract_member(zip_t *archive, const char *name, const char *out,
                           int progress) {
  safe_member(name);
  zip_int64_t index = zip_name_locate(archive, name, ZIP_FL_ENC_GUESS);
  need(index >= 0, "ZIP member missing");
  zip_stat_t st;
  need(zip_stat_index(archive, index, 0, &st) == 0 && st.size > 0 &&
           st.size <= MAX_MEMBER && st.comp_size <= MAX_MEMBER,
       "ZIP member exceeds component limit");
  zip_file_t *f = zip_fopen_index(archive, index, 0);
  need(f != NULL, "Cannot open ZIP member");
  Blob b = {alloc(st.size), st.size};
  size_t done = 0;
  time_t last = time(NULL);
  if (progress)
    fprintf(stderr, "Download %s: 0 / %.1f MiB\n", name,
            (double)b.n / RANGE_CACHE);
  while (done < b.n) {
    size_t chunk = b.n - done;
    if (chunk > RANGE_CACHE)
      chunk = RANGE_CACHE;
    zip_int64_t n = zip_fread(f, b.p + done, chunk);
    need(n > 0, "ZIP data/CRC error");
    done += n;
    time_t now = time(NULL);
    if (progress && (now - last >= 2 || done == b.n)) {
      fprintf(stderr, "Download %s: %.1f / %.1f MiB (%zu%%)\n", name,
              (double)done / RANGE_CACHE, (double)b.n / RANGE_CACHE,
              done * 100 / b.n);
      last = now;
    }
  }
  unsigned char extra;
  need(zip_fread(f, &extra, 1) == 0 && zip_fclose(f) == 0,
       "ZIP CRC/extent error");
  write_file(out, b);
  free(b.p);
}
typedef struct {
  char *url;
  uint64_t size, pos, start, end;
  unsigned char *data;
  size_t capacity, count;
  int valid_range;
  CURL *curl;
  zip_error_t error;
} Remote;
static size_t receive(char *data, size_t unit, size_t count, void *ctx) {
  Remote *r = ctx;
  size_t n = unit * count;
  if (n > r->capacity - r->count)
    return 0;
  memcpy(r->data + r->count, data, n);
  r->count += n;
  return n;
}
static size_t headers(char *data, size_t unit, size_t count, void *ctx) {
  Remote *r = ctx;
  size_t n = unit * count;
  if (n > 14 && !strncasecmp(data, "Content-Range:", 14)) {
    char line[256];
    if (n >= sizeof(line))
      return 0;
    memcpy(line, data, n);
    line[n] = 0;
    unsigned long long a, b, total;
    if (sscanf(line + 14, " bytes %llu-%llu/%llu", &a, &b, &total) == 3)
      r->valid_range = a == r->start && b == r->end && total == r->size;
  }
  return n;
}
static zip_int64_t remote_read(void *ctx, void *data, zip_uint64_t len,
                               zip_source_cmd_t cmd) {
  Remote *r = ctx;
  switch (cmd) {
  case ZIP_SOURCE_OPEN:
    r->pos = 0;
    return 0;
  case ZIP_SOURCE_CLOSE:
    return 0;
  case ZIP_SOURCE_STAT: {
    if (len < sizeof(zip_stat_t))
      return -1;
    zip_stat_t *st = data;
    zip_stat_init(st);
    st->size = r->size;
    st->valid = ZIP_STAT_SIZE;
    return sizeof(*st);
  }
  case ZIP_SOURCE_TELL:
    return r->pos;
  case ZIP_SOURCE_SEEK: {
    zip_source_args_seek_t *s =
        ZIP_SOURCE_GET_ARGS(zip_source_args_seek_t, data, len, &r->error);
    if (!s)
      return -1;
    int64_t base = s->whence == SEEK_SET   ? 0
                   : s->whence == SEEK_CUR ? (int64_t)r->pos
                   : s->whence == SEEK_END ? (int64_t)r->size
                                           : -1;
    if (base < 0 || s->offset < -base || s->offset > (int64_t)r->size - base)
      return -1;
    r->pos = base + s->offset;
    return 0;
  }
  case ZIP_SOURCE_SUPPORTS:
    return ZIP_SOURCE_SUPPORTS_SEEKABLE;
  case ZIP_SOURCE_ERROR:
    return zip_error_to_data(&r->error, data, len);
  case ZIP_SOURCE_FREE:
    zip_error_fini(&r->error);
    curl_easy_cleanup(r->curl);
    free(r->data);
    free(r->url);
    free(r);
    return 0;
  case ZIP_SOURCE_READ: {
    if (len > r->size - r->pos)
      len = r->size - r->pos;
    if (!len)
      return 0;
    if (len > MAX_MEMBER) {
      zip_error_set(&r->error, ZIP_ER_READ, EFBIG);
      return -1;
    }
    size_t done = 0;
    while (done < len) {
      if (!r->count || r->pos < r->start || r->pos >= r->start + r->count) {
        r->count = 0;
        r->valid_range = 0;
        r->start = r->pos;
        uint64_t amount = r->size - r->pos;
        if (amount > r->capacity)
          amount = r->capacity;
        r->end = r->start + amount - 1;
        char range[96];
        snprintf(range, sizeof(range), "%llu-%llu",
                 (unsigned long long)r->start, (unsigned long long)r->end);
        curl_easy_setopt(r->curl, CURLOPT_RANGE, range);
        CURLcode result = curl_easy_perform(r->curl);
        long status = 0;
        curl_easy_getinfo(r->curl, CURLINFO_RESPONSE_CODE, &status);
        if (result != CURLE_OK || status != 206 || !r->valid_range ||
            r->count != amount) {
          fprintf(stderr,
                  "Apple range %s failed: %s; HTTP %ld; received %zu/%llu "
                  "bytes; Content-Range %s\n",
                  range, curl_easy_strerror(result), status, r->count,
                  (unsigned long long)amount,
                  r->valid_range ? "valid" : "invalid");
          r->count = 0;
          zip_error_set(&r->error, ZIP_ER_READ, EIO);
          return -1;
        }
      }
      size_t available = r->count - (r->pos - r->start);
      size_t n = len - done < available ? len - done : available;
      memcpy((unsigned char *)data + done, r->data + (r->pos - r->start), n);
      done += n;
      r->pos += n;
    }
    return len;
  }
  default:
    return -1;
  }
}
static int apple_https(const char *url) {
  CURLU *u = curl_url();
  char *scheme = NULL, *host = NULL, *port = NULL, *user = NULL;
  int valid = 0;
  if (curl_url_set(u, CURLUPART_URL, url, 0) == CURLUE_OK &&
      curl_url_get(u, CURLUPART_SCHEME, &scheme, 0) == CURLUE_OK &&
      curl_url_get(u, CURLUPART_HOST, &host, 0) == CURLUE_OK) {
    size_t n = strlen(host);
    valid = !strcmp(scheme, "https") &&
            (!strcmp(host, "apple.com") ||
             (n > 10 && !strcmp(host + n - 10, ".apple.com")));
    if (curl_url_get(u, CURLUPART_PORT, &port, 0) == CURLUE_OK &&
        strcmp(port, "443"))
      valid = 0;
    if (curl_url_get(u, CURLUPART_USER, &user, 0) == CURLUE_OK)
      valid = 0;
  }
  curl_free(scheme);
  curl_free(host);
  curl_free(port);
  curl_free(user);
  curl_url_cleanup(u);
  return valid;
}
static zip_t *remote_open(const char *url, const char *size) {
  need(apple_https(url), "Firmware URL must use Apple HTTPS");
  Remote *r = alloc(sizeof(*r));
  r->url = strdup(url);
  char *end;
  r->size = strtoull(size, &end, 10);
  need(*size && !*end && r->size > 0 && r->size < 16ULL * 1024 * 1024 * 1024,
       "Invalid remote IPSW length");
  r->capacity = RANGE_CACHE;
  r->data = alloc(r->capacity);
  r->curl = curl_easy_init();
  need(r->curl != NULL, "Cannot initialize Apple download");
  curl_easy_setopt(r->curl, CURLOPT_URL, r->url);
  curl_easy_setopt(r->curl, CURLOPT_FOLLOWLOCATION, 0L);
  curl_easy_setopt(r->curl, CURLOPT_PROTOCOLS_STR, "https");
  curl_easy_setopt(r->curl, CURLOPT_CONNECTTIMEOUT, 15L);
  curl_easy_setopt(r->curl, CURLOPT_TIMEOUT, 45L);
  curl_easy_setopt(r->curl, CURLOPT_LOW_SPEED_LIMIT, 1024L);
  curl_easy_setopt(r->curl, CURLOPT_LOW_SPEED_TIME, 15L);
  curl_easy_setopt(r->curl, CURLOPT_USERAGENT, "Project5C6/2.0");
  curl_easy_setopt(r->curl, CURLOPT_ACCEPT_ENCODING, "identity");
  curl_easy_setopt(r->curl, CURLOPT_WRITEFUNCTION, receive);
  curl_easy_setopt(r->curl, CURLOPT_WRITEDATA, r);
  curl_easy_setopt(r->curl, CURLOPT_HEADERFUNCTION, headers);
  curl_easy_setopt(r->curl, CURLOPT_HEADERDATA, r);
  zip_error_init(&r->error);
  zip_error_t err;
  zip_error_init(&err);
  zip_source_t *src = zip_source_function_create(remote_read, r, &err);
  need(src != NULL, "Cannot open remote ZIP source");
  zip_t *z = zip_open_from_source(src, ZIP_RDONLY, &err);
  if (!z)
    die("Cannot open Apple IPSW ranges: %s", zip_error_strerror(&err));
  zip_error_fini(&err);
  return z;
}
int zip_main(int argc, char **argv) {
  const char *cmd = argv[1];
  if (!strcmp(cmd, "remote-member")) {
    need(argc == 6, "remote-member URL SIZE MEMBER OUTPUT");
    curl_global_init(CURL_GLOBAL_DEFAULT);
    zip_t *z = remote_open(argv[2], argv[3]);
    extract_member(z, argv[4], argv[5], 1);
    need(zip_close(z) == 0, "ZIP close failed");
    curl_global_cleanup();
    return 1;
  }
  if (!strcmp(cmd, "zip-extract") || !strcmp(cmd, "zip-list") ||
      !strcmp(cmd, "zip-check")) {
    need(argc >= 3, "ZIP operation requires archive");
    int err;
    zip_t *z = zip_open(argv[2], ZIP_RDONLY, &err);
    need(z != NULL, "Invalid ZIP archive");
    zip_int64_t n = zip_get_num_entries(z, 0);
    for (zip_int64_t i = 0; i < n; i++) {
      const char *name = zip_get_name(z, i, 0);
      need(name != NULL, "Invalid ZIP name");
      safe_member(name);
      need(zip_name_locate(z, name, 0) == i, "Duplicate ZIP member");
      if (!strcmp(cmd, "zip-list"))
        puts(name);
      if (!strcmp(cmd, "zip-check") && name[strlen(name) - 1] != '/') {
        zip_stat_t st;
        need(!zip_stat_index(z, i, 0, &st) && st.size <= MAX_MEMBER,
             "ZIP member exceeds component limit");
        zip_file_t *file = zip_fopen_index(z, i, 0);
        need(file != NULL, "Cannot open ZIP member");
        unsigned char buffer[65536];
        uint64_t size = 0;
        zip_int64_t got;
        while ((got = zip_fread(file, buffer, sizeof(buffer))) > 0)
          size += got;
        need(got == 0 && size == st.size && !zip_fclose(file),
             "ZIP data/CRC error");
      }
    }
    if (!strcmp(cmd, "zip-extract")) {
      need(argc == 5, "zip-extract ARCHIVE MEMBER OUTPUT");
      extract_member(z, argv[3], argv[4], 0);
    }
    need(zip_close(z) == 0, "ZIP close failed");
    return 1;
  }
  if (!strcmp(cmd, "tail-stitch")) {
    need(argc == 5, "tail-stitch INPUT SIGNATURE OUTPUT");
    Blob old = read_file(argv[2]), sig = read_file(argv[3]);
    need(sig.n > 0 && sig.n < old.n, "Invalid signature extent");
    memcpy(old.p + old.n - sig.n, sig.p, sig.n);
    write_file(argv[4], old);
    return 1;
  }
  return 0;
}
