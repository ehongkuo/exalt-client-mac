#define EXALT_HIT_PROBE
#include "../../probe/native_hook.h"
#include <assert.h>
#include <stdio.h>
#include <stdarg.h>
typedef struct {uint64_t id,correlation,update_context,projectile;int phase,hp,tick_sequence,value,owner,flag0,flag1,flag2,flag3;uint32_t server_time,bullet;} ProbeEvent;
typedef struct {void *klass;int value[7];} Message;
static int player,connection,socket,active=1,fatal_enabled,field_reads,forwards,notes;
static uint64_t sequence,probe_update_context=123;
static void *connection_field=(void*)1,*fatal_socket_field=(void*)2,*connection_class;
static ProbeEvent records[32];static unsigned record_count;
static void *probe_player(void){return &player;}
static int probe_active(void){return active;}
static void *read_reference(void *object,void *field){return object==&player && field==connection_field?&connection:object==&connection && field==fatal_socket_field?&socket:NULL;}
static ProbeEvent probe_snapshot(int phase,void *p,void *caller){(void)p;(void)caller;return (ProbeEvent){.id=++sequence,.phase=phase,.hp=200};}
static void probe_emit(ProbeEvent e){assert(record_count<32);records[record_count++]=e;}
static void note(const char *format,...){(void)format;++notes;}
static void *il2cpp_object_get_class(void *object){return ((Message*)object)->klass;}
static void il2cpp_field_get_value(void *object,void *field,void *output){
 ++field_reads;
 if(field==(void*)999){assert(object==&connection);*(int*)output=5;return;}
 uintptr_t code=(uintptr_t)field-1;unsigned group=(unsigned)(code/8),index=(unsigned)(code%8);
 size_t size=group==3 && index>=4?1:group==3 && index==2?2:4;
 memcpy(output,&((Message*)object)->value[index],size);
}
static void *il2cpp_domain_get(void){return NULL;}
static const void **il2cpp_domain_get_assemblies(void *domain,size_t *count){(void)domain;*count=0;return NULL;}
static const void *il2cpp_assembly_get_image(const void *a){return a;}
static const char *il2cpp_image_get_name(const void *a){(void)a;return "";}
static const char *safe(const char *s){return s?s:"";}
static void *il2cpp_class_from_name(const void *image,const char *space,const char *name){(void)image;(void)space;(void)name;return NULL;}
static void *typed_field(void *klass,const char *name,const char *type){(void)klass;(void)name;(void)type;return NULL;}
static const void *find_method_named(void *klass,const char *name,int count,const char *type){(void)klass;(void)name;(void)count;(void)type;return NULL;}
static int probe_signature(const void *method,const char **types,uint32_t count){(void)method;(void)types;(void)count;return 0;}
static int at_offset(const void *method,uintptr_t offset){(void)method;(void)offset;return 0;}
#include "../../probe/sync_trace.h"
static Message *expected_message;static const void *expected_info;
static void forwarded(void *self,void *message,void **entity,const void *info){
 assert(self==&connection && message==expected_message && info==expected_info);++forwards;*entity=(void*)0xbeef;
}
int main(void){
 (void)sync_install;fatal_enabled=1;sync_install();assert(!sync_ready && notes==1);fatal_enabled=0;
 for(int i=0;i<4;++i){sync_classes[i]=(void*)(uintptr_t)(10+i);for(int j=0;j<7;++j)sync_fields[i][j]=(void*)(uintptr_t)(1+i*8+j);}
 sync_player_id_field=(void*)999;sync_ready=1;
 Message tick={sync_classes[0],{37,200,12345,99}};Message saved=tick;
 ProbeEvent entry=sync_tick(&connection,&tick);assert(entry.tick_sequence==37 && entry.server_time==12345 && entry.correlation==123);
 memset(&tick,0,sizeof tick);sync_tick_return(&connection,entry);
 assert(records[1].phase==46 && records[1].tick_sequence==37 && records[1].server_time==12345 && records[1].correlation==entry.id);
 tick=saved;assert(!memcmp(&tick,&saved,sizeof tick));
 Message report={sync_classes[2],{1030,193913}};saved=report;sync_send(&socket,&report);
 assert(records[2].phase==42 && records[2].bullet==1030 && records[2].owner==193913 && !memcmp(&report,&saved,sizeof report));
 Message response={sync_classes[1],{37,12345}};sync_send(&socket,&response);
 assert(records[3].phase==41 && records[3].tick_sequence==37 && records[3].server_time==12345);
 Message damage={sync_classes[3],{5,114,1030,193913,0,1,0}};saved=damage;
 expected_message=&damage;expected_info=(void*)0x1234;sync_damage_original[0]=forwarded;sync_damage_original[1]=forwarded;
 void *entity=NULL;sync_damage_0(&connection,&damage,&entity,expected_info);
 assert(forwards==1 && entity==(void*)0xbeef && !memcmp(&damage,&saved,sizeof damage));
 assert(records[4].phase==43 && records[4].projectile==5 && records[4].value==114 && records[4].flag1==1);
 assert(records[5].phase==44 && records[5].correlation==records[4].id);
 active=0;int reads=field_reads;unsigned count=record_count;sync_damage_1(&connection,&damage,&entity,expected_info);sync_send(&socket,&report);
 assert(field_reads==reads && record_count==count && forwards==2);
 active=1;damage.klass=NULL;sync_damage_0(&connection,&damage,&entity,expected_info);assert(forwards==3 && record_count==count);
 damage=saved;sync_events=SYNC_EVENT_LIMIT;reads=field_reads;sync_damage_1(&connection,&damage,&entity,expected_info);sync_send(&socket,&report);
 assert(field_reads==reads && record_count==count && forwards==4);
 puts("Sync trace: exact forwarding, field identity, no mutation, pooled tick lifetime, off-main and cap behavior passed");
}
