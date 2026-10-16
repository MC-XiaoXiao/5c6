/* Add guards and evidence to upstream BasebandData. Signing, stitching and
 * transport remain in restore_send_baseband_data. */
static int p5_native_bb_target(struct idevicerestore_client_t *c)
{
    return c && c->restore && (c->flags & FLAG_CUSTOM) &&
        c->restore->protocol_version == 12 && c->device &&
        (!strcmp(c->device->hardware_model,"n48ap") || !strcmp(c->device->hardware_model,"n49ap"));
}
static int p5_native_bb_active(struct idevicerestore_client_t *c)
{
    return p5_native_bb_target(c) && (c->flags & FLAG_PROJECT5C_BASEBAND);
}
static int p5_native_bb_same_query(plist_t a, plist_t b, unsigned depth)
{
    if (!a || !b || depth > 32 || plist_get_node_type(a)!=plist_get_node_type(b)) return 0;
    if (PLIST_IS_DICT(a)) {
        if (plist_dict_get_size(a)!=plist_dict_get_size(b)) return 0;
        plist_dict_iter iter=NULL; plist_dict_new_iter(a,&iter);
        char *key=NULL; plist_t value=NULL; int same=1;
        while (1) {
            plist_dict_next_item(a,iter,&key,&value);
            if (!key) break;
            same=p5_native_bb_same_query(value,plist_dict_get_item(b,key),depth+1);
            free(key); key=NULL;
            if (!same) break;
        }
        free(iter); return same;
    }
    if (PLIST_IS_ARRAY(a)) {
        uint32_t count=plist_array_get_size(a);
        if (count!=plist_array_get_size(b)) return 0;
        for(uint32_t i=0;i<count;i++)
            if(!p5_native_bb_same_query(plist_array_get_item(a,i),plist_array_get_item(b,i),depth+1))return 0;
        return 1;
    }
    return plist_compare_node_value(a,b);
}
static int p5_native_bb_query(struct idevicerestore_client_t *c, plist_t q)
{
    int n48 = !strcmp(c->device->hardware_model,"n48ap");
    plist_t id=c->restore->build_identity;
    if (!PLIST_IS_DICT(q) || c->restore->p5_bb_done ||
        c->restore->p5_bb_requests>=16 ||
        p5_bb_number(id,"ApChipID")!=0x8950 ||
        p5_bb_number(id,"ApBoardID")!=(n48?10:14) ||
        p5_bb_number(id,"BbChipID")!=0x6f20e1 ||
        p5_bb_number(q,"ChipID")!=0x6f20e1 ||
        !p5_bb_data(q,"ChipSerialNo",4) ||
        !PLIST_IS_UINT(plist_dict_get_item(q,"CertID"))) return -1;
    uint64_t cert=p5_bb_number(q,"CertID");
    if (cert>UINT32_MAX && cert<UINT64_C(0xffffffff80000000)) return -1;
    cert=(uint32_t)cert;
    plist_t nonce=plist_dict_get_item(q,"Nonce");
    if (nonce) {
        if (!p5_bb_data(q,"Nonce",20)) return -1;
        uint64_t n=0; const char *p=plist_get_data_ptr(nonce,&n); unsigned char any=0;
        for(uint64_t i=0;i<n;i++)any|=(unsigned char)p[i];
        if(!any)return -1;
    }
    plist_t old=c->restore->p5_bb_query;
    if(old && (p5_bb_number(old,"ChipID")!=p5_bb_number(q,"ChipID") ||
        (uint32_t)p5_bb_number(old,"CertID")!=cert ||
        !plist_compare_node_value(plist_dict_get_item(old,"ChipSerialNo"),plist_dict_get_item(q,"ChipSerialNo")))) return -1;
    /* Retain upstream's nonce-bound ticket across identical live queries.
     * Fresh TSS replies can carry different BBTicket signatures even for the
     * same nonce; do not replace the package authenticated by RestoreSBL1
     * while transitioning to the regular loader. Invalidate on any change,
     * including nonce appearance/removal, and discard any preflight cache. */
    if(!p5_native_bb_same_query(old,q,0) && c->restore->bbtss) {
        plist_free(c->restore->bbtss); c->restore->bbtss=NULL;
    }
    plist_free(c->restore->p5_bb_query); c->restore->p5_bb_query=plist_copy(q);
    c->restore->p5_bb_requests++;
    return 0;
}
static int p5_native_bb_evidence(struct idevicerestore_client_t *c,const char *suffix,plist_t value)
{
    const char *prefix=getenv("PROJECT5C_BB_SAVE");
    if(!prefix || !*prefix)return 0;
    char *path=NULL,*xml=NULL; uint32_t n=0;
    if(asprintf(&path,"%s-%02u.%s.plist",prefix,c->restore->p5_bb_requests,suffix)<0)return -1;
    plist_to_xml(value,&xml,&n);
    int result=xml?write_file(path,xml,n):-1;
    free(path); free(xml); return result;
}
static int p5_native_bb_options(struct idevicerestore_client_t *c,plist_t opts)
{
    if(!(c->flags & FLAG_PROJECT5C_BASEBAND))return 0;
    if(!p5_native_bb_active(c) || !build_identity_has_component(c->restore->build_identity,"BasebandFirmware"))return -1;
    if(c->tss_url && strcmp(c->tss_url,"https://gs.apple.com/TSS/controller?action=2"))return -1;
    if(!c->tss_url)c->tss_url=strdup("https://gs.apple.com/TSS/controller?action=2");
    plist_dict_set_item(opts,"UpdateBaseband",plist_new_bool(1));
    plist_dict_set_item(opts,"BasebandNVRestoreItems",plist_new_uint(3));
    plist_t bb=plist_new_dict();
    plist_dict_set_item(bb,"DisallowFusing",plist_new_bool(1));
    plist_dict_set_item(bb,"EraseEFS",plist_new_bool(0));
    plist_dict_set_item(bb,"NVRestoreSetting",plist_new_uint(3));
    plist_dict_set_item(opts,"BasebandUpdater",bb);
    logger_dump_plist(LL_DEBUG,opts,0);
    return p5_native_bb_evidence(c,"options",opts);
}
