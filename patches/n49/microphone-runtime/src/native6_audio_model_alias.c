/* Process-private, instruction-feature guarded VirtualAudio model alias for N49.
 * Preserve syscall result, buffer size, all other callers, and system identity.
 */
typedef unsigned int U32;
typedef unsigned long Size;
typedef struct { const char *name; void *base; const char *symbol; void *address; } DlInfo;
extern int sysctlbyname(const char *,void *,Size *,const void *,Size);
extern int dladdr(const void *,DlInfo *);
extern int write(int,const void *,unsigned int);
static int equal(const char *a,const char *b) {
 if(!a||!b)return 0;
 while(*a&&*a==*b){a++;b++;}
 return *a==*b;
}
#include "audio_features.h"
static int feature_equal(const unsigned char *p,const unsigned char *a,const unsigned char *b,U32 n) {
 int old=1,patched=1;
 for(U32 i=0;i<n;i++){if(p[i]!=a[i])old=0;if(p[i]!=b[i])patched=0;}
 return old||patched;
}
static int audio_feature_image(const unsigned char *base,U32 textsize,int unique) {
 if(textsize<0x1846f4+32||textsize>0x800000)return 0;
 if(!feature_equal(base+0x18451e,audio_uid_before,audio_uid_after,32)||
    !feature_equal(base+0x1846f4,audio_setup_before,audio_setup_after,32))return 0;
 if(unique){
  U32 u=0,s=0;
  for(U32 i=0;i+32<=textsize;i++){
   if(feature_equal(base+i,audio_uid_before,audio_uid_after,32))u++;
   if(feature_equal(base+i,audio_setup_before,audio_setup_after,32))s++;
   if(u>1||s>1)return 0;
  }
  if(u!=1||s!=1)return 0;
 }
 return 1;
}
static int pinned(void *caller) {
 static void *validated_base;
 DlInfo info;if(!dladdr(caller,&info)||!info.base||!equal(info.name,"/Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin/VirtualAudio"))return 0;
 const U32 *header=info.base;
 if(header[0]!=0xfeedface||header[4]>100||header[5]>0x10000)return 0;
 const unsigned char *command=(const unsigned char *)header+28;U32 remaining=header[5],textsize=0;
 for(U32 i=0;i<header[4];i++){
  if(remaining<8)return 0;
  U32 kind=((const U32 *)command)[0],size=((const U32 *)command)[1];
  if(size<8||size>remaining)return 0;
  if(kind==1&&size>=56&&equal((const char *)command+8,"__TEXT")){
   const U32 *segment=(const U32 *)command;
   if(segment[6]!=0||segment[8]!=0)return 0;
   textsize=segment[9];
  }
  remaining-=size;command+=size;
 }
 if(!audio_feature_image(info.base,textsize,validated_base!=info.base))return 0;
 validated_base=info.base;return 1;
}
__attribute__((noinline)) static int audio_sysctlbyname(const char *name,void *old,Size *length,const void *newvalue,Size newlength) {
 void *caller=__builtin_return_address(0);
 Size capacity=length?*length:0;
 int result=sysctlbyname(name,old,length,newvalue,newlength);
 if(!result&&!newvalue&&!newlength&&equal(name,"hw.model")&&old&&length&&capacity>=6&&*length==6&&pinned(caller)){
  char *model=old;
  if(equal(model,"N49AP")){
#ifdef NATIVE6_AUDIO_ROUTE_PATCH
   codec_route_patch(caller);
#endif
   model[2]='2';
   static const char message[]="AUDIO_MODEL_ALIAS VirtualAudio N49AP -> N42AP\n";
   write(2,message,sizeof(message)-1);
  }
 }
 return result;
}
__attribute__((used,section("__DATA,__interpose")))
static const struct { const void *replacement;const void *original; } pair={
 (const void *)&audio_sysctlbyname,(const void *)&sysctlbyname};
