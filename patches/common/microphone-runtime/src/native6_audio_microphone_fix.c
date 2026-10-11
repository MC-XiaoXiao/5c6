/* N49 / 10B329 VirtualAudio Codec route and CS81 I2S master clock repair.
 * Original IOKit calls and samples are preserved. All register access goes
 * through the real CS81 driver; no MMIO or synthesized CoreAudio results.
 */
#define NATIVE6_AUDIO_CONTROL_OVERRIDE 1
#include "native6_audio_codec_route.c"
typedef unsigned long long U64;
extern void *dlopen(const char *,int);
extern void *dlsym(void *,const char *);
extern S32 IOConnectCallMethod(U32,U32,const U64 *,U32,const void *,Size,U64 *,U32 *,void *,Size *);
extern S32 IOServiceOpen(U32,U32,U32,U32 *);
extern S32 IOServiceClose(U32);
static struct {U32 connection,device;} connections[32];
static volatile U32 connection_lock;
static void lock_connections(void){while(__sync_lock_test_and_set(&connection_lock,1)){} }
static void unlock_connections(void){__sync_lock_release(&connection_lock);}
static void *io_library(void){static void *handle;if(!handle)handle=dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",1);return handle;}
static void *cf_library(void){static void *handle;if(!handle)handle=dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",1);return handle;}
static void master_clock(U32 connection) {
 if(!codec_route_applied)return;
 void *io=io_library();
 void *cf=cf_library();
 if(!io||!cf)return;
 S32 (*getservice)(U32,U32 *),(*parent)(U32,const char *,U32 *),(*iorelease)(U32),(*ioretain)(U32),(*setprops)(U32,void *);
 unsigned char (*cfequal)(void *,void *),(*conforms)(U32,const char *),(*number)(void *,int,void *);
 void *(*string)(void *,const char *,U32),*(*property)(U32,void *,void *,U32),*(*at)(void *,long),*(*data)(void *,const unsigned char *,long),*(*parse)(void *,void *,int,void **);
 long (*count)(void *),(*length)(void *);
 U32 (*type)(void *),(*arraytype)(void),(*numbertype)(void),(*datatype)(void);
 const unsigned char *(*bytes)(void *);
 void (*release)(void *);
 #define LOAD(h,f,n) do {*(void **)(&f)=dlsym(h,n);if(!f){emit(n,0,0);return;}}while(0)
 LOAD(io,getservice,"IOConnectGetService");LOAD(io,parent,"IORegistryEntryGetParentEntry");
 LOAD(io,iorelease,"IOObjectRelease");LOAD(io,ioretain,"IOObjectRetain");LOAD(cf,cfequal,"CFEqual");LOAD(io,conforms,"IOObjectConformsTo");
 LOAD(io,property,"IORegistryEntryCreateCFProperty");LOAD(io,setprops,"IORegistryEntrySetCFProperties");
 LOAD(cf,string,"CFStringCreateWithCString");LOAD(cf,at,"CFArrayGetValueAtIndex");
 LOAD(cf,count,"CFArrayGetCount");LOAD(cf,number,"CFNumberGetValue");
 LOAD(cf,type,"CFGetTypeID");LOAD(cf,arraytype,"CFArrayGetTypeID");
 LOAD(cf,numbertype,"CFNumberGetTypeID");LOAD(cf,datatype,"CFDataGetTypeID");
 LOAD(cf,bytes,"CFDataGetBytePtr");LOAD(cf,length,"CFDataGetLength");
 LOAD(cf,data,"CFDataCreate");LOAD(cf,parse,"CFPropertyListCreateFromXMLData");LOAD(cf,release,"CFRelease");
 #undef LOAD
 U32 device=0,codec=0;void *key=0,*value=0,*xml=0,*dict=0,*error=0,*uidkey=0,*uid=0,*wanted=0;
 U32 before=0xffffffff,after=0xffffffff;S32 status=-1;
 S32 gs=getservice(connection,&device);
 if(gs||!device){
  device=0;lock_connections();
  for(U32 j=0;j<32;j++)if(connections[j].connection==connection){if(!ioretain(connections[j].device))device=connections[j].device;break;}
  unlock_connections();
 }
 if(!device)return;
 if(!conforms(device,"AppleEmbeddedAudioDevice"))goto done;
 uidkey=string(0,"device UID",0x08000100);wanted=string(0,"Codec",0x08000100);
 if(!uidkey||!wanted)goto done;
 uid=property(device,uidkey,0,0);if(!uid||!cfequal(uid,wanted))goto done;
 S32 pg=parent(device,"IOService",&codec);
 if(pg||!codec||!conforms(codec,"AppleCS42L81Audio"))goto done;
 key=string(0,"CodecRegisterData",0x08000100);if(!key)goto done;
 value=property(codec,key,0,0);
 if(!value||type(value)!=arraytype())goto done;
 long n=count(value);if(n<2||n>64||(n&1))goto done;
 for(long i=0;i<n;i+=2){
  void *base=at(value,i),*region=at(value,i+1);S32 start=-1;
  if(type(base)!=numbertype()||type(region)!=datatype()||!number(base,3,&start))goto done;
  long size=length(region);
  if(start>=0&&start<=15&&size>15-start){before=bytes(region)[15-start];break;}
 }
 /* Verified native6 44.1/48 kHz values. Never alter rate or unrelated bits. */
 if(before!=10&&before!=12&&before!=138&&before!=140)goto report;
 if(before&128){status=0;after=before;goto report;}
 #define XML(v) "<plist version=\"1.0\"><dict><key>CodecRegisterData</key><array><array><integer>15</integer><integer>" #v "</integer></array></array></dict></plist>"
 const char *text=before==10?XML(138):XML(140);U32 size=0;while(text[size])size++;
 xml=data(0,(const unsigned char *)text,size);if(!xml)goto report;
 dict=parse(0,xml,0,&error);if(!dict)goto report;
 status=setprops(codec,dict);
 release(value);value=property(codec,key,0,0);
 if(value&&type(value)==arraytype()){
  n=count(value);if(n>=2&&n<=64&&!(n&1))for(long i=0;i<n;i+=2){
   void *base=at(value,i),*region=at(value,i+1);S32 start=-1;
   if(type(base)==numbertype()&&type(region)==datatype()&&number(base,3,&start)&&start>=0&&start<=15&&length(region)>15-start){after=bytes(region)[15-start];break;}
  }
 }
 report:;
 U32 values[4]={connection,before,after,(U32)status};emit("AUDIO_CS81_MASTER_CLOCK",values,4);
 done:
 if(uid)release(uid);if(uidkey)release(uidkey);if(wanted)release(wanted);
 if(error)release(error);if(dict)release(dict);if(xml)release(xml);
 if(value)release(value);if(key)release(key);if(codec)iorelease(codec);iorelease(device);
}
static S32 microphone_method(U32 c,U32 s,const U64 *i,U32 n,const void *si,Size sn,U64 *o,U32 *on,void *so,Size *son) {
 S32 result=IOConnectCallMethod(c,s,i,n,si,sn,o,on,so,son);
 int saved=*__error();if(!result&&!s)master_clock(c);*__error()=saved;return result;
}
__attribute__((used,section("__DATA,__interpose")))
static const struct {const void *replacement;const void *original;} microphone_pair={
 (const void *)&microphone_method,(const void *)&IOConnectCallMethod};

extern S32 IOConnectCallScalarMethod(U32,U32,const U64 *,U32,U64 *,U32 *);
extern S32 IOConnectCallStructMethod(U32,U32,const void *,Size,void *,Size *);
static S32 microphone_scalar(U32 c,U32 s,const U64 *i,U32 n,U64 *o,U32 *on) {
 S32 result=IOConnectCallScalarMethod(c,s,i,n,o,on);
 int saved=*__error();if(!result&&!s)master_clock(c);*__error()=saved;return result;
}
static S32 microphone_struct(U32 c,U32 s,const void *i,Size n,void *o,Size *on) {
 S32 result=IOConnectCallStructMethod(c,s,i,n,o,on);
 int saved=*__error();if(!result&&!s)master_clock(c);*__error()=saved;return result;
}
__attribute__((used,section("__DATA,__interpose")))
static const struct {const void *replacement;const void *original;} microphone_pairs[]={
 {(const void *)&microphone_scalar,(const void *)&IOConnectCallScalarMethod},
 {(const void *)&microphone_struct,(const void *)&IOConnectCallStructMethod}};

static S32 microphone_open(U32 service,U32 task,U32 kind,U32 *connection) {
 S32 result=IOServiceOpen(service,task,kind,connection);int saved=*__error();
 if(!result&&connection&&*connection){
  void *io=io_library();
  S32 (*retain)(U32)=io?dlsym(io,"IOObjectRetain"):0;
  unsigned char (*conforms)(U32,const char *)=io?dlsym(io,"IOObjectConformsTo"):0;
  if(retain&&conforms&&conforms(service,"AppleEmbeddedAudioDevice")){
   lock_connections();
   for(U32 j=0;j<32;j++)if(!connections[j].connection){
    if(!retain(service)){connections[j].device=service;connections[j].connection=*connection;}break;
   }
   unlock_connections();
  }
 }
 *__error()=saved;return result;
}
static S32 microphone_close(U32 connection) {
 S32 result=IOServiceClose(connection);int saved=*__error();
 U32 device=0;
 if(!result){lock_connections();for(U32 j=0;j<32;j++)if(connections[j].connection==connection){
  device=connections[j].device;connections[j].connection=0;connections[j].device=0;break;
 }
 unlock_connections();}
 if(device){void *io=io_library();S32 (*release)(U32)=io?dlsym(io,"IOObjectRelease"):0;if(release)release(device);}
 *__error()=saved;return result;
}
__attribute__((used,section("__DATA,__interpose")))
static const struct {const void *replacement;const void *original;} service_pairs[]={
 {(const void *)&microphone_open,(const void *)&IOServiceOpen},
 {(const void *)&microphone_close,(const void *)&IOServiceClose}};
