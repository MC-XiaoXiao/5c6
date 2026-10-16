/* iOS 6 native restored compatibility, without a standalone restore/update flow.
 * The stock libBBUpdater-128 has no N48/N49 profile. Its N42 flashless MDM9615
 * transport can drive Mav7 after the pinned executable's PID/path adaptation.
 * This changes TelephonyCapabilities' transport profile, not device identity. */
typedef unsigned long size_type;
static const char *factory_status="not called";
static void (*diagnostic_sink)(const char *,int);
static int profile_result=-1, radio_vendor=-1;
extern "C" void project5c_native_set_diagnostic_sink(void (*sink)(const char *,int)) { diagnostic_sink=sink; }
static void trace(const char *phase,int value=0) {
    factory_status=phase;
    if(diagnostic_sink)diagnostic_sink(phase,value);
}
extern "C" const char *project5c_native_factory_status(void) { return factory_status; }
extern "C" {
extern int sysctlbyname(const char *, void *, size_type *, void *, size_type);
extern int strcmp(const char *, const char *);
extern int memcmp(const void *,const void *,size_type);
extern void *dlsym(void *, const char *);
extern const void *IOServiceMatching(const char *);
extern unsigned IOServiceGetMatchingService(unsigned,const void *);
extern int IOObjectRelease(unsigned);
}
__attribute__((constructor)) static void initialize_profile(void)
{
    char board[32]={0}; size_type size=sizeof(board);
    if(sysctlbyname("hw.model",board,&size,0,0) ||
        (strcmp(board,"N48AP") && strcmp(board,"N49AP")))return;
    int (*set)(const char *)=(int (*)(const char *))dlsym((void *)-2,"TelephonyCapabilitiesSetHardwareModelFromString");
    int (*vendor)(void)=(int (*)(void))dlsym((void *)-2,"TelephonyRadiosGetRadioVendor");
    if(set && vendor) {
        const void *(*get_model)(void)=(const void *(*)(void))dlsym((void *)-2,"TelephonyCapabilitiesGetHardwareModel");
        if(!get_model)return;
        /* Model and radio caches use separate dispatch_once tokens. Prime the
         * model token before replacing it, then refresh the original radio
         * mapping after the executable's constructors have initialized it. */
        get_model();
        profile_result=set("N42AP");
        radio_vendor=vendor();
        unsigned long slide=((unsigned long)set&~1UL)-0x871c4;
        const unsigned char pre[]={0x80,0xb5,0x6f,0x46,0x00,0xf0,0x1c,0xf8};
        if(profile_result==1 && !memcmp((const void *)(slide+0x871b4),pre,sizeof(pre))) {
            void (*refresh)(void *)=(void (*)(void *))(slide+0x871b5);
            refresh(0);
            radio_vendor=vendor();
        }
    }
}
extern "C" __attribute__((visibility("default"))) void *project5c_native_factory(void)
{
    typedef void (*log_fn)(const char *,...);
    log_fn log=(log_fn)dlsym((void *)-2,"ramrod_log_msg");
    trace("factory entered");
    initialize_profile();
    trace("legacy profile setter result",profile_result);
    trace("radio vendor",radio_vendor);
    trace("checking AppleBaseband service");
    unsigned service=IOServiceGetMatchingService(0,IOServiceMatching("AppleBaseband"));
    if(!service) {
        trace("AppleBaseband service absent");
        if(log && !diagnostic_sink)log("Project5C: native factory: AppleBaseband service is absent\n");
        return 0;
    }
    IOObjectRelease(service);
    trace("AppleBaseband service found",1);
    if(log && !diagnostic_sink)log("Project5C: native factory: AppleBaseband service found\n");
    trace(diagnostic_sink?"preflight logger bypassed":"native logger returned");
    unsigned long anchor=(unsigned long)dlsym((void *)-2,"_ZN21BBUpdaterPersonalizedC1EPKvmPKc");
    if(!anchor) { trace("constructor anchor missing"); return 0; }
    /* The pinned factory calls __assert_rtn for every other vendor value.
     * Report that condition rather than entering an unconditional abort. */
    if(radio_vendor!=1 && radio_vendor!=2) {
        trace("radio vendor rejected before original factory assertion",radio_vendor);
        return 0;
    }
    unsigned long slide=(anchor&~1UL)-0x5b448;
    typedef void *(*factory_fn)(const unsigned *);
    factory_fn factory=(factory_fn)(slide+0x1decd);
    const unsigned params[4]={2989,~0U,0,0};
    trace("entering original WithParameters factory");
    try {
        void *result=factory(params);
        trace(result?"original factory created updater":"original factory returned NULL");
        if(log && !diagnostic_sink)log("Project5C: native factory returned %s\n",result?"an updater":"NULL");
        return result;
    } catch(...) {
        trace("original factory raised C++ exception");
        if(log && !diagnostic_sink)log("Project5C: original BBUpdater factory raised a C++ exception; controller initialization failed\n");
        return 0;
    }
}
extern "C" int project5c_native_requires_filesystem(void **error)
{
    typedef int (*requires_fn)(void **);
    requires_fn requires=(requires_fn)dlsym((void *)-2,"ramrod_baseband_update_requires_system_filesystem");
    if(!requires)return -2;
    try { return requires(error); }
    catch(...) { trace("requires-system-filesystem raised C++ exception"); return -1; }
}
