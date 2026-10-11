/* Temporary N48 process-local USB PID repair; no shared-cache file writes. */
typedef unsigned int u32;
extern const u32 *TelephonyCapabilitiesGetHardwareModel(void);
extern void TelephonyCapabilitiesSetHardwareModel(const u32 *);
extern int TelephonyRadiosDetermineRadio(const u32 *);
extern int TelephonyCapabilitiesRadioIPCGetNumQMIInstances(void);
extern int TelephonyCapabilitiesRadioHSICGetBootedProductID(void);
extern int TelephonyCapabilitiesRadioIPCGetQMIHSICInterfaceNum(const char *);
extern long write(int,const void*,unsigned long);
extern int vm_protect(u32,u32,u32,int,int);
extern u32 mach_task_self_;
extern void sys_icache_invalidate(void *,unsigned long);
extern void _exit(int) __attribute__((noreturn));
static void note(const char *s) { unsigned long n=0;while(s[n])++n;write(2,s,n); }
static void fail(const char *s) {note(s);_exit(78);}
__attribute__((constructor)) static void initialize(void) {
 const u32 *old=TelephonyCapabilitiesGetHardwareModel();
 if (!old || old[0]!=48 || (old[1]&255)!='N')
  fail("Project5C: HSIC N48 model guard failed\n");
 volatile unsigned char *p=(void *)((u32)&TelephonyCapabilitiesRadioHSICGetBootedProductID & ~1U);
 static const unsigned char expected[]={0x80,0xb5,0x6f,0x46,0xff,0xf7,0x9e,0xfd,0x01,0x46,0x49,0xf2,0x01,0x00,0x8a,0x1e,0x02,0x2a,0x02,0xd3,0x06,0x29,0x01,0xd0,0x00,0x20,0x80,0xbd,0x49,0xf2,0x34,0x00,0x80,0xbd};
 for(u32 i=0;i<sizeof(expected);++i)
  if(p[i]!=expected[i])fail("Project5C: HSIC original code guard failed\n");
 u32 page=(u32)p & ~4095U;
 /* VM_PROT_COPY requests a private copy of the shared-cache mapping. */
 if(vm_protect(mach_task_self_,page,4096,0,1|2|16))
  fail("Project5C: HSIC private writable mapping failed\n");
 p[30]=0x33;
 if(vm_protect(mach_task_self_,page,4096,0,1|4))
  fail("Project5C: HSIC executable protection restore failed\n");
 sys_icache_invalidate((void *)p,34);
 const u32 profile[3]={42,'N',3};
 TelephonyCapabilitiesSetHardwareModel(profile);
 if(TelephonyRadiosDetermineRadio(profile)!=6 || TelephonyCapabilitiesRadioIPCGetNumQMIInstances()!=6 || TelephonyCapabilitiesRadioHSICGetBootedProductID()!=0x9033)
  fail("Project5C: HSIC post-patch capability check failed\n");
 const char *names[]={"qmux1","qmux2","qmux3","qmux4","qmux5","loc"};
 const int expected_if[]={3,5,7,9,-1,11};
 for(u32 i=0;i<6;++i)
  if(TelephonyCapabilitiesRadioIPCGetQMIHSICInterfaceNum(names[i])!=expected_if[i])
   fail("Project5C: HSIC QMI interface guard failed\n");
 note("Project5C: HSIC private PID 9034 -> 9033 verified; QMI=6 interfaces=3,5,7,9,-1,11\n");
}
