#define EXALT_HIT_PROBE
#include "../../probe/native_hook.h"
#include <assert.h>
#include <stdio.h>
#include <stdarg.h>
typedef struct {uint64_t id,correlation,update_context,projectile;int phase,hp,tick_sequence,value,owner,flag0,flag1,flag2,flag3;uint32_t server_time,bullet;} ProbeEvent;
typedef struct {void *klass;int value[7];} Message;
static int player,other,manager,other_manager,connection,socket,active=1,fatal_enabled,field_reads,forwards,notes;
static uint64_t sequence,probe_update_context=123;
static void *connection_field=(void*)1,*fatal_socket_field=(void*)2,*connection_class;
static ProbeEvent records[32];static unsigned record_count;
static void *probe_player(void){return &player;}
static int probe_active(void){return active;}
static void *owner_field=(void*)3;
static void *read_reference(void *object,void *field){return field==owner_field?(object==&manager?(void*)&player:object==&other_manager?(void*)&other:NULL):object==&player && field==connection_field?&connection:object==&connection && field==fatal_socket_field?&socket:NULL;}
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
static void read_text(void *string,char *out,size_t size){snprintf(out,size,"%s",(const char*)string);}
static const void *il2cpp_class_get_methods(void *klass,void **iterator){(void)klass;(void)iterator;return NULL;}
static const char *il2cpp_method_get_name(const void *method){(void)method;return "";}
static uint32_t il2cpp_method_get_param_count(const void *method){(void)method;return 0;}
static const void *il2cpp_method_get_param(const void *method,uint32_t index){(void)method;(void)index;return NULL;}
static char *il2cpp_type_get_name(const void *type){(void)type;return NULL;}
static void il2cpp_free(void *p){(void)p;}
#include "../../probe/sync_trace.h"
static Message *expected_message;static const void *expected_info;
static void forwarded(void *self,void *message,void **entity,const void *info){
 assert(self==&connection && message==expected_message && info==expected_info);++forwards;*entity=(void*)0xbeef;
}
static int texts,amounts;static const char *expected_text;static int expected_kind,expected_amount;static void *expected_manager;
static void string_forwarded(void *self,int kind,void *text,uint64_t color,float x,float y,float z,const void *info){
 assert(self==expected_manager && kind==expected_kind && text==expected_text && color==0xff00ff0001ULL && x==1 && y==2 && z==3 && info==expected_info);++texts;
}
static void amount_forwarded(void *self,int kind,int amount,uint64_t color,float delay,const void *info){
 assert(self==expected_manager && kind==expected_kind && amount==expected_amount && color==0xff00ff0001ULL && delay==.5f && info==expected_info);++amounts;
 expected_text="+92";sync_text_1(self,kind,(void*)expected_text,color,1,2,3,info); /* The game formats and passes it on. */
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
 expected_message=&damage;expected_info=(void*)0x1234;sync_damage_original[0]=forwarded;
 void *entity=NULL;sync_damage_0(&connection,&damage,&entity,expected_info);
 assert(forwards==1 && entity==(void*)0xbeef && !memcmp(&damage,&saved,sizeof damage));
 assert(records[4].phase==43 && records[4].projectile==5 && records[4].value==114 && records[4].flag1==1);
 assert(records[5].phase==44 && records[5].correlation==records[4].id);
 sync_text_ready=1;sync_text_owner_field=owner_field;expected_manager=&manager;expected_kind=7;
 for(int i=0;i<SYNC_TEXT_METHODS;++i)sync_text_original[i]=i<2?(void*)string_forwarded:(void*)amount_forwarded;
 expected_text="+50";sync_text_0(&manager,7,(void*)expected_text,0xff00ff0001ULL,1,2,3,expected_info);
 assert(texts==1 && record_count==7 && records[6].phase==47 && records[6].value==50 && records[6].flag0==1 && records[6].flag1==1);
 assert(records[6].flag2==7 && records[6].flag3==0 && records[6].owner==(int)0xff00ff00);
 expected_amount=92;sync_text_2(&manager,7,92,0xff00ff0001ULL,.5f,expected_info);
 assert(amounts==1 && texts==2 && record_count==8 && records[7].value==92 && records[7].flag0==1 && records[7].flag3==2);
 /* The nested text call is forwarded but not recorded twice. */
 expected_text="Level Up!";sync_text_1(&manager,7,(void*)expected_text,0xff00ff0001ULL,1,2,3,expected_info);
 assert(texts==3 && records[8].flag0==0 && records[8].flag3==1);
 unsigned before=record_count;expected_manager=&other_manager;expected_text="+75";
 sync_text_0(&other_manager,7,(void*)expected_text,0xff00ff0001ULL,1,2,3,expected_info);
 sync_text_5(&other_manager,7,92,0xff00ff0001ULL,.5f,expected_info);
 assert(texts==5 && amounts==2 && record_count==before); /* Another object's text is forwarded, not recorded. */
 expected_manager=&manager;
 active=0;int reads=field_reads;unsigned count=record_count;sync_damage_0(&connection,&damage,&entity,expected_info);sync_send(&socket,&report);
 assert(field_reads==reads && record_count==count && forwards==2);
 active=1;damage.klass=NULL;sync_damage_0(&connection,&damage,&entity,expected_info);assert(forwards==3 && record_count==count);
 damage=saved;sync_events=SYNC_EVENT_LIMIT;reads=field_reads;sync_damage_0(&connection,&damage,&entity,expected_info);sync_send(&socket,&report);
 assert(field_reads==reads && record_count==count && forwards==4);
 expected_text="+50";sync_text_0(&manager,7,(void*)expected_text,0xff00ff0001ULL,1,2,3,expected_info);
 sync_text_4(&manager,7,92,0xff00ff0001ULL,.5f,expected_info);
 assert(texts==7 && amounts==3 && record_count==count && !sync_text_depth); /* At the event cap, text is forwarded but not recorded. */
 puts("Sync trace: exact forwarding, field identity, no mutation, pooled tick lifetime, off-main and cap behavior, object text passed");
}
