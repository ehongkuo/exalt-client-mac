#define il2cpp_runtime_invoke fixture_runtime_invoke
#define il2cpp_object_get_class fixture_object_get_class
#define il2cpp_field_get_value fixture_field_get_value
#define main guard_fixture_main
#include "../fixture.c"
#undef main
#undef il2cpp_field_get_value
#undef il2cpp_object_get_class
#undef il2cpp_runtime_invoke
#include <pthread.h>
extern uint64_t probe_fixture(void *,int,uint32_t,int,int,uint8_t,int,const void *);
extern void notify_fixture(void *,uint8_t,int,void *,uint8_t,void *,uint8_t,uint8_t,const void *);
static unsigned report_forwarded,notify_forwarded,enemy_forwarded,hp_forwarded,manual_nexus_forwarded;
static int assigned_hp=-1;
extern void incoming_fixture(void *,uint32_t,int,const void *);
extern void hp_fixture(void *,int,const void *);
extern void nexus_fixture(void *,const void *);
extern int damage_fixture(void *,float,const void *);
extern void death_fixture(void *,void *,const void *);
static unsigned damage_forwarded,death_forwarded;
extern void update_fixture(void *,void *,const void *);
extern void stats_fixture(void *,void *,void *,uint8_t,const void *);
static int update_sequence=41;static uint32_t update_time=1000;static int next_stats_hp=1005;
static unsigned update_forwarded,stats_forwarded;
void update_fixture_body(void *self,void *message,const void *info) {
 assert(self==(void*)70 && message==(void*)3 && info==(void*)0x5678);
 ++update_forwarded;stats_fixture(self,(void*)40,(void*)3,1,info);++update_sequence;update_time+=200;
}
void stats_fixture_body(void *self,void *actor,void *stats,uint8_t flag,const void *info) {
 assert(self==(void*)70 && (actor==(void*)40 || actor==(void*)3) && stats==(void*)3 && flag==1 && info==(void*)0x5678);
 ++stats_forwarded;if(actor==(void*)40)hp_fixture(actor,next_stats_hp,info);
}
static uint8_t socket_nexusing;
void *il2cpp_runtime_invoke(const void *method,void *object,void **args,void **exception) {
#ifdef FATAL_BURST
 if(method==&nexus_method){
  assert(object==(void*)70 && args==NULL);*exception=NULL;
#ifdef NEXUS_REQUEST_EXCEPTION
  *exception=&fake_exception;return NULL;
#else
  ++nexus_calls;nexus_fixture(object,(void*)0x5678);
#ifndef NEXUS_REQUEST_DENIED
  socket_nexusing=1;
#endif
  return NULL;
#endif
 }
#endif
 return fixture_runtime_invoke(method,object,args,exception);
}
void *il2cpp_object_get_class(void *object) {
#ifdef BAD_DAMAGE_ARGUMENT
 if(object==(void*)3) { volatile unsigned char *invalid=object;(void)*invalid; }
#endif
 return fixture_object_get_class(object);
}
int damage_fixture_body(void *self,float value,const void *info) {
 #ifdef BAD_DAMAGE_ARGUMENT
 assert(self==(void*)3);
#else
 assert(self==(void*)0x3456);
#endif
 assert(value==50.5f && info==(void*)0x5678);++damage_forwarded;return 50;
}
void death_fixture_body(void *self,void *message,const void *info) {
 assert(self==(void*)20 && message==(void*)0x1234 && info==(void*)0x5678);++death_forwarded;
}
void il2cpp_field_get_value(void *o,void *f,void *v) {
 if(f==(void*)1001){assert(o==(void*)40 || o==(void*)41);*(uint64_t*)v=1ULL<<45;return;}
 if(f==(void*)1002){assert(o==(void*)40 || o==(void*)41);*(int*)v=0;return;}
 if(f==(void*)1003){assert(o==(void*)40 || o==(void*)41);*(int*)v=100;return;}
 if(f==(void*)992){assert(o==(void*)70);*(void**)v=(void*)500;return;}
 if(f==(void*)993){assert(o==(void*)500);*(uint8_t*)v=socket_nexusing;return;}
 if(f==(void*)990){assert(o==(void*)70);*(int*)v=update_sequence;return;}
 if(f==(void*)991){assert(o==(void*)70);*(uint32_t*)v=update_time;return;}
 if(f==(void*)11 && o==(void*)40 && assigned_hp>=0){*(int*)v=assigned_hp;return;}
 fixture_field_get_value(o,f,v);
}
void incoming_fixture_body(void *self,uint32_t bullet,int owner,const void *info) {
 assert(self==(void*)70 && bullet==4000000000u && owner==7 && info==(void*)0x5678);
 ++report_forwarded;
}
void hp_fixture_body(void *self,int value,const void *info) {
 assert(self==(void*)40 && info==(void*)0x5678);assigned_hp=value;++hp_forwarded;
}
void nexus_fixture_body(void *self,const void *info) {
 assert(self==(void*)70 && info==(void*)0x5678);++manual_nexus_forwarded;
}
uint64_t fixture_body(void *self,int tick,uint32_t bullet,int value,int owner,uint8_t flag,int type,const void *info) {
 assert(self==(void*)70 && tick==21 && bullet==4000000000u && value==400 && owner==7 && flag==1 && type==9 && info==(void*)0x5678);
 ++enemy_forwarded;return 0xabcdef0123456789ULL;
}
void notify_fixture_body(void *self,uint8_t killed,int value,void *conditions,uint8_t flag,void *projectile,uint8_t a,uint8_t b,const void *info) {
 assert(self==(void*)40 && killed==0 && (value==400 || value==50) && conditions==(void*)0x2345 && flag==1 && projectile==(void*)0x3456 && a==1 && b==0 && info==(void*)0x4567);
 ++notify_forwarded;
#if defined(LETHAL_BURST) || defined(FATAL_BURST)
 #ifndef FATAL_RECONCILE
 if(notify_forwarded==4)assigned_hp=0;
#endif
#endif
}
#ifdef BAD_DAMAGE_ARGUMENT
#define DAMAGE_ARGUMENT ((void*)3)
#else
#define DAMAGE_ARGUMENT ((void*)0x3456)
#endif
extern void send_fixture(void *,void *,const void *);
static unsigned boundary_sent,other_sent;
void send_fixture_body(void *self,void *message,const void *info) {
 assert(message==(void*)3);
 if(self==(void*)500 && info==(void*)0x5678)++boundary_sent;
 else ++other_sent;
}
static void burst(void *unused) {
 (void)unused;
 probe_fixture((void*)70,21,4000000000u,400,7,1,9,(void*)0x5678);
#ifdef FATAL_BURST
 hp_fixture((void*)40,200,(void*)0x5678);
#ifdef FATAL_BOUNDARY_BURST
 for(int i=0;i<6;++i){
  notify_fixture((void*)40,0,50,(void*)0x2345,1,(void*)0x3456,1,0,(void*)0x4567);
  send_fixture((void*)500,(void*)3,(void*)0x5678);
  send_fixture((void*)500,(void*)3,(void*)0x9876); /* unrelated callsite */
  send_fixture((void*)501,(void*)3,(void*)0x5678); /* unrelated socket */
 }
 assert(other_sent==12);
#if defined(NEXUS_REQUEST_DENIED) || defined(NEXUS_REQUEST_EXCEPTION) || defined(BOUNDARY_PASS)
 assert(boundary_sent==6 && notify_forwarded==6);
#else
 assert(boundary_sent==3 && notify_forwarded==3);
#endif
 printf("boundary_sent=%u other_sent=%u\n",boundary_sent,other_sent);
 return;
#endif
#ifdef FATAL_RECONCILE
 assert(damage_fixture(DAMAGE_ARGUMENT,50.5f,(void*)0x5678)==50);
 incoming_fixture((void*)70,4000000000u,7,(void*)0x5678);
 notify_fixture((void*)40,0,50,(void*)0x2345,1,(void*)0x3456,1,0,(void*)0x4567);
 next_stats_hp=200;stats_fixture((void*)70,(void*)40,(void*)3,1,(void*)0x5678);
#endif
 for(int i=0;i<6;++i) {
  int actual=damage_fixture(DAMAGE_ARGUMENT,50.5f,(void*)0x5678);
#if defined(NEXUS_REQUEST_DENIED) || defined(NEXUS_REQUEST_EXCEPTION)
  assert(actual==50);
#else
  #ifdef VERIFY_EARLY
  assert(actual==0);
#else
  assert(actual==(i<3?50:0));
#endif
#endif
#ifdef FATAL_RECONCILE
  if(i==3){next_stats_hp=200;stats_fixture((void*)70,(void*)40,(void*)3,1,(void*)0x5678);}
#endif
  incoming_fixture((void*)70,4000000000u,7,(void*)0x5678);
  if(actual)notify_fixture((void*)40,0,actual,(void*)0x2345,1,(void*)0x3456,1,0,(void*)0x4567);
  else notify_fixture((void*)40,0,0,(void*)0x2345,1,(void*)0x3456,1,0,(void*)0x4567);
 }
#elif defined(LETHAL_BURST)
 hp_fixture((void*)40,200,(void*)0x5678);
 for(int i=0;i<6;++i) {
  assert(damage_fixture(DAMAGE_ARGUMENT,50.5f,(void*)0x5678)==50);
  incoming_fixture((void*)70,4000000000u,7,(void*)0x5678);
  notify_fixture((void*)40,0,50,(void*)0x2345,1,(void*)0x3456,1,0,(void*)0x4567);
  if(i==3)death_fixture((void*)20,(void*)0x1234,(void*)0x5678);
 }
#ifdef ABRUPT_EXIT
 _exit(23);
#endif
#else
 for(int i=0;i<3;++i) {
  assert(damage_fixture(DAMAGE_ARGUMENT,50.5f,(void*)0x5678)==50);
  incoming_fixture((void*)70,4000000000u,7,(void*)0x5678);
  if(i==1)update_fixture((void*)70,(void*)3,(void*)0x5678);
  notify_fixture((void*)40,0,400,(void*)0x2345,1,(void*)0x3456,1,0,(void*)0x4567);
 }
 next_stats_hp=805;stats_fixture((void*)70,(void*)40,(void*)3,1,(void*)0x5678);
 stats_fixture((void*)70,(void*)3,(void*)3,1,(void*)0x5678);
 nexus_fixture((void*)70,(void*)0x5678);
#endif
}
static void *other_thread(void *unused) {
 (void)unused;incoming_fixture((void*)70,4000000000u,7,(void*)0x5678);
#ifdef FATAL_BURST
 notify_fixture((void*)40,0,50,(void*)0x2345,1,(void*)0x3456,1,0,(void*)0x4567);
#endif
 return NULL;
}
static void background(void *unused) {
 (void)unused;pthread_t thread;assert(!pthread_create(&thread,NULL,other_thread,NULL));assert(!pthread_join(thread,NULL));
}
#ifdef FATAL_CLIENT_TOGGLE
static void late_blocked_hit(void *unused) {
 (void)unused;
 assert(damage_fixture(DAMAGE_ARGUMENT,50.5f,(void*)0x5678)==0);
 incoming_fixture((void*)70,4000000000u,7,(void*)0x5678);
 notify_fixture((void*)40,0,0,(void*)0x2345,1,(void*)0x3456,1,0,(void*)0x4567);
}
#endif
static void verify_forwarding(void *unused) {
 (void)unused;
#ifdef FATAL_BURST
#ifdef FATAL_BOUNDARY_BURST
 return;
#endif
#if defined(NEXUS_REQUEST_DENIED) || defined(NEXUS_REQUEST_EXCEPTION)
 assert(report_forwarded==7 && notify_forwarded==7 && assigned_hp==0);
#else
 #ifdef FATAL_RECONCILE
 assert(report_forwarded==4 && notify_forwarded==4 && assigned_hp==200);
#else
 #ifdef VERIFY_EARLY
 assert(report_forwarded==0 && notify_forwarded==0 && assigned_hp==200);
#else
 assert(report_forwarded==3 && notify_forwarded==3 && assigned_hp==200);
#endif
#endif
#endif
 #if defined(FATAL_RECONCILE) || defined(FATAL_CLIENT_TOGGLE)
 assert(damage_forwarded==7 && enemy_forwarded==1);
#else
 assert(damage_forwarded==6 && enemy_forwarded==1);
#endif
 printf("fatal_report_forwarded=%u fatal_notify_forwarded=%u fatal_damage_calls=%u\n",report_forwarded,notify_forwarded,damage_forwarded);
#elif defined(LETHAL_BURST)
 assert(report_forwarded==7 && notify_forwarded==6 && damage_forwarded==6 && death_forwarded==1 && enemy_forwarded==1 && hp_forwarded==1);
#else
 assert(damage_forwarded==3 && death_forwarded==0 && update_forwarded==1 && stats_forwarded==3);
 assert(report_forwarded==4 && notify_forwarded==3 && enemy_forwarded==1 && hp_forwarded==2 && manual_nexus_forwarded==1);
#endif
 printf("probe_report_forwarded=%u probe_notify_forwarded=%u\n",report_forwarded,notify_forwarded);
}
int main(void) {
#ifdef FATAL_CLIENT_TOGGLE
 dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW,1500*NSEC_PER_MSEC),dispatch_get_main_queue(),NULL,late_blocked_hit);
#endif
 dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW,900*NSEC_PER_MSEC),dispatch_get_main_queue(),NULL,burst);
 dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW,1000*NSEC_PER_MSEC),dispatch_get_main_queue(),NULL,background);
 dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW,3900*NSEC_PER_MSEC),dispatch_get_main_queue(),NULL,verify_forwarding);
 return guard_fixture_main();
}

void death_audit_body(void *a,void *b,const void *c){(void)a;(void)b;(void)c;}

void send_audit_body(void *a,void *b,const void *c){(void)a;(void)b;(void)c;}
