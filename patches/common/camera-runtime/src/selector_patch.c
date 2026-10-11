extern void*dlopen(const char*,int);extern void*dlsym(void*,const char*);extern int printf(const char*,...);
#include "profile.h"
typedef unsigned int u32;
static unsigned char blob[0x578c];static u32 loaded;
static void(*original)(void*,u32,u32,u32,u32,void*);
static void*select_sensor(u32*out,u32 sensor,u32 rev,u32 supplier,u32 platform,void*nvm){
 if(sensor==0x9762&&loaded&&rev==0x20){out[0]=(u32)blob;out[1]=sizeof(blob);out[2]=0;printf("CAMERA OV9762 setfile 7652 len=%u\n",sizeof(blob));}
 else original(out,sensor,rev,supplier,platform,nvm);
 return out;
}
#include "profile-original.h"
static int equal(volatile unsigned char*p,const unsigned char*q,u32 n){for(u32 i=0;i<n;i++)if(p[i]!=q[i])return 0;return 1;}
__attribute__((constructor))static void patch(void){
 void*h=dlopen("/System/Library/MediaCapture/H4ISP.mediacapture",2),*sy=dlopen("/usr/lib/libSystem.dylib",2);
 if(!h||!sy)return;
 original=dlsym(h,"_ZN5H4ISP20H4ISPSetfileSelectorC2EtjjjPh");u32 f=(u32)dlsym(h,"_ZN5H4ISP20H4ISPSetfileSelectorC1EtjjjPh")&~1u;
 if(!original||!f)return;
 u32 slide=f-0x33576850;volatile unsigned char*p=(void*)f,*wl=(void*)(0x33561cb2+slide),*model=(void*)(0x3356207c+slide),*table=(void*)(0x33584f80+slide);
 static const unsigned char expected[]={0x90,0xb5,0x01,0xaf,0x82,0xb0,0xd7,0xf8},cmp[]={0x49,0xf2,0x60,0x71};
 if(!equal(p,expected,8)||!equal(wl,cmp,4)||!equal(model,cmp,4)||!equal(table,original_profile,sizeof(original_profile))){printf("CAMERA patch guard failed; unsupported capture image\n");return;}
 void*(*op)(const char*,const char*)=dlsym(sy,"fopen");u32(*rd)(void*,u32,u32,void*)=dlsym(sy,"fread");int(*cl)(void*)=dlsym(sy,"fclose");
 void*file=op("/usr/local/share/firmware/isp/7652_01XX.dat","rb");if(!file)return;u32 nr=rd(blob,1,sizeof(blob),file);cl(file);if(nr!=sizeof(blob)||blob[0]!=0x76||blob[1]!=0x52)return;
 int(*protect)(u32,u32,u32,int,int)=dlsym(sy,"vm_protect");u32*task=dlsym(sy,"mach_task_self_");void(*flush)(void*,u32)=dlsym(sy,"sys_icache_invalidate");
 u32 pages[]={f&~4095u,(u32)wl&~4095u,(u32)model&~4095u,(u32)table&~4095u};u32 sizes[]={4096,4096,4096,8192};
 for(u32 i=0;i<4;i++)if(protect(*task,pages[i],sizes[i],0,i==3?0x13:0x17)){for(u32 j=0;j<i;j++)protect(*task,pages[j],sizes[j],0,j==3?1:5);return;}
 wl[2]=0x62;model[2]=0x62;for(u32 i=0;i<sizeof(profile);i++)table[i]=profile[i];
 loaded=1;*(u32*)f=0xf000f8df;*(u32*)(f+4)=(u32)select_sensor;
 flush((void*)f,8);flush((void*)wl,4);flush((void*)model,4);
 for(u32 i=0;i<4;i++)protect(*task,pages[i],sizes[i],0,i==3?1:5);
 printf("CAMERA OV9762 compatibility enabled\n");
}
