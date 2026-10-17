#include "p5.h"
plist_t parse_plist(Blob b) {
  need(b.n <= UINT32_MAX, "Plist too large");
  plist_t p = NULL;
  plist_from_memory((char *)b.p, b.n, &p, NULL);
  need(p != NULL, "Invalid plist/JSON");
  return p;
}
plist_t load_plist(const char *path) {
  Blob b = read_file(path);
  plist_t p = parse_plist(b);
  free(b.p);
  return p;
}
char *pstr(plist_t n) {
  char *s = NULL;
  if (n && plist_get_node_type(n) == PLIST_STRING)
    plist_get_string_val(n, &s);
  return s ? s : strdup("");
}
uint64_t puint(plist_t n) {
  uint64_t v = 0;
  if (n)
    plist_get_uint_val(n, &v);
  return v;
}
/* Typed JSON prevents plist DATA, dates and UIDs becoming plain strings. */
static plist_t encode(plist_t p) {
  plist_type type = plist_get_node_type(p);
  if (type == PLIST_DATA) {
    uint64_t n;
    const char *d = plist_get_data_ptr(p, &n);
    char *s = hex((Blob){(unsigned char *)d, n});
    plist_t v = plist_new_dict();
    plist_dict_set_item(v, "$data", plist_new_string(s));
    free(s);
    return v;
  }
  if (type == PLIST_DATE) {
    int32_t sec, usec;
    plist_get_date_val(p, &sec, &usec);
    plist_t v = plist_new_dict(), a = plist_new_array();
    plist_array_append_item(a, plist_new_int(sec));
    plist_array_append_item(a, plist_new_uint(usec));
    plist_dict_set_item(v, "$date", a);
    return v;
  }
  if (type == PLIST_UID) {
    uint64_t id;
    plist_get_uid_val(p, &id);
    plist_t v = plist_new_dict();
    plist_dict_set_item(v, "$uid", plist_new_uint(id));
    return v;
  }
  if (type == PLIST_ARRAY) {
    plist_t v = plist_new_array();
    for (uint32_t i = 0; i < plist_array_get_size(p); i++)
      plist_array_append_item(v, encode(plist_array_get_item(p, i)));
    return v;
  }
  if (type == PLIST_DICT) {
    plist_t v = plist_new_dict();
    plist_dict_iter it = NULL;
    plist_dict_new_iter(p, &it);
    char *key = NULL;
    plist_t n;
    while (1) {
      plist_dict_next_item(p, it, &key, &n);
      if (!key)
        break;
      plist_dict_set_item(v, key, encode(n));
      free(key);
    }
    free(it);
    return v;
  }
  return plist_copy(p);
}
plist_t decode_json(plist_t p) {
  plist_type type = plist_get_node_type(p);
  if (type == PLIST_DICT) {
    if (plist_dict_get_size(p) == 1) {
      plist_t n = plist_dict_get_item(p, "$data");
      if (n) {
        char *s = pstr(n);
        Blob b = unhex(s);
        plist_t v = plist_new_data((char *)b.p, b.n);
        free(s);
        free(b.p);
        return v;
      }
      n = plist_dict_get_item(p, "$date");
      if (n) {
        need(plist_get_node_type(n) == PLIST_ARRAY &&
                 plist_array_get_size(n) == 2,
             "Invalid typed date");
        return plist_new_date((int32_t)puint(plist_array_get_item(n, 0)),
                              puint(plist_array_get_item(n, 1)));
      }
      n = plist_dict_get_item(p, "$uid");
      if (n)
        return plist_new_uid(puint(n));
    }
    plist_t v = plist_new_dict();
    plist_dict_iter it = NULL;
    plist_dict_new_iter(p, &it);
    char *key = NULL;
    plist_t n;
    while (1) {
      plist_dict_next_item(p, it, &key, &n);
      if (!key)
        break;
      plist_dict_set_item(v, key, decode_json(n));
      free(key);
    }
    free(it);
    return v;
  }
  if (type == PLIST_ARRAY) {
    plist_t v = plist_new_array();
    for (uint32_t i = 0; i < plist_array_get_size(p); i++)
      plist_array_append_item(v, decode_json(plist_array_get_item(p, i)));
    return v;
  }
  return plist_copy(p);
}
void print_json(plist_t p) {
  plist_t v = encode(p);
  char *s = NULL;
  uint32_t n = 0;
  need(plist_to_json(v, &s, &n, 1) == PLIST_ERR_SUCCESS && s,
       "Cannot encode JSON");
  need(fwrite(s, 1, n, stdout) == n, "JSON write failed");
  fputc('\n', stdout);
  free(s);
  plist_free(v);
}
void save_plist(const char *path, plist_t p, int binary) {
  char *s = NULL;
  uint32_t n = 0;
  if (binary)
    plist_to_bin(p, &s, &n);
  else
    plist_to_xml(p, &s, &n);
  need(s != NULL, "Cannot encode plist");
  write_file(path, (Blob){(unsigned char *)s, n});
  free(s);
}
int plist_main(int argc, char **argv) {
  if (!strcmp(argv[1], "typed-plist-json")) {
    need(argc == 3, "typed-plist-json INPUT");
    plist_t p = load_plist(argv[2]);
    print_json(p);
    plist_free(p);
    return 1;
  }
  if (!strcmp(argv[1], "typed-json-plist")) {
    need(argc == 4 || argc == 5, "typed-json-plist INPUT OUTPUT [binary]");
    plist_t p = load_plist(argv[2]), v = decode_json(p);
    save_plist(argv[3], v, argc == 5);
    plist_free(p);
    plist_free(v);
    return 1;
  }
  return 0;
}

#include <libxml/parser.h>
#include <openssl/evp.h>
static xmlNode *element(xmlNode *n) {
  while (n && n->type != XML_ELEMENT_NODE)
    n = n->next;
  return n;
}
static plist_t prelink_node(xmlNode *node, plist_t refs, unsigned depth) {
  need(node && depth < 128, "Invalid prelink XML depth");
  xmlChar *ref = xmlGetProp(node, (xmlChar *)"IDREF");
  if (ref) {
    plist_t p = plist_dict_get_item(refs, (char *)ref);
    xmlFree(ref);
    need(p != NULL, "Missing/forward prelink IDREF");
    return plist_copy(p);
  }
  xmlChar *text = xmlNodeGetContent(node);
  const char *tag = (char *)node->name, *s = text ? (char *)text : "";
  plist_t p = NULL;
  if (!strcmp(tag, "dict")) {
    p = plist_new_dict();
    xmlNode *n = element(node->children);
    while (n) {
      need(!xmlStrcmp(n->name, (xmlChar *)"key"),
           "Invalid prelink dictionary key");
      plist_t key = prelink_node(n, refs, depth + 1);
      char *name = pstr(key);
      plist_free(key);
      n = element(n->next);
      need(n != NULL, "Odd prelink dictionary");
      plist_dict_set_item(p, name, prelink_node(n, refs, depth + 1));
      free(name);
      n = element(n->next);
    }
  } else if (!strcmp(tag, "array")) {
    p = plist_new_array();
    for (xmlNode *n = element(node->children); n; n = element(n->next))
      plist_array_append_item(p, prelink_node(n, refs, depth + 1));
  } else if (!strcmp(tag, "string") || !strcmp(tag, "key") ||
             !strcmp(tag, "date"))
    p = plist_new_string(s);
  else if (!strcmp(tag, "integer")) {
    char *end;
    errno = 0;
    uint64_t v = strtoull(s, &end, 0);
    while (*end == ' ' || *end == '\n' || *end == '\t')
      end++;
    need(!errno && end != s && !*end, "Invalid prelink integer");
    p = plist_new_uint(v);
  } else if (!strcmp(tag, "real"))
    p = plist_new_real(strtod(s, NULL));
  else if (!strcmp(tag, "true") || !strcmp(tag, "false"))
    p = plist_new_bool(!strcmp(tag, "true"));
  else if (!strcmp(tag, "data")) {
    size_t len = strlen(s), n = 0;
    char *clean = alloc(len + 1);
    for (size_t i = 0; i < len; i++)
      if (s[i] != ' ' && s[i] != '\n' && s[i] != '\r' && s[i] != '\t')
        clean[n++] = s[i];
    unsigned char *raw = alloc(n + 1);
    int used = n ? EVP_DecodeBlock(raw, (unsigned char *)clean, n) : 0;
    need(used >= 0, "Invalid prelink DATA");
    if (n && clean[n - 1] == '=')
      used--;
    if (n > 1 && clean[n - 2] == '=')
      used--;
    p = plist_new_data((char *)raw, used);
    free(clean);
    free(raw);
  } else
    die("Unsupported prelink element: %s", tag);
  xmlChar *id = xmlGetProp(node, (xmlChar *)"ID");
  if (id) {
    plist_dict_set_item(refs, (char *)id, plist_copy(p));
    xmlFree(id);
  }
  xmlFree(text);
  return p;
}
plist_t parse_prelink(Blob b) {
  while (b.n && b.p[b.n - 1] == 0)
    b.n--;
  need(b.n < INT32_MAX, "Prelink XML too large");
  xmlDoc *doc =
      xmlReadMemory((char *)b.p, b.n, "prelink.xml", NULL,
                    XML_PARSE_NONET | XML_PARSE_NOERROR | XML_PARSE_NOWARNING);
  need(doc != NULL, "Invalid prelink XML");
  plist_t refs = plist_new_dict(),
          result = prelink_node(xmlDocGetRootElement(doc), refs, 0);
  plist_free(refs);
  xmlFreeDoc(doc);
  need(plist_get_node_type(result) == PLIST_DICT, "Invalid prelink root");
  return result;
}
