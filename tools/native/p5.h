#ifndef P5_H
#define P5_H
#define _FILE_OFFSET_BITS 64
#include <errno.h>
#include <plist/plist.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef struct {
  unsigned char *p;
  size_t n;
} Blob;
void die(const char *fmt, ...);
void need(int ok, const char *message);
void *alloc(size_t n);
Blob read_file(const char *name);
void write_file(const char *name, Blob data);
uint32_t le32(const unsigned char *p);
uint32_t be32(const unsigned char *p);
uint64_t be64(const unsigned char *p);
void putle(unsigned char *p, uint32_t n);
void putbe(unsigned char *p, uint32_t n);
Blob unhex(const char *hex);
char *hex(Blob data);
plist_t parse_prelink(Blob data);
plist_t load_plist(const char *path);
plist_t parse_plist(Blob data);
plist_t decode_json(plist_t node);
void print_json(plist_t node);
void save_plist(const char *path, plist_t node, int binary);
char *pstr(plist_t node);
uint64_t puint(plist_t node);
int plist_main(int argc, char **argv);
int zip_main(int argc, char **argv);
int mux_main(int argc, char **argv);
int archive_main(int argc, char **argv);
int process_main(int argc, char **argv);
#endif
