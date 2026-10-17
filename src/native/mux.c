#include "p5.h"
#include <arpa/inet.h>
#include <signal.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>
static const char *socket_path = "/var/run/usbmuxd";
static int connection(void) {
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0)
    return -1;
  struct timeval timeout = {15, 0};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
  struct sockaddr_un addr = {0};
  addr.sun_family = AF_UNIX;
  need(strlen(socket_path) < sizeof(addr.sun_path),
       "usbmux socket path too long");
  strcpy(addr.sun_path, socket_path);
  if (connect(fd, (struct sockaddr *)&addr, sizeof(addr))) {
    int error = errno;
    close(fd);
    errno = error;
    return -1;
  }
  return fd;
}
static int transfer(int fd, void *data, size_t n, int write) {
  unsigned char *p = data;
  while (n) {
    ssize_t k = write ? send(fd, p, n, 0) : recv(fd, p, n, 0);
    if (k <= 0)
      return 0;
    p += k;
    n -= k;
  }
  return 1;
}
static plist_t exchange(int fd, plist_t request, int mux) {
  char *xml = NULL;
  uint32_t length = 0;
  plist_to_xml(request, &xml, &length);
  if (!xml)
    return NULL;
  unsigned char header[16];
  if (mux) {
    putle(header, length + 16);
    putle(header + 4, 1);
    putle(header + 8, 8);
    putle(header + 12, 1);
  } else
    putbe(header, length);
  int ok =
      transfer(fd, header, mux ? 16 : 4, 1) && transfer(fd, xml, length, 1);
  free(xml);
  if (!ok || !transfer(fd, header, mux ? 16 : 4, 0))
    return NULL;
  length = mux ? le32(header) : be32(header);
  if (mux) {
    if (length < 16 || le32(header + 4) != 1 || le32(header + 8) != 8 ||
        le32(header + 12) != 1)
      return NULL;
    length -= 16;
  }
  if (!length || length > 4 * 1024 * 1024)
    return NULL;
  Blob b = {alloc(length), length};
  if (!transfer(fd, b.p, b.n, 0)) {
    free(b.p);
    return NULL;
  }
  plist_t p = NULL;
  plist_from_memory((char *)b.p, b.n, &p, NULL);
  free(b.p);
  return p;
}
static plist_t mux_request(const char *type) {
  plist_t p = plist_new_dict();
  plist_dict_set_item(p, "MessageType", plist_new_string(type));
  plist_dict_set_item(p, "ClientVersionString", plist_new_string("Project5C"));
  plist_dict_set_item(p, "ProgName", plist_new_string("Project5C"));
  plist_dict_set_item(p, "kLibUSBMuxVersion", plist_new_uint(3));
  return p;
}
static plist_t query(int fd, const char *request, const char *key) {
  plist_t p = plist_new_dict();
  plist_dict_set_item(p, "Label", plist_new_string("restore6"));
  plist_dict_set_item(p, "Request", plist_new_string(request));
  if (key)
    plist_dict_set_item(p, "QueryKey", plist_new_string(key));
  plist_t r = exchange(fd, p, 0);
  plist_free(p);
  return r;
}
int mux_main(int argc, char **argv) {
  if (strcmp(argv[1], "restored-probe"))
    return 0;
  int positional = 4;
  need(argc == positional ||
           (argc == positional + 2 && !strcmp(argv[positional], "--socket")),
       "restored-probe ECID N48AP|N49AP [--socket PATH]");
  if (argc == positional + 2)
    socket_path = argv[positional + 1];
  signal(SIGPIPE, SIG_IGN);
  need(!strcasecmp(argv[3], "N48AP") || !strcasecmp(argv[3], "N49AP"),
       "Unsupported restore target");
  uint64_t ecid = strtoull(argv[2], NULL, 0);
  int board = !strcasecmp(argv[3], "N48AP") ? 10 : 14;
  int fd = connection();
  if (fd < 0) {
    die("usbmuxd is unavailable");
  }
  plist_t p = mux_request("ListDevices"), reply = exchange(fd, p, 1);
  plist_free(p);
  close(fd);
  need(reply != NULL, "Invalid usbmuxd reply");
  plist_t devices = plist_dict_get_item(reply, "DeviceList"),
          found = plist_new_array();
  for (uint32_t i = 0; devices && i < plist_array_get_size(devices); i++) {
    plist_t device = plist_array_get_item(devices, i),
            props = plist_dict_get_item(device, "Properties");
    char *type = pstr(plist_dict_get_item(props, "ConnectionType"));
    int usb = !strcmp(type, "USB") || !*type;
    free(type);
    if (!usb)
      continue;
    fd = connection();
    if (fd < 0)
      continue;
    p = mux_request("Connect");
    plist_dict_set_item(p, "DeviceID",
                        plist_copy(plist_dict_get_item(device, "DeviceID")));
    plist_dict_set_item(p, "PortNumber", plist_new_uint(htons(62078)));
    plist_t connected = exchange(fd, p, 1);
    plist_free(p);
    if (!connected || !plist_dict_get_item(connected, "Number") ||
        puint(plist_dict_get_item(connected, "Number"))) {
      plist_free(connected);
      close(fd);
      continue;
    }
    plist_free(connected);
    plist_t kind = query(fd, "QueryType", NULL);
    if (!kind) {
      close(fd);
      continue;
    }
    char *service = pstr(plist_dict_get_item(kind, "Type"));
    if (strcmp(service, "com.apple.mobile.restored")) {
      free(service);
      plist_free(kind);
      close(fd);
      continue;
    }
    free(service);
    plist_t value = query(fd, "QueryValue", "HardwareInfo"),
            info = value ? plist_dict_get_item(value, "HardwareInfo") : NULL;
    char *model = pstr(plist_dict_get_item(kind, "HardwareModel"));
    if (!*model) {
      free(model);
      plist_t r = query(fd, "QueryValue", "HardwareModel");
      model = pstr(r ? plist_dict_get_item(r, "HardwareModel") : NULL);
      plist_free(r);
    }
    int valid =
        info &&
        puint(plist_dict_get_item(kind, "RestoreProtocolVersion")) == 12 &&
        !strcasecmp(model, argv[3]) &&
        puint(plist_dict_get_item(info, "ChipID")) == 0x8950 &&
        puint(plist_dict_get_item(info, "BoardID")) == (uint64_t)board &&
        puint(plist_dict_get_item(info, "UniqueChipID")) == ecid && ecid > 0;
    if (valid) {
      plist_t result = plist_new_dict();
      plist_dict_set_item(result, "device_id",
                          plist_copy(plist_dict_get_item(device, "DeviceID")));
      plist_dict_set_item(result, "protocol", plist_new_uint(12));
      plist_dict_set_item(result, "hardware_model", plist_new_string(model));
      plist_dict_set_item(result, "ecid", plist_new_uint(ecid));
      plist_array_append_item(found, result);
    }
    free(model);
    plist_free(value);
    plist_free(kind);
    close(fd);
  }
  need(plist_array_get_size(found) == 1,
       "Expected exactly one matching iOS 6 restored USB device");
  print_json(plist_array_get_item(found, 0));
  plist_free(found);
  plist_free(reply);
  return 1;
}
