/* Assemble prelinked kernels from individually maintained driver components. */
#include "p5.h"
#include <libxml/parser.h>
#include <libxml/tree.h>

static xmlNode *element(xmlNode *n) {
  while (n && n->type != XML_ELEMENT_NODE)
    n = n->next;
  return n;
}
static xmlNode *find_id(xmlNode *node, const xmlChar *id) {
  for (; node; node = node->next) {
    xmlChar *value = xmlGetProp(node, BAD_CAST "ID");
    int match = value && !xmlStrcmp(value, id);
    xmlFree(value);
    if (match)
      return node;
    xmlNode *found = find_id(node->children, id);
    if (found)
      return found;
  }
  return NULL;
}
static xmlNode *resolve(xmlNode *node, xmlNode *root) {
  for (unsigned i = 0; node && i < 128; i++) {
    xmlChar *id = xmlGetProp(node, BAD_CAST "IDREF");
    if (!id)
      return node;
    node = find_id(root, id);
    xmlFree(id);
  }
  die("Invalid/cyclic prelink reference");
  return NULL;
}
static xmlNode *dict_value(xmlNode *dict, const char *key, xmlNode *root) {
  for (xmlNode *n = element(dict->children); n;) {
    need(!xmlStrcmp(n->name, BAD_CAST "key"), "Invalid prelink dictionary");
    xmlChar *s = xmlNodeGetContent(resolve(n, root));
    int match = s && !strcmp((char *)s, key);
    xmlFree(s);
    xmlNode *value = element(n->next);
    need(value != NULL, "Odd prelink dictionary");
    if (match)
      return value;
    n = element(value->next);
  }
  return NULL;
}
static int equal(plist_t a, plist_t b) {
  if (!a || !b)
    return a == b;
  char *x = NULL, *y = NULL;
  uint32_t nx = 0, ny = 0;
  plist_to_xml(a, &x, &nx);
  plist_to_xml(b, &y, &ny);
  int same = x && y && nx == ny && !memcmp(x, y, nx);
  free(x);
  free(y);
  return same;
}
/* Inline references before removing an ID definition, so other kexts keep
 * their original values. Copies have no IDs and cannot introduce forward refs.
 */
static xmlNode *resolved_copy(xmlNode *node, xmlNode *root, unsigned depth) {
  need(node && depth < 128, "Cyclic prelink object");
  xmlNode *source = resolve(node, root);
  xmlNode *copy = xmlDocCopyNode(source, root->doc, 2);
  need(copy != NULL, "Cannot copy prelink object");
  xmlUnsetProp(copy, BAD_CAST "ID");
  xmlUnsetProp(copy, BAD_CAST "IDREF");
  if (!xmlStrcmp(node->name, BAD_CAST "key"))
    xmlNodeSetName(copy, BAD_CAST "key");
  for (xmlNode *child = source->children; child; child = child->next) {
    xmlNode *c = child->type == XML_ELEMENT_NODE
                     ? resolved_copy(child, root, depth + 1)
                     : xmlDocCopyNode(child, root->doc, 1);
    need(c != NULL, "Cannot copy prelink value");
    xmlAddChild(copy, c);
  }
  return copy;
}
static void preserve_refs(xmlNode *node, xmlNode *victim, xmlNode *root) {
  while (node) {
    xmlNode *next = node->next;
    if (node != victim) {
      xmlChar *ref = xmlGetProp(node, BAD_CAST "IDREF");
      int external = ref && find_id(victim->children, ref);
      xmlChar *own = xmlGetProp(victim, BAD_CAST "ID");
      external |= ref && own && !xmlStrcmp(ref, own);
      xmlFree(ref);
      xmlFree(own);
      if (external) {
        xmlNode *copy = resolved_copy(node, root, 0);
        xmlReplaceNode(node, copy);
        xmlFreeNode(node);
      } else
        preserve_refs(node->children, victim, root);
    }
    node = next;
  }
}
static xmlNode *from_plist(plist_t value, xmlDoc *doc) {
  plist_t wrapper = plist_new_dict();
  plist_dict_set_item(wrapper, "value", plist_copy(value));
  char *xml = NULL;
  uint32_t size = 0;
  plist_to_xml(wrapper, &xml, &size);
  plist_free(wrapper);
  need(xml != NULL && size < INT32_MAX, "Cannot encode kext property");
  xmlDoc *temp = xmlReadMemory(xml, size, "overlay.plist", NULL,
                               XML_PARSE_NONET | XML_PARSE_NOBLANKS);
  free(xml);
  need(temp != NULL, "Invalid kext property");
  xmlNode *dict = element(xmlDocGetRootElement(temp)->children);
  xmlNode *node = dict_value(dict, "value", xmlDocGetRootElement(temp));
  need(node != NULL, "Missing kext property");
  xmlNode *copy = xmlDocCopyNode(node, doc, 1);
  xmlFreeDoc(temp);
  need(copy != NULL, "Cannot copy kext property");
  return copy;
}
/* Rebuild a cache from its core and individually maintained linked kexts.
 * Stripped Apple kexts have no relocations: their verified VM addresses stay
 * fixed. No whole-cache delta or prebuilt cache is used by this assembler. */
typedef struct {
  size_t text, info, prefix;
  uint32_t vm, length;
} Cache;
static Cache cache_layout(Blob b, int complete) {
  need(b.n >= 28 && le32(b.p) == 0xfeedface && le32(b.p + 4) == 12,
       "Expected thin ARM kernel");
  size_t at = 28, count = le32(b.p + 16), bytes = le32(b.p + 20);
  need(count <= 4096 && bytes <= b.n - 28, "Invalid kernel commands");
  Cache c = {0};
  for (size_t i = 0; i < count; i++) {
    need(at + 8 <= 28 + bytes, "Truncated kernel command");
    size_t length = le32(b.p + at + 4);
    need(length >= 8 && length <= 28 + bytes - at,
         "Invalid kernel command size");
    if (le32(b.p + at) == 1) {
      need(length >= 56 && le32(b.p + at + 48) <= (length - 56) / 68,
           "Invalid kernel segment");
      size_t *slot = NULL;
      const char *section = NULL;
      if (!memcmp(b.p + at + 8, "__PRELINK_TEXT\0\0", 16)) {
        slot = &c.text;
        section = "__text";
      }
      if (!memcmp(b.p + at + 8, "__PRELINK_INFO\0\0", 16)) {
        slot = &c.info;
        section = "__info";
      }
      if (slot) {
        need(!*slot && length == 124 && le32(b.p + at + 48) == 1,
             "Unsupported prelink segment");
        need(!strcmp((char *)b.p + at + 56, section) &&
                 !memcmp(b.p + at + 72, b.p + at + 8, 16),
             "Unsupported prelink section");
        *slot = at;
      }
    }
    at += length;
  }
  need(at == 28 + bytes && c.text && c.info, "Missing prelink segments");
  c.prefix = le32(b.p + c.text + 32);
  c.vm = le32(b.p + c.text + 24);
  c.length = le32(b.p + c.text + 36);
  need(c.prefix >= at && c.prefix <= b.n && !(c.prefix & 4095) &&
           !(c.vm & 4095),
       "Invalid prelink text mapping");
  if (complete) {
    uint64_t off = le32(b.p + c.info + 32), size = le32(b.p + c.info + 36);
    need(c.length <= b.n - c.prefix && off == c.prefix + c.length && size &&
             off + size <= b.n,
         "Invalid prelink extents");
    need((uint64_t)c.vm + c.length == le32(b.p + c.info + 24),
         "Prelink VM mapping differs");
    need(le32(b.p + c.text + 28) == c.length &&
             le32(b.p + c.text + 92) == c.length &&
             le32(b.p + c.text + 88) == c.vm &&
             le32(b.p + c.text + 96) == c.prefix,
         "Invalid prelink text section");
    need(le32(b.p + c.info + 88) == le32(b.p + c.info + 24) &&
             le32(b.p + c.info + 92) == size && le32(b.p + c.info + 96) == off,
         "Invalid prelink info section");
    for (size_t i = off + size; i < b.n; i++)
      need(!b.p[i], "Nonzero data after prelink info");
  }
  /* Every other file-backed segment belongs to the standalone core. */
  for (at = 28; at < 28 + bytes; at += le32(b.p + at + 4)) {
    if (le32(b.p + at) != 1 || at == c.text || at == c.info)
      continue;
    uint64_t off = le32(b.p + at + 32), size = le32(b.p + at + 36);
    need(!size || off + size <= c.prefix,
         "Unsupported segment after kernel core");
  }
  return c;
}
static void normalize_core(Blob b, Cache c) {
  const unsigned text[] = {28, 36, 92}, info[] = {24, 28, 32, 36, 88, 92, 96};
  for (unsigned i = 0; i < sizeof(text) / sizeof(*text); i++)
    putle(b.p + c.text + text[i], 0);
  for (unsigned i = 0; i < sizeof(info) / sizeof(*info); i++)
    putle(b.p + c.info + info[i], 0);
}
static plist_t row_for(plist_t rows, const char *id, size_t *index) {
  plist_t result = NULL;
  for (uint32_t i = 0; i < plist_array_get_size(rows); i++) {
    plist_t row = plist_array_get_item(rows, i);
    char *name = pstr(plist_dict_get_item(row, "CFBundleIdentifier"));
    if (!strcmp(name, id)) {
      need(!result, "Duplicate kext bundle ID");
      result = row;
      if (index)
        *index = i;
    }
    free(name);
  }
  return result;
}
static xmlNode *row_node(xmlNode *array, size_t index) {
  xmlNode *node = element(array->children);
  while (node && index--)
    node = element(node->next);
  need(node && !xmlStrcmp(node->name, BAD_CAST "dict"),
       "Invalid kext XML entry");
  return node;
}
static void set_property(xmlNode *node, plist_t row, const char *key,
                         plist_t value, xmlNode *root, xmlNode *source) {
  if (!source && equal(plist_dict_get_item(row, key), value))
    return;
  xmlNode *old = dict_value(node, key, root),
          *copy = source ? xmlDocCopyNode(source, root->doc, 1)
                         : from_plist(value, root->doc);
  need(copy != NULL, "Cannot copy driver property");
  /* Address fields in Apple's prelink format are explicitly 64 bit. */
  if (!strncmp(key, "_Prelink", 8) && plist_get_node_type(value) == PLIST_UINT)
    xmlSetProp(copy, BAD_CAST "size", BAD_CAST "64");
  if (old) {
    preserve_refs(root, old, root);
    xmlReplaceNode(old, copy);
    xmlFreeNode(old);
  } else {
    xmlNewTextChild(node, NULL, BAD_CAST "key", BAD_CAST key);
    xmlAddChild(node, copy);
  }
  plist_dict_set_item(row, key, plist_copy(value));
}
static void uint_property(xmlNode *node, plist_t row, const char *key,
                          uint64_t value, xmlNode *root) {
  plist_t n = plist_new_uint(value);
  set_property(node, row, key, n, root, NULL);
  plist_free(n);
}
static void overlay_file(xmlNode *node, plist_t row, const char *file,
                         const char *field, const char *id, xmlNode *root) {
  if (!strcmp(file, "-"))
    return;
  Blob bytes = read_file(file);
  plist_t patch = parse_plist(bytes);
  need(plist_get_node_type(patch) == PLIST_DICT, "Expected driver dictionary");
  /* Keep integer widths in personality XML. libplist's value model alone
   * cannot distinguish an OSNumber created with size=32 from size=64. */
  xmlDoc *doc = xmlReadMemory((char *)bytes.p, bytes.n, file, NULL,
                              XML_PARSE_NONET | XML_PARSE_NOBLANKS);
  free(bytes.p);
  need(doc != NULL, "Driver configuration must be an XML plist");
  xmlNode *config = xmlDocGetRootElement(doc);
  if (config && !xmlStrcmp(config->name, BAD_CAST "plist"))
    config = element(config->children);
  need(config && !xmlStrcmp(config->name, BAD_CAST "dict"),
       "Driver configuration must contain a dictionary");
  if (field)
    set_property(node, row, field, patch, root, config);
  else {
    plist_dict_iter it = NULL;
    plist_dict_new_iter(patch, &it);
    char *key;
    plist_t value;
    for (;;) {
      plist_dict_next_item(patch, it, &key, &value);
      if (!key)
        break;
      need(strncmp(key, "_Prelink", 8) && strcmp(key, "IOKitPersonalities") &&
               strcmp(key, "OSBundleLibraries"),
           "Info.plist contains reserved driver field");
      if (!strcmp(key, "CFBundleIdentifier")) {
        char *name = pstr(value);
        need(!strcmp(name, id), "Driver bundle ID differs");
        free(name);
      }
      set_property(node, row, key, value, root,
                   dict_value(config, key, config));
      free(key);
    }
    free(it);
  }
  plist_free(patch);
  xmlFreeDoc(doc);
}
static Blob module_blob(Blob source, Cache c, plist_t row) {
  uint64_t size = puint(plist_dict_get_item(row, "_PrelinkExecutableSize"));
  if (!size)
    return (Blob){NULL, 0};
  uint64_t addr =
      puint(plist_dict_get_item(row, "_PrelinkExecutableSourceAddr"));
  need(addr >= c.vm && addr - c.vm <= c.length &&
           size <= c.length - (addr - c.vm),
       "Kext lies outside prelink text");
  return (Blob){source.p + c.prefix + addr - c.vm, size};
}
static void check_module(Blob code, uint64_t address) {
  need(code.n >= 28 && le32(code.p) == 0xfeedface && le32(code.p + 4) == 12,
       "Expected thin linked ARM kext");
  size_t at = 28, count = le32(code.p + 16), bytes = le32(code.p + 20);
  need(count <= 4096 && bytes <= code.n - 28, "Invalid kext commands");
  for (size_t i = 0; i < count; i++) {
    need(at + 8 <= 28 + bytes, "Truncated kext command");
    size_t length = le32(code.p + at + 4);
    need(length >= 8 && length <= 28 + bytes - at, "Invalid kext command size");
    if (le32(code.p + at) == 1) {
      need(length >= 56, "Invalid kext segment");
      uint64_t vm = le32(code.p + at + 24), off = le32(code.p + at + 32),
               size = le32(code.p + at + 36);
      need(!size ||
               (off <= code.n && size <= code.n - off && vm == address + off),
           "Kext requires relocation");
    }
    at += length;
  }
  need(at == 28 + bytes, "Invalid kext commands extent");
}
static void build_cache(char **argv) {
  Blob source = read_file(argv[2]), core = read_file(argv[3]);
  Cache s = cache_layout(source, 1), c = cache_layout(core, 0);
  need(core.n == s.prefix && c.prefix == s.prefix && c.vm == s.vm &&
           c.text == s.text && c.info == s.info,
       "Kernel core layout differs");
  Blob normalized = {alloc(core.n), core.n};
  memcpy(normalized.p, core.p, core.n);
  normalize_core(normalized, c);
  need(!memcmp(normalized.p, core.p, core.n),
       "Kernel core has stale cache sizes");
  free(normalized.p);
  size_t infooff = le32(source.p + s.info + 32),
         infosize = le32(source.p + s.info + 36);
  while (infosize && !source.p[infooff + infosize - 1])
    infosize--;
  plist_t metadata = parse_prelink((Blob){source.p + infooff, infosize});
  plist_t rows = plist_dict_get_item(metadata, "_PrelinkInfoDictionary");
  need(plist_get_node_type(rows) == PLIST_ARRAY, "Missing prelink kext array");
  plist_t originals = plist_copy(rows), paths = plist_new_dict(),
          seen = plist_new_dict();
  xmlDoc *doc = xmlReadMemory((char *)source.p + infooff, infosize,
                              "prelink.xml", NULL, XML_PARSE_NONET);
  need(doc != NULL, "Invalid source prelink XML");
  xmlNode *root = xmlDocGetRootElement(doc),
          *array = dict_value(root, "_PrelinkInfoDictionary", root);
  need(array && !xmlStrcmp(array->name, BAD_CAST "array"),
       "Missing prelink XML array");
  FILE *plan = fopen(argv[4], "r");
  need(plan != NULL, "Cannot read driver plan");
  char *line = NULL;
  size_t capacity = 0;
  while (getline(&line, &capacity, plan) >= 0) {
    line[strcspn(line, "\r\n")] = 0;
    if (!*line || *line == '#')
      continue;
    char *fields[7], *state = NULL;
    size_t n = 0;
    for (char *v = strtok_r(line, "\t", &state); v && n < 7;
         v = strtok_r(NULL, "\t", &state))
      fields[n++] = v;
    need(n == 6, "Invalid driver plan row");
    char *id = fields[0];
    need(!plist_dict_get_item(seen, id), "Duplicate driver plan entry");
    plist_dict_set_item(seen, id, plist_new_bool(1));
    size_t index = 0;
    plist_t row = row_for(rows, id, &index);
    xmlNode *node;
    int added = !row;
    if (added) {
      need(strcmp(fields[1], "-") && strcmp(fields[5], "-"),
           "New kext needs executable and layout");
      row = plist_new_dict();
      plist_array_append_item(rows, row);
      node = xmlNewChild(array, NULL, BAD_CAST "dict", NULL);
    } else {
      need(!strcmp(fields[5], "-"), "Cannot relocate a stock kext");
      node = row_node(array, index);
    }
    overlay_file(node, row, fields[2], NULL, id, root);
    overlay_file(node, row, fields[3], "IOKitPersonalities", id, root);
    overlay_file(node, row, fields[4], "OSBundleLibraries", id, root);
    char *name = pstr(plist_dict_get_item(row, "CFBundleIdentifier"));
    need(!strcmp(name, id), "Driver Info.plist lacks bundle ID");
    free(name);
    if (strcmp(fields[1], "-")) {
      Blob code = read_file(fields[1]);
      if (added) {
        plist_t layout = load_plist(fields[5]);
        need(plist_get_node_type(layout) == PLIST_DICT &&
                 plist_dict_get_size(layout) == 4,
             "Invalid driver layout");
        need(plist_get_node_type(plist_dict_get_item(layout, "Address")) ==
                     PLIST_UINT &&
                 plist_get_node_type(
                     plist_dict_get_item(layout, "KmodOffset")) == PLIST_UINT,
             "Driver address and kmod offset must be integers");
        uint64_t address = puint(plist_dict_get_item(layout, "Address")),
                 kmod = puint(plist_dict_get_item(layout, "KmodOffset"));
        need(address >= (uint64_t)s.vm + s.length && !(address & 4095) &&
                 address <= UINT32_MAX && code.n <= UINT32_MAX - address &&
                 kmod < code.n,
             "Invalid new kext placement");
        uint_property(node, row, "_PrelinkExecutableLoadAddr", address, root);
        uint_property(node, row, "_PrelinkExecutableSourceAddr", address, root);
        uint_property(node, row, "_PrelinkExecutableSize", code.n, root);
        uint_property(node, row, "_PrelinkKmodInfo", address + kmod, root);
        const char *keys[] = {"BundlePath", "Executable"},
                   *dest[] = {"_PrelinkBundlePath",
                              "_PrelinkExecutableRelativePath"};
        for (unsigned i = 0; i < 2; i++) {
          plist_t value = plist_dict_get_item(layout, keys[i]);
          need(value && plist_get_node_type(value) == PLIST_STRING,
               "Missing kext layout path");
          set_property(node, row, dest[i], value, root, NULL);
        }
        plist_free(layout);
      } else
        need(code.n ==
                 puint(plist_dict_get_item(row, "_PrelinkExecutableSize")),
             "Stock kext size changed; relocation required");
      check_module(
          code, puint(plist_dict_get_item(row, "_PrelinkExecutableLoadAddr")));
      free(code.p);
      plist_dict_set_item(paths, id, plist_new_string(fields[1]));
    }
  }
  need(!ferror(plan), "Driver plan read failed");
  fclose(plan);
  /* The explicit list defines the complete order, including codeless kexts. */
  FILE *list = fopen(argv[5], "r");
  need(list != NULL, "Cannot read kext list");
  size_t count = 0;
  plist_free(seen);
  seen = plist_new_dict();
  while (getline(&line, &capacity, list) >= 0) {
    line[strcspn(line, "\r\n")] = 0;
    if (!*line || *line == '#')
      continue;
    need(!plist_dict_get_item(seen, line), "Duplicate kext list entry");
    plist_dict_set_item(seen, line, plist_new_bool(1));
    plist_t row = plist_array_get_item(rows, count++);
    char *id = pstr(plist_dict_get_item(row, "CFBundleIdentifier"));
    if (strcmp(id, line))
      die("Kext list order differs at %s (got %s)", line, id);
    free(id);
  }
  need(!ferror(list) && count == plist_array_get_size(rows),
       "Kext list differs from selected drivers");
  fclose(list);
  free(line);
  uint64_t end = s.vm;
  for (uint32_t i = 0; i < count; i++) {
    plist_t row = plist_array_get_item(rows, i),
            deps = plist_dict_get_item(row, "OSBundleLibraries");
    need(!deps || plist_get_node_type(deps) == PLIST_DICT,
         "Invalid driver dependencies");
    plist_dict_iter it = NULL;
    if (deps)
      plist_dict_new_iter(deps, &it);
    char *dep;
    plist_t version;
    while (it) {
      plist_dict_next_item(deps, it, &dep, &version);
      if (!dep)
        break;
      if (!plist_dict_get_item(seen, dep))
        die("Missing kext dependency: %s", dep);
      need(plist_get_node_type(version) == PLIST_STRING,
           "Invalid dependency version");
      free(dep);
    }
    free(it);
    uint64_t size = puint(plist_dict_get_item(row, "_PrelinkExecutableSize"));
    if (!size)
      continue;
    uint64_t address =
        puint(plist_dict_get_item(row, "_PrelinkExecutableSourceAddr"));
    need(address >= s.vm &&
             address == puint(plist_dict_get_item(
                            row, "_PrelinkExecutableLoadAddr")) &&
             address <= UINT32_MAX && size <= UINT32_MAX - address,
         "Unsupported kext mapping");
    if (address + size > end)
      end = address + size;
  }
  uint64_t textsize = (end - s.vm + 4095) & ~(uint64_t)4095;
  xmlBuffer *buffer = xmlBufferCreate();
  need(buffer != NULL, "Cannot allocate prelink XML");
  need(xmlNodeDump(buffer, doc, root, 0, 0) >= 0,
       "Cannot serialize prelink XML");
  size_t used = xmlBufferLength(buffer) + 1,
         space = (used + 4095) & ~(size_t)4095;
  plist_t check = parse_prelink(
      (Blob){(unsigned char *)xmlBufferContent(buffer), used - 1});
  need(equal(metadata, check),
       "Kext metadata changed outside selected driver files");
  plist_free(check);
  need(s.vm + textsize + space <= UINT32_MAX &&
           s.prefix + textsize + space <= UINT32_MAX,
       "Rebuilt cache exceeds ARM address range");
  Blob output = {alloc(s.prefix + textsize + space),
                 s.prefix + textsize + space};
  memcpy(output.p, core.p, core.n);
  /* Fresh text segment and explicit zero padding; never copy the old cache as
   * an opaque body. Each selected executable is placed and checked once. */
  uint64_t *starts = alloc(count * sizeof(uint64_t)),
           *ends = alloc(count * sizeof(uint64_t));
  for (uint32_t i = 0; i < count; i++) {
    plist_t row = plist_array_get_item(rows, i);
    char *id = pstr(plist_dict_get_item(row, "CFBundleIdentifier"));
    plist_t path = plist_dict_get_item(paths, id);
    char *file = pstr(path);
    Blob code = path ? read_file(file)
                     : module_blob(source, s, row_for(originals, id, NULL));
    uint64_t address = puint(
                 plist_dict_get_item(row, "_PrelinkExecutableSourceAddr")),
             size = puint(plist_dict_get_item(row, "_PrelinkExecutableSize"));
    need(code.n == size, "Kext executable size differs");
    if (size) {
      check_module(code, address);
      starts[i] = address;
      ends[i] = address + size;
      for (uint32_t j = 0; j < i; j++)
        need(!ends[j] || ends[i] <= starts[j] || starts[i] >= ends[j],
             "Overlapping kext executables");
      memcpy(output.p + s.prefix + address - s.vm, code.p, size);
    }
    if (path)
      free(code.p);
    free(id);
    free(file);
  }
  size_t at = s.prefix + textsize;
  memcpy(output.p + at, xmlBufferContent(buffer), used - 1);
  putle(output.p + c.text + 28, textsize);
  putle(output.p + c.text + 36, textsize);
  putle(output.p + c.text + 92, textsize);
  putle(output.p + c.info + 24, s.vm + textsize);
  putle(output.p + c.info + 28, space);
  putle(output.p + c.info + 32, at);
  putle(output.p + c.info + 36, used);
  putle(output.p + c.info + 88, s.vm + textsize);
  putle(output.p + c.info + 92, used);
  putle(output.p + c.info + 96, at);
  cache_layout(output, 1);
  write_file(argv[6], output);
  free(starts);
  free(ends);
  free(source.p);
  free(core.p);
  free(output.p);
  xmlBufferFree(buffer);
  xmlFreeDoc(doc);
  plist_free(metadata);
  plist_free(originals);
  plist_free(paths);
  plist_free(seen);
}
int kernel_main(int argc, char **argv) {
  if (!strcmp(argv[1], "kernel-core")) {
    need(argc == 4, "kernel-core KERNEL OUTPUT");
    Blob b = read_file(argv[2]);
    Cache c = cache_layout(b, 1);
    normalize_core(b, c);
    b.n = c.prefix;
    write_file(argv[3], b);
    free(b.p);
    return 1;
  }
  if (!strcmp(argv[1], "kernel-build")) {
    need(argc == 7, "kernel-build SOURCE CORE DRIVER_PLAN KEXT_LIST OUTPUT");
    build_cache(argv);
    return 1;
  }
  return 0;
}
