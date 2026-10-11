/* iOS 6.1.3 SpringBoard compatibility for repeated disconnected CT updates.
 * All original telephony updates still execute. Only their redundant idle reset
 * while both the previous and current displayed-call states are empty is omitted.
 */
extern void *dlopen(const char*,int),*dlsym(void*,const char*);
extern int printf(const char*,...),fflush(void*);
static void (*update_original)(void*,void*),(*reset_original)(void*,void*);
static void *(*displayed_call)(void*);
static unsigned long slide;static int previous_has_call,suppress_reset;static unsigned skipped;
static void update_hook(void*self,void*sel){int has_call=displayed_call(0)!=0;int prior_suppress=suppress_reset;suppress_reset=!previous_has_call&&!has_call;previous_has_call=has_call;update_original(self,sel);suppress_reset=prior_suppress;}
static void reset_hook(void*self,void*sel){unsigned long caller=(unsigned long)__builtin_return_address(0);if(suppress_reset&&caller==slide+0x50915){if(skipped++<8){printf("AUTOLOCK omitted redundant no-call telephony idle reset\n");fflush(0);}return;}reset_original(self,sel);}
__attribute__((constructor)) static void initialize(void){void*l=dlopen("/usr/lib/libobjc.A.dylib",1);void*(*cls)(const char*)=dlsym(l,"objc_getClass");void*(*sel)(const char*)=dlsym(l,"sel_registerName");void*(*method)(void*,void*)=dlsym(l,"class_getInstanceMethod");void*(*set)(void*,void*)=dlsym(l,"method_setImplementation");void*(*implementation)(void*)=dlsym(l,"method_getImplementation");void*s=dlopen("/usr/lib/libSystem.B.dylib",1);unsigned long(*getslide)(unsigned)=dlsym(s,"_dyld_get_image_vmaddr_slide");displayed_call=dlsym((void*)-2,"TPGetDisplayedCallFromCalls");void*u=method(cls("SBTelephonyManager"),sel("updateSpringBoard"));void*r=method(cls("SpringBoard"),sel("resetIdleTimerAndUndim"));if(!u||!r||!displayed_call||!getslide){printf("AUTOLOCK inactive: required methods or symbol unavailable\n");fflush(0);return;}slide=getslide(0);if((unsigned long)implementation(u)!=slide+0x50821||(unsigned long)implementation(r)!=slide+0xe5bd){printf("AUTOLOCK inactive: unsupported SpringBoard implementation\n");fflush(0);return;}previous_has_call=0;reset_original=set(r,(void*)reset_hook);update_original=set(u,(void*)update_hook);printf("AUTOLOCK installed slide=%lx\n",slide);fflush(0);}
