#include "../../probe/native_hook.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
static const unsigned char prologue[] = {0x55,0x48,0x89,0xe5,0x41,0x57,0x41,0x56,0x41,0x55,0x41,0x54,0x53,0x48,0x83,0xec,0x18};
typedef uint64_t (*Function)(void *, int, uint32_t, int, int, uint8_t, int, const void *);
extern uint64_t probe_fixture(void *, int, uint32_t, int, int, uint8_t, int, const void *);
static Function original;
static unsigned original_calls, observed;
uint64_t fixture_body(void *self,int a,uint32_t b,int c,int d,uint8_t e,int f,const void *info) {
 assert(self==(void*)0x1234 && a==-3 && b==4000000000u && c==250 && d==7 && e==1 && f==9 && info==(void*)0x5678);
 ++original_calls; return 0xabcdef0123456789ULL;
}
static uint64_t wrapper(void *self,int a,uint32_t b,int c,int d,uint8_t e,int f,const void *info) {
 ++observed; return original(self,a,b,c,d,e,f,info);
}
void notify_fixture_body(void) {}
static void (*hp_audit_original)(void *,int,const void *);
extern void hp_assignment_fixture(void *,int,const void *);
static unsigned hp_audit_calls;
static int hp_before;
static unsigned char hp_object[0x300];
static void hp_callback(void *self,const void *info) {
 assert(self==hp_object && info==(void*)0x6789);++hp_audit_calls;
}
static void hp_audit_wrapper(void *self,int value,const void *info) {
 memcpy(&hp_before,(unsigned char*)self+0x20c,sizeof hp_before);
 hp_audit_original(self,value,info);
}
static void hp_assignment_test(void) {
 const unsigned char bytes[]={0x55,0x48,0x89,0xe5,0x89,0xb7,0x0c,0x02,0,0,0x48,0x8b,0x07,0x48,0x8b,0x88,0xa8,0x09,0,0};
 unsigned char table[0x9b8]={0};void *table_pointer=table,*callback=(void*)hp_callback,*info=(void*)0x6789;
 memcpy(hp_object,&table_pointer,sizeof table_pointer);
 memcpy(table+0x9a8,&callback,sizeof callback);memcpy(table+0x9b0,&info,sizeof info);
 int initial=1000;memcpy(hp_object+0x20c,&initial,sizeof initial);
 NativeHook h={0};
 assert(native_hook_install(&h,(void*)hp_assignment_fixture,(void*)hp_audit_wrapper,bytes,sizeof bytes,(void**)&hp_audit_original)==HOOK_OK);
 hp_assignment_fixture(hp_object,805,(void*)0x5678);
 int after;memcpy(&after,hp_object+0x20c,sizeof after);
 assert(hp_before==1000 && after==805 && hp_audit_calls==1);
 assert(native_hook_remove(&h)==HOOK_OK);
 puts("Audited HP assignment trampoline: field write and virtual callback preserved");
}
extern void death_audit_fixture(void *,void *,const void *);
static void (*death_audit_original)(void *,void *,const void *);
static unsigned death_audit_calls;
void death_audit_body(void *panel,void *message,const void *info) {
 assert(panel==(void*)0x6789 && message==(void*)0x5678 && info==NULL);++death_audit_calls;
}
static void death_audit_wrapper(void *self,void *message,const void *info) {
 death_audit_original(self,message,info);
}
static void death_prefix_test(void) {
 const unsigned char bytes[]={0x55,0x48,0x89,0xe5,0x48,0x8b,0xbf,0x40,0x01,0,0,0x48,0x85,0xff};
 unsigned char gui[0x148]={0};void *panel=(void*)0x6789;memcpy(gui+0x140,&panel,sizeof panel);
 NativeHook h={0};assert(native_hook_install(&h,(void*)death_audit_fixture,(void*)death_audit_wrapper,bytes,sizeof bytes,(void**)&death_audit_original)==HOOK_OK);
 death_audit_fixture(gui,(void*)0x5678,(void*)0x1234);assert(death_audit_calls==1);
 panel=NULL;memcpy(gui+0x140,&panel,sizeof panel);
 death_audit_fixture(gui,(void*)0x5678,(void*)0x1234);assert(death_audit_calls==1);
 assert(native_hook_remove(&h)==HOOK_OK);
 puts("Death-screen prefix: test flags and both branch outcomes preserved");
}
extern void send_audit_fixture(void *,void *,const void *);
static void (*send_audit_original)(void *,void *,const void *);
static int send_audit_calls;
void send_audit_body(void *self,void *message,const void *info){
 assert(self && message==(void*)3 && info==(void*)4);++send_audit_calls;
}
static void send_audit_wrapper(void *self,void *message,const void *info){send_audit_original(self,message,info);}
static void test_send_prologue(void){
 unsigned char object[64]={0};
 const unsigned char bytes[]={0x55,0x48,0x89,0xe5,0x41,0x56,0x53,0x49,0x89,0xf6,0x48,0x89,0xfb,0x48,0x8b,0x47,0x28};
 NativeHook hook={0};
 assert(native_hook_install(&hook,(void*)send_audit_fixture,(void*)send_audit_wrapper,bytes,sizeof bytes,(void**)&send_audit_original)==HOOK_OK);
 send_audit_fixture(object,(void*)3,(void*)4);assert(send_audit_calls==1);
 assert(native_hook_remove(&hook)==HOOK_OK);
}
int main(void) {
 test_send_prologue();
 setbuf(stdout,NULL);puts("test started");hp_assignment_test();death_prefix_test();
 NativeHook hook={0};
 unsigned char wrong[sizeof prologue];memcpy(wrong,prologue,sizeof wrong);wrong[0]^=1;
 assert(native_hook_install(&hook,(void*)probe_fixture,(void*)wrapper,wrong,sizeof wrong,(void**)&original)==HOOK_BYTES);
 assert(!hook.installed && !memcmp((void*)probe_fixture,prologue,sizeof prologue));
 assert(probe_fixture((void*)0x1234,-3,4000000000u,250,7,1,9,(void*)0x5678)==0xabcdef0123456789ULL);
 puts("installing redirect");
 assert(native_hook_install(&hook,(void*)probe_fixture,(void*)wrapper,prologue,sizeof prologue,(void**)&original)==HOOK_OK);
 puts("calling redirected function");
 for(unsigned i=0;i<10000;++i)assert(probe_fixture((void*)0x1234,-3,4000000000u,250,7,1,9,(void*)0x5678)==0xabcdef0123456789ULL);
 assert(observed==10000 && original_calls==10001);
 assert(native_hook_remove(&hook)==HOOK_OK);
 assert(!memcmp((void*)probe_fixture,prologue,sizeof prologue));
 assert(probe_fixture((void*)0x1234,-3,4000000000u,250,7,1,9,(void*)0x5678)==0xabcdef0123456789ULL);
 assert(observed==10000 && original_calls==10002);
 puts("Intel native redirect: argument/return preservation, mismatch refusal and restore passed");
}

void incoming_fixture_body(void *a,unsigned b,int c,const void *d){(void)a;(void)b;(void)c;(void)d;}
void hp_fixture_body(void *a,int b,const void *c){(void)a;(void)b;(void)c;}
void nexus_fixture_body(void *a,const void *b){(void)a;(void)b;}

int damage_fixture_body(void *a,float b,const void *c){(void)a;(void)c;return (int)b;}
void death_fixture_body(void *a,void *b,const void *c){(void)a;(void)b;(void)c;}

void update_fixture_body(void *a,void *b,const void *c){(void)a;(void)b;(void)c;}
void stats_fixture_body(void *a,void *b,void *c,unsigned char d,const void *e){(void)a;(void)b;(void)c;(void)d;(void)e;}

void send_fixture_body(void *a,void *b,const void *c){(void)a;(void)b;(void)c;}
