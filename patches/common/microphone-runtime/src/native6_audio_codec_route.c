/* Temporary N49 record-route experiment; private RAM changes only.
 * Exact UUID and instruction guards. No CoreAudio result or sample synthesis.
 * Change Record_N41's internal-microphone transport from Voice to Codec and
 * omit the Voice-only pass-through setup on that Codec object.
 */
static void codec_route_patch(void *);
#define NATIVE6_AUDIO_ROUTE_PATCH 1
#include "native6_audio_route_trace.c"
extern int mprotect(void *,Size,int);
extern void sys_icache_invalidate(void *,Size);
static int codec_route_applied;
static void codec_route_patch(void *caller) {
 if(codec_route_applied||!pinned(caller))return;
 DlInfo info;if(!dladdr(caller,&info)||!info.base)return;
 unsigned char *base=info.base,*uid=base+0x18451e,*setup=base+0x1846f4;
 const unsigned char olduid[4]={0x4e,0xf6,0x7e,0x61};
 const unsigned char oldsetup[4]={0x17,0xf7,0x8a,0xf8};
 for(U32 i=0;i<4;i++)if(uid[i]!=olduid[i]||setup[i]!=oldsetup[i]){
  U32 result[1]={1};emit("AUDIO_CODEC_ROUTE_REJECT",result,1);return;
 }
 void *page=(void *)((Size)uid&~(Size)0xfff);
 int status=mprotect(page,0x1000,7);
 if(status){U32 result[1]={(U32)status};emit("AUDIO_CODEC_ROUTE_PROTECT",result,1);return;}
 /* MOVW r1,#ee2e + MOVT r1,#a + PC18452a = Codec CFString233358. */
 uid[2]=0x2e;
 setup[0]=0x00;setup[1]=0xbf;setup[2]=0x00;setup[3]=0xbf;
 sys_icache_invalidate(page,0x1000);
 status=mprotect(page,0x1000,5);codec_route_applied=1;
 U32 result[3]={(U32)(Size)base,(U32)status,0x18451e};emit("AUDIO_CODEC_ROUTE_APPLIED",result,3);
}
#ifdef NATIVE6_AUDIO_IO_TRACE
extern S32 AudioDeviceStart(U32,void *);
extern S32 AudioDeviceStop(U32,void *);
extern S32 AudioObjectGetPropertyData(U32,const Address *,U32,const void *,U32 *,void *);
static void io_state(const char *tag,U32 device,void *proc,S32 status) {
 Address running={0x676f696e,0x676c6f62,0};U32 value=0xffffffff,size=4;
 S32 get=AudioObjectGetPropertyData(device,&running,0,0,&size,&value);
 U32 values[6]={device,(U32)(Size)proc,(U32)status,(U32)get,size,value};emit(tag,values,6);
}
__attribute__((noinline)) static S32 device_start(U32 device,void *proc) {
 io_state("AUDIO_START_BEFORE",device,proc,0);
 S32 status=AudioDeviceStart(device,proc);io_state("AUDIO_START_AFTER",device,proc,status);return status;
}
__attribute__((noinline)) static S32 device_stop(U32 device,void *proc) {
 S32 status=AudioDeviceStop(device,proc);io_state("AUDIO_STOP_AFTER",device,proc,status);return status;
}
__attribute__((used,section("__DATA,__interpose")))
static const struct { const void *replacement;const void *original; } io_pairs[]={
 {(const void *)&device_start,(const void *)&AudioDeviceStart},
 {(const void *)&device_stop,(const void *)&AudioDeviceStop}};
#endif
#ifdef NATIVE6_AUDIO_KERNEL_TRACE
typedef unsigned long long U64;
extern S32 IOConnectCallMethod(U32,U32,const U64 *,U32,const void *,Size,U64 *,U32 *,void *,Size *);
extern S32 IOConnectCallScalarMethod(U32,U32,const U64 *,U32,U64 *,U32 *);
extern S32 IOConnectCallStructMethod(U32,U32,const void *,Size,void *,Size *);
#ifdef NATIVE6_AUDIO_TIMING_TRACE
extern S32 IOConnectMapMemory(U32,U32,U32,U32 *,U32 *,U32);
extern S32 IOConnectUnmapMemory(U32,U32,U32,U32);
static struct {U32 connection,address,size;} timing_maps[32];
#ifdef NATIVE6_AUDIO_BUFFER_TRACE
static struct {U32 connection,type,address,size;} buffer_maps[32];
static void buffer_state(const char *tag,U32 connection) {
 for(U32 i=0;i<32;i++)if(buffer_maps[i].connection==connection&&buffer_maps[i].address){
  U32 length=buffer_maps[i].size;if(length>65536)length=65536;
  volatile const unsigned char *data=(const unsigned char *)(Size)buffer_maps[i].address;
  U32 hash=2166136261u,nonzero=0;
  for(U32 j=0;j<length;j++){U32 value=data[j];hash=(hash^value)*16777619u;nonzero+=value!=0;}
  U32 values[7]={connection,buffer_maps[i].type,buffer_maps[i].address,buffer_maps[i].size,length,hash,nonzero};
  emit(tag,values,7);
 }
}
#endif
static void timing_state(const char *tag,U32 connection) {
 for(U32 i=0;i<32;i++)if(timing_maps[i].connection==connection&&timing_maps[i].address&&timing_maps[i].size>=40){
  U32 values[13]={connection,timing_maps[i].address,timing_maps[i].size};
  volatile const U32 *data=(const U32 *)(Size)timing_maps[i].address;
  for(U32 j=0;j<10;j++)values[3+j]=data[j];
  emit(tag,values,13);
 }
}
static S32 timing_map(U32 connection,U32 type,U32 task,U32 *address,U32 *size,U32 options) {
 S32 result=IOConnectMapMemory(connection,type,task,address,size,options);
#ifdef NATIVE6_AUDIO_BUFFER_TRACE
 if(!result&&address&&size&&*address&&*size){
  for(U32 i=0;i<32;i++)if(!buffer_maps[i].address){
   buffer_maps[i].connection=connection;buffer_maps[i].type=type;
   buffer_maps[i].address=*address;buffer_maps[i].size=*size;break;
  }
  buffer_state("AUDIO_BUFFER_MAP",connection);
 }
#endif
 if(!result&&!type&&address&&size&&*size>=40&&*address){
  for(U32 i=0;i<32;i++)if(!timing_maps[i].address){timing_maps[i].connection=connection;timing_maps[i].size=*size;timing_maps[i].address=*address;break;}
  timing_state("AUDIO_TIMING_MAP",connection);
 }
 return result;
}
static S32 timing_unmap(U32 connection,U32 type,U32 task,U32 address) {
#ifdef NATIVE6_AUDIO_BUFFER_TRACE
 for(U32 i=0;i<32;i++)if(buffer_maps[i].connection==connection&&buffer_maps[i].address==address)buffer_maps[i].address=0;
#endif
 for(U32 i=0;i<32;i++)if(timing_maps[i].connection==connection&&timing_maps[i].address==address)timing_maps[i].address=0;
 return IOConnectUnmapMemory(connection,type,task,address);
}
__attribute__((used,section("__DATA,__interpose")))
static const struct {const void *replacement;const void *original;} timing_pairs[]={
 {(const void *)&timing_map,(const void *)&IOConnectMapMemory},
 {(const void *)&timing_unmap,(const void *)&IOConnectUnmapMemory}};
#endif
static void kernel_result(const char *tag,U32 connection,U32 selector,S32 status,const U64 *input,U32 count) {
 U32 values[12]={connection,selector,(U32)status,count};
 for(U32 i=0;i<4;i++){values[4+2*i]=input&&count>i?(U32)input[i]:0;values[5+2*i]=input&&count>i?(U32)(input[i]>>32):0;}
 emit(tag,values,12);
}
static S32 kernel_method(U32 c,U32 s,const U64 *i,U32 n,const void *si,Size sn,U64 *o,U32 *on,void *so,Size *son) {
#ifdef NATIVE6_AUDIO_TIMING_TRACE
 if(s<=1)timing_state(s?"AUDIO_TIMING_BEFORE_STOP":"AUDIO_TIMING_BEFORE_START",c);
#ifdef NATIVE6_AUDIO_BUFFER_TRACE
 if(s<=1)buffer_state(s?"AUDIO_BUFFER_BEFORE_STOP":"AUDIO_BUFFER_BEFORE_START",c);
#endif
#endif
 S32 result=IOConnectCallMethod(c,s,i,n,si,sn,o,on,so,son);kernel_result("AUDIO_KERNEL_METHOD",c,s,result,i,n);return result;
}
static S32 kernel_scalar(U32 c,U32 s,const U64 *i,U32 n,U64 *o,U32 *on) {
 S32 result=IOConnectCallScalarMethod(c,s,i,n,o,on);kernel_result("AUDIO_KERNEL_SCALAR",c,s,result,i,n);return result;
}
static S32 kernel_struct(U32 c,U32 s,const void *i,Size n,void *o,Size *on) {
 S32 result=IOConnectCallStructMethod(c,s,i,n,o,on);kernel_result("AUDIO_KERNEL_STRUCT",c,s,result,0,0);return result;
}
__attribute__((used,section("__DATA,__interpose")))
static const struct {const void *replacement;const void *original;} kernel_pairs[]={
 {(const void *)&kernel_method,(const void *)&IOConnectCallMethod},
 {(const void *)&kernel_scalar,(const void *)&IOConnectCallScalarMethod},
 {(const void *)&kernel_struct,(const void *)&IOConnectCallStructMethod}};
#endif
