/* Included by restore.c: share upstream restore_sign_bbfw, without USB/restore. */
#include <errno.h>
#include <sys/stat.h>

static plist_t p5_bb_read(const char *path)
{
    void *data = NULL;
    size_t size = 0;
    plist_t result = NULL;
    if (read_file(path, &data, &size) < 0 || !size || size > 4194304) {
        free(data);
        return NULL;
    }
    plist_from_memory(data, (uint32_t)size, &result, NULL);
    free(data);
    return result;
}

static int p5_bb_save(const char *dir, const char *name, plist_t value)
{
    char *xml = NULL, *path = NULL;
    uint32_t size = 0;
    plist_to_xml(value, &xml, &size);
    if (!xml || asprintf(&path, "%s/%s", dir, name) < 0) {
        free(xml);
        return -1;
    }
    int result = write_file(path, xml, size);
    free(xml);
    free(path);
    return result;
}

static uint64_t p5_bb_number(plist_t dict, const char *key)
{
    plist_t node = plist_dict_get_item(dict, key);
    uint64_t value = UINT64_MAX;
    if (node && plist_get_node_type(node) == PLIST_UINT)
        plist_get_uint_val(node, &value);
    else if (node && plist_get_node_type(node) == PLIST_STRING) {
        char *str = NULL, *end = NULL;
        plist_get_string_val(node, &str);
        errno = 0;
        if (str && *str && *str != '-') {
            value = strtoull(str, &end, 0);
            if (errno || !end || *end) value = UINT64_MAX;
        }
        free(str);
    }
    return value;
}

static int p5_bb_data(plist_t dict, const char *key, uint64_t expected)
{
    plist_t node = plist_dict_get_item(dict, key);
    uint64_t size = 0;
    return node && plist_get_node_type(node) == PLIST_DATA &&
        plist_get_data_ptr(node, &size) && size == expected;
}

int project5c_baseband_sign(int argc, char **argv)
{
    int result = EXIT_FAILURE;
    plist_t identity = NULL, envelope = NULL, query = NULL;
    plist_t parameters = NULL, request = NULL, response = NULL;
    char *path = NULL;
    void *stock = NULL;
    size_t size = 0;
    uint64_t ecid, nonce_size = 0;
    const char *nonce = NULL;
    if (argc != 7) {
        fprintf(stderr, "Usage: %s --baseband-sign ECID IDENTITY QUERY STOCK_BBFW NEW_OUTPUT_DIR\n", argv[0]);
        return 2;
    }
    char *end = NULL;
    errno = 0;
    ecid = strtoull(argv[2], &end, 0);
    if (errno || !*argv[2] || *argv[2] == '-' || !end || *end || !ecid) goto fail;
    identity = p5_bb_read(argv[3]);
    envelope = p5_bb_read(argv[4]);
    if (!identity || plist_get_node_type(identity) != PLIST_DICT || !envelope ||
        plist_get_node_type(envelope) != PLIST_DICT) goto fail;
    /* Require the device identity envelope; never treat an AP nonce as BbNonce. */
    plist_t product = plist_dict_get_item(envelope, "ProductType");
    if (!product || plist_get_node_type(product) != PLIST_STRING ||
        (plist_string_val_compare(product, "iPhone5,4") &&
         plist_string_val_compare(product, "iPhone5,3")) ||
        p5_bb_number(envelope, "UniqueChipID") != ecid) goto fail;
    int n48 = !plist_string_val_compare(product, "iPhone5,3");
    query = plist_dict_get_item(envelope, "Baseband");
    if (!query || plist_get_node_type(query) != PLIST_DICT) goto fail;
    plist_t device_class = plist_access_path(identity, 2, "Info", "DeviceClass");
    if (!device_class || plist_get_node_type(device_class) != PLIST_STRING ||
        plist_string_val_compare(device_class, n48 ? "n48ap" : "n49ap") ||
        p5_bb_number(identity, "ApChipID") != 0x8950 ||
        p5_bb_number(identity, "ApBoardID") != (n48 ? 10 : 14) ||
        p5_bb_number(identity, "BbChipID") != 0x6f20e1 ||
        p5_bb_number(query, "ChipID") != 0x6f20e1 ||
        !p5_bb_data(query, "ChipSerialNo", 4)) goto fail;
    plist_t cert = plist_dict_get_item(query, "CertID");
    if (!cert || plist_get_node_type(cert) != PLIST_UINT) goto fail;
    uint64_t cert_value = p5_bb_number(query, "CertID");
    /* iOS can expose the sign-extended int32 CertID. Normalize to unsigned32. */
    if (cert_value > UINT32_MAX && cert_value < UINT64_C(0xffffffff80000000)) goto fail;
    plist_t nonce_node = plist_dict_get_item(query, "Nonce");
    if (nonce_node) {
        if (!p5_bb_data(query, "Nonce", 20)) goto fail;
        nonce = plist_get_data_ptr(nonce_node, &nonce_size);
        unsigned char any = 0;
        for (uint64_t i = 0; i < nonce_size; i++) any |= (unsigned char)nonce[i];
        if (!any) goto fail;
    }
    /* No offline/stale response injection: every invocation requests Apple TSS. */
    parameters = plist_new_dict();
    if (tss_parameters_add_from_manifest(parameters, identity, true) < 0) goto fail;
    plist_dict_set_item(parameters, "ApECID", plist_new_uint(ecid));
    plist_dict_set_item(parameters, "BbChipID", plist_new_uint(0x6f20e1));
    plist_dict_set_item(parameters, "BbGoldCertId", plist_new_uint((uint32_t)cert_value));
    plist_dict_set_item(parameters, "BbSNUM", plist_copy(plist_dict_get_item(query, "ChipSerialNo")));
    if (nonce_node) plist_dict_set_item(parameters, "BbNonce", plist_copy(nonce_node));
    request = tss_request_new(NULL);
    if (!request || tss_request_add_common_tags(request, parameters, NULL) < 0 ||
        tss_request_add_baseband_tags(request, parameters, NULL) < 0) goto fail;
    if (mkdir(argv[6], 0700) < 0) goto fail;
    if (p5_bb_save(argv[6], "request.plist", request) < 0 ||
        p5_bb_save(argv[6], "query.plist", envelope) < 0) goto fail;
    response = tss_request_send(request, "https://gs.apple.com/TSS/controller?action=2");
    {
        uint64_t ticket_size = 0;
        plist_t ticket = response ? plist_dict_get_item(response, "BBTicket") : NULL;
        if (!ticket || plist_get_node_type(ticket) != PLIST_DATA ||
            !plist_get_data_ptr(ticket, &ticket_size) || !ticket_size) goto fail;
    }
    plist_t blobs = plist_dict_get_item(response, "BasebandFirmware");
    const char *keys[] = {"SBL1-Blob", "RestoreSBL1-Blob"};
    for (unsigned i = 0; i < 2; i++) {
        uint64_t blob_size = 0;
        plist_t blob = blobs ? plist_dict_get_item(blobs, keys[i]) : NULL;
        if (!blob || plist_get_node_type(blob) != PLIST_DATA ||
            !plist_get_data_ptr(blob, &blob_size) || !blob_size) goto fail;
    }
    if (p5_bb_save(argv[6], "response.plist", response) < 0 ||
        read_file(argv[5], &stock, &size) < 0 || !size || size > 67108864 ||
        asprintf(&path, "%s/Mav7personalized.zip", argv[6]) < 0 ||
        write_file(path, stock, size) < 0) goto fail;
    if (restore_sign_bbfw(path, response, (const unsigned char *)nonce, 0x6f20e1) < 0) {
        remove(path);
        goto fail;
    }
    result = EXIT_SUCCESS;
    goto done;
fail:
    fprintf(stderr, "Baseband signing failed; no modem operation was performed.\n");
done:
    free(stock);
    free(path);
    plist_free(response);
    plist_free(request);
    plist_free(parameters);
    plist_free(envelope);
    plist_free(identity);
    return result;
}
