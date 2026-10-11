/* Temporary diagnostics with real property setters and converters preserved. */
#include "native6_audio_model_alias.c"
typedef signed int S32;
typedef struct { U32 selector,scope,element; } Address;
typedef struct { double rate; U32 format,flags,packet,frames,frame,channels,bits,reserved; } ASBD;
extern S32 AudioObjectSetPropertyData(U32,const Address *,U32,const void *,U32,const void *);
extern S32 AudioConverterNew(const ASBD *,const ASBD *,void **);
extern int *__error(void);
static char *word(char *p,U32 value) {
 static const char digits[]="0123456789abcdef";
 *p++=' ';
 for(int i=7;i>=0;i--)*p++=digits[(value>>(i*4))&15];
 return p;
}
static void emit(const char *tag,const U32 *values,U32 count) {
 int saved=*__error();char text[512],*p=text;
 while(*tag)*p++=*tag++;
 for(U32 i=0;i<count;i++)p=word(p,values[i]);
 *p++='\n';write(2,text,(unsigned int)(p-text));*__error()=saved;
}
#ifndef NATIVE6_AUDIO_CONTROL_OVERRIDE
__attribute__((noinline)) static S32 property(U32 device,const Address *address,U32 qsize,const void *qualifier,U32 size,const void *data) {
 int trace=address&&pinned(__builtin_return_address(0));
 U32 values[16];
 if(trace){
  values[0]=device;values[1]=address->selector;values[2]=address->scope;values[3]=address->element;
  values[4]=qsize;values[5]=size;
  for(U32 i=0;i<8;i++)values[6+i]=data&&size>=(i+1)*4?((const U32 *)data)[i]:0;
 }
 S32 result=AudioObjectSetPropertyData(device,address,qsize,qualifier,size,data);
 if(trace){values[14]=(U32)result;emit("AUDIO_PROP",values,15);}
 return result;
}
#endif
__attribute__((noinline)) static S32 converter(const ASBD *input,const ASBD *output,void **result) {
 S32 status=AudioConverterNew(input,output,result);
 if(status&&input&&output){
  U32 values[21];values[0]=(U32)status;
  for(U32 i=0;i<10;i++){values[1+i]=((const U32 *)input)[i];values[11+i]=((const U32 *)output)[i];}
  emit("AUDIO_CONVERTER_FAIL",values,21);
 }
 return status;
}
#ifndef NATIVE6_AUDIO_CONTROL_OVERRIDE
__attribute__((used,section("__DATA,__interpose")))
static const struct { const void *replacement;const void *original; } property_pair={
 (const void *)&property,(const void *)&AudioObjectSetPropertyData};
#endif
__attribute__((used,section("__DATA,__interpose")))
static const struct { const void *replacement;const void *original; } converter_pair={
 (const void *)&converter,(const void *)&AudioConverterNew};
