#include "p5.h"
#include <archive.h>
#include <archive_entry.h>

/* Canonical USTAR repacking preserves package uid/gid and setuid modes even
 * when the host user cannot chown an extracted tree. Policy comes from Bash. */
typedef struct {
  char *original, *name, *link;
  Blob data;
  unsigned mode;
  uint64_t uid, gid;
  int type;
} Entry;
static Entry *entries;
static size_t count;
static int beneath(const char *name, const char *prefix) {
  size_t n = strlen(prefix);
  return !strncmp(name, prefix, n) && (!name[n] || name[n] == '/');
}
static int safe(const char *name) {
  if (!*name || *name == '/')
    return 0;
  const char *p = name;
  while (*p) {
    const char *end = strchr(p, '/');
    size_t n = end ? (size_t)(end - p) : strlen(p);
    if (n == 2 && !strncmp(p, "..", 2))
      return 0;
    if (!end)
      break;
    p = end + 1;
  }
  return 1;
}
static int cmp_entry(const void *a, const void *b) {
  return strcmp(((const Entry *)a)->name, ((const Entry *)b)->name);
}
static void octal(unsigned char *field, size_t width, uint64_t value) {
  char buffer[32];
  snprintf(buffer, sizeof(buffer), "%0*llo", (int)width - 1,
           (unsigned long long)value);
  need(strlen(buffer) == width - 1, "USTAR numeric field overflow");
  memcpy(field, buffer, width - 1);
}
static void emit(FILE *out, const void *data, size_t size) {
  need(fwrite(data, 1, size, out) == size, "USTAR write failed");
}
static void header(FILE *out, Entry *entry) {
  unsigned char h[512] = {0};
  char path[300];
  need(strlen(entry->name) + 2 <= sizeof(path), "USTAR path too long");
  snprintf(path, sizeof(path), "%s%s", entry->name,
           entry->type == '5' ? "/" : "");
  const char *name = path;
  if (strlen(path) > 100) {
    const char *split = NULL;
    for (const char *p = path; *p; p++)
      if (*p == '/' && p - path <= 155 && strlen(p + 1) <= 100 && p[1])
        split = p;
    need(split != NULL, "USTAR path cannot be split");
    memcpy(h + 345, path, split - path);
    name = split + 1;
  }
  memcpy(h, name, strlen(name));
  octal(h + 100, 8, entry->mode);
  octal(h + 108, 8, entry->uid);
  octal(h + 116, 8, entry->gid);
  octal(h + 124, 12, entry->data.n);
  octal(h + 136, 12, 0);
  memset(h + 148, ' ', 8);
  h[156] = entry->type;
  if (entry->link) {
    need(strlen(entry->link) <= 100, "USTAR symlink too long");
    memcpy(h + 157, entry->link, strlen(entry->link));
  }
  memcpy(h + 257, "ustar\00000", 8);
  unsigned sum = 0;
  for (unsigned i = 0; i < 512; i++)
    sum += h[i];
  snprintf((char *)h + 148, 8, "%06o", sum);
  h[155] = ' ';
  emit(out, h, 512);
  emit(out, entry->data.p, entry->data.n);
  unsigned char zero[512] = {0};
  if (entry->data.n % 512)
    emit(out, zero, 512 - entry->data.n % 512);
}
int archive_main(int argc, char **argv) {
  if (strcmp(argv[1], "tar-repack"))
    return 0;
  need(argc == 4, "tar-repack POLICY_JSON OUTPUT");
  plist_t spec = load_plist(argv[2]);
  plist_t archives = plist_dict_get_item(spec, "archives");
  entries = alloc(100000 * sizeof(*entries));
  for (uint32_t i = 0; i < plist_array_get_size(archives); i++) {
    char *path = pstr(plist_array_get_item(archives, i));
    struct archive *a = archive_read_new();
    archive_read_support_filter_all(a);
    archive_read_support_format_tar(a);
    need(archive_read_open_filename(a, path, 10240) == ARCHIVE_OK,
         "Cannot read bootstrap archive");
    struct archive_entry *e;
    int status;
    size_t archive_start = count;
    while ((status = archive_read_next_header(a, &e)) == ARCHIVE_OK) {
      const char *name = archive_entry_pathname(e);
      while (!strncmp(name, "./", 2))
        name += 2;
      if (!*name || !strcmp(name, "."))
        continue;
      need(safe(name) && count < 100000, "Unsafe bootstrap archive entry");
      Entry row = {0};
      row.original = strdup(name);
      size_t n = strlen(row.original);
      while (n && row.original[n - 1] == '/')
        row.original[--n] = 0;
      row.name = strdup(row.original);
      row.uid = archive_entry_uid(e);
      row.gid = archive_entry_gid(e);
      row.mode = archive_entry_perm(e);
      const char *hard = archive_entry_hardlink(e),
                 *link = archive_entry_symlink(e);
      if (hard) {
        while (!strncmp(hard, "./", 2))
          hard += 2;
        need(safe(hard), "Unsafe bootstrap hardlink");
        size_t found = count;
        for (size_t j = archive_start; j < count; j++)
          if (!strcmp(entries[j].original, hard))
            found = j;
        need(found < count && entries[found].type == '0',
             "Unresolved bootstrap hardlink");
        row.type = '0';
        row.data = entries[found].data;
      } else if (archive_entry_filetype(e) == AE_IFREG) {
        int64_t size = archive_entry_size(e);
        need(size >= 0 && size <= 64 * 1024 * 1024,
             "Oversized bootstrap member");
        row.type = '0';
        row.data = (Blob){alloc(size), size};
        size_t at = 0;
        while (at < row.data.n) {
          la_ssize_t got =
              archive_read_data(a, row.data.p + at, row.data.n - at);
          need(got > 0, "Truncated bootstrap member");
          at += got;
        }
      } else if (archive_entry_filetype(e) == AE_IFDIR)
        row.type = '5';
      else if (archive_entry_filetype(e) == AE_IFLNK && link) {
        row.type = '2';
        row.link = strdup(link);
        /* Resolve relative link traversal depth; absolute links are image
         * paths. */
        if (*link != '/') {
          unsigned depth = 0;
          for (const char *p = row.name; *p; p++)
            if (*p == '/')
              depth++;
          char *copy = strdup(link), *save = NULL;
          for (char *p = strtok_r(copy, "/", &save); p;
               p = strtok_r(NULL, "/", &save)) {
            if (!strcmp(p, "..")) {
              need(depth > 0, "Bootstrap symlink escapes image");
              depth--;
            } else if (strcmp(p, "."))
              depth++;
          }
          free(copy);
        }
      } else
        die("Unsupported bootstrap member type");
      entries[count++] = row;
    }
    need(status == ARCHIVE_EOF, "Invalid bootstrap archive");
    archive_read_free(a);
    free(path);
  }
  char *prefix = pstr(plist_dict_get_item(spec, "filter_prefix"));
  char *rename = pstr(plist_dict_get_item(spec, "rename_prefix"));
  plist_t keep = plist_dict_get_item(spec, "keep_prefixes"),
          exclude = plist_dict_get_item(spec, "exclude");
  size_t output_count = 0;
  for (size_t i = 0; i < count; i++) {
    Entry row = entries[i];
    int include = 1;
    if (beneath(row.name, prefix)) {
      include = 0;
      for (uint32_t j = 0; j < plist_array_get_size(keep); j++) {
        char *s = pstr(plist_array_get_item(keep, j));
        if (beneath(row.name, s))
          include = 1;
        free(s);
      }
      if (include) {
        char *s = alloc(strlen(rename) + strlen(row.name) + 1);
        sprintf(s, "%s%s", rename, row.name + strlen(prefix));
        row.name = s;
      }
    }
    for (uint32_t j = 0; j < plist_array_get_size(exclude); j++) {
      char *s = pstr(plist_array_get_item(exclude, j));
      if (!strcmp(row.name, s))
        include = 0;
      free(s);
    }
    if (!include)
      continue;
    size_t found = output_count;
    for (size_t j = 0; j < output_count; j++)
      if (!strcmp(entries[j].name, row.name))
        found = j;
    entries[found] = row;
    if (found == output_count)
      output_count++;
  }
  qsort(entries, output_count, sizeof(*entries), cmp_entry);
  FILE *out = fopen(argv[3], "wb");
  need(out != NULL, "Cannot write bootstrap tar");
  for (size_t i = 0; i < output_count; i++)
    header(out, &entries[i]);
  unsigned char zero[10240] = {0};
  emit(out, zero, 1024);
  off_t size = ftello(out);
  if (size % 10240)
    emit(out, zero, 10240 - size % 10240);
  need(!fclose(out), "Cannot finish bootstrap tar");
  printf("%zu\n", output_count);
  plist_free(spec);
  return 1;
}
