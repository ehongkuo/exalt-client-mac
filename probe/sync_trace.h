#ifndef SYNC_TRACE_H
#define SYNC_TRACE_H
/* Observation-only, build-checked decoded fields. No payloads, packet mutation,
 * acknowledgement inference, or production inclusion. Phases 40..46 are separate
 * from prediction events. update_context is the local player ID in this schema. */
#if !defined(EXALT_HIT_PROBE) || defined(EXALT_CLIENT_FATAL)
#error Synchronization tracing requires the observation-only diagnostic build
#endif
typedef void (*SyncDamageFunction)(void *,void *,void **,const void *);
static SyncDamageFunction sync_damage_original[2];
static NativeHook sync_damage_hooks[2];
static void *sync_classes[4],*sync_fields[4][7],*sync_player_id_field;
static int sync_ready;
static unsigned sync_events;
#define SYNC_EVENT_LIMIT 12000U
static int probe_signature(const void *,const char **,uint32_t);
static int sync_i32(void *object,void *field) {
    int value=0;il2cpp_field_get_value(object,field,&value);return value;
}
static void sync_publish(ProbeEvent event) {
    if(sync_events>=SYNC_EVENT_LIMIT)return;
    ++sync_events;probe_emit(event);
    if(sync_events==SYNC_EVENT_LIMIT)note("sync_trace_limit\tevents=%u\n",sync_events);
}
static ProbeEvent sync_snapshot(int phase,void *connection) {
    ProbeEvent e=probe_snapshot(phase,probe_player(),NULL);
    e.update_context=(uint32_t)sync_i32(connection,sync_player_id_field);
    return e;
}
static ProbeEvent sync_tick(void *connection,void *message) {
    if(!sync_ready || sync_events>=SYNC_EVENT_LIMIT || !probe_active() || !message ||
       il2cpp_object_get_class(message)!=sync_classes[0])return (ProbeEvent){0};
    ProbeEvent e=sync_snapshot(40,connection);e.correlation=probe_update_context;
    e.tick_sequence=sync_i32(message,sync_fields[0][0]);
    e.value=sync_i32(message,sync_fields[0][1]);
    il2cpp_field_get_value(message,sync_fields[0][2],&e.server_time);
    e.bullet=(uint32_t)sync_i32(message,sync_fields[0][3]);
    sync_publish(e);return e;
}
static void sync_tick_return(void *connection,ProbeEvent before) {
    /* Tick processing returns the message to its pool before this boundary.
     * Carry decoded entry values; never inspect the pooled object again. */
    ProbeEvent e=sync_snapshot(46,connection);e.correlation=before.id;
    e.tick_sequence=before.tick_sequence;e.server_time=before.server_time;
    e.value=before.value;e.bullet=before.bullet;sync_publish(e);
}
static void sync_send(void *socket,void *message) {
    if(!sync_ready || sync_events>=SYNC_EVENT_LIMIT || !probe_active() || !message)return;
    void *player=probe_player(),*connection=player?read_reference(player,connection_field):NULL;
    if(!connection || socket!=read_reference(connection,fatal_socket_field))return;
    void *klass=il2cpp_object_get_class(message);
    if(klass!=sync_classes[1] && klass!=sync_classes[2])return;
    ProbeEvent e=sync_snapshot(klass==sync_classes[1]?41:42,connection);
    if(klass==sync_classes[1]){
        e.tick_sequence=sync_i32(message,sync_fields[1][0]);
        il2cpp_field_get_value(message,sync_fields[1][1],&e.server_time);
    } else {
        il2cpp_field_get_value(message,sync_fields[2][0],&e.bullet);
        e.owner=sync_i32(message,sync_fields[2][1]);
    }
    sync_publish(e);
}
static void sync_damage(void *self,void *message,void **entity,const void *info,int which) {
    uint64_t entry=0;
    if(sync_ready && sync_events<SYNC_EVENT_LIMIT && probe_active() && message &&
       il2cpp_object_get_class(message)==sync_classes[3]){
        void *player=probe_player();
        if(player && self==read_reference(player,connection_field)){
            ProbeEvent e=sync_snapshot(43,self);e.flag3=which;
            e.projectile=(uint32_t)sync_i32(message,sync_fields[3][0]); /* target ID, not pointer */
            e.value=sync_i32(message,sync_fields[3][1]);
            int16_t bullet=0;il2cpp_field_get_value(message,sync_fields[3][2],&bullet);e.bullet=(uint16_t)bullet;
            e.owner=sync_i32(message,sync_fields[3][3]);
            uint8_t a=0,b=0,c=0;
            il2cpp_field_get_value(message,sync_fields[3][4],&a);
            il2cpp_field_get_value(message,sync_fields[3][5],&b);
            il2cpp_field_get_value(message,sync_fields[3][6],&c);
            e.flag0=a;e.flag1=b;e.flag2=c;entry=e.id;sync_publish(e);
        }
    }
    /* Always forward exactly once, including off-main, unknown-class and limit cases. */
    sync_damage_original[which](self,message,entity,info);
    if(entry){ProbeEvent e=sync_snapshot(44,self);e.correlation=entry;e.flag3=which;sync_publish(e);}
}
static void sync_damage_0(void *self,void *message,void **entity,const void *info) {sync_damage(self,message,entity,info,0);}
static void sync_damage_1(void *self,void *message,void **entity,const void *info) {sync_damage(self,message,entity,info,1);}
static void sync_install(void) {
    if(fatal_enabled){note("sync_trace_refused\tintervention_enabled\n");return;}
    size_t count=0;const void **assemblies=il2cpp_domain_get_assemblies(il2cpp_domain_get(),&count);
    const void *game=NULL;
    for(size_t i=0;i<count;++i){const void *image=il2cpp_assembly_get_image(assemblies[i]);
        if(!strcmp(safe(il2cpp_image_get_name(image)),"Assembly-CSharp.dll"))game=image;}
    if(!game){note("sync_trace_refused\tassembly\n");return;}
    const char *classes[]={"BJEENKGELLO","FKGDHGJDNAO","HLDKJECFCAC","MMDLNDNCGMA"};
    const char *names[][7]={{"ADELDBNEGND","HOMNPDGNOMO","OOMJAHJPEGC","PHBFAKPBEAB"},
        {"FNMONFPCBME","DLIOLEFCGDD"},{"CLKDFFOGKJB","LHGHIMNMIBL"},
        {"ECAFJKPPKHA","IOFBNGEBPLE","KLHOFENGJNM","HHPOJBFICAH","BBGFAJEPHKG","ENAOALKIOMH","BAIFHIKEBLB"}};
    const char *types[][7]={{"System.Int32","System.Int32","System.UInt32","System.UInt32"},
        {"System.Int32","System.UInt32"},{"System.UInt32","System.Int32"},
        {"System.Int32","System.Int32","System.Int16","System.Int32","System.Boolean","System.Boolean","System.Boolean"}};
    const int fields[]={4,2,2,7};
    for(int i=0;i<4;++i){
        sync_classes[i]=il2cpp_class_from_name(game,"",classes[i]);
        if(!sync_classes[i]){note("sync_trace_refused\tclass=%s\n",classes[i]);return;}
        for(int j=0;j<fields[i];++j){
            sync_fields[i][j]=typed_field(sync_classes[i],names[i][j],types[i][j]);
            if(!sync_fields[i][j]){note("sync_trace_refused\tfield=%s\n",names[i][j]);return;}
        }
    }
    sync_player_id_field=typed_field(connection_class,"CMAEBFGEKFC","System.Int32");
    if(!sync_player_id_field){note("sync_trace_refused\tplayer_id\n");return;}
    const char *methods[]={"KMNAOFNEMKK","DJCPAGLIIBO"};
    const uintptr_t offsets[]={0x1840650,0x1841230};
    const unsigned char bytes[]={0x55,0x48,0x89,0xe5,0x41,0x57,0x41,0x56,0x41,0x55,0x41,0x54,0x53,0x50,0x49,0x89,0xd6};
    void *entries[2];
    for(int i=0;i<2;++i){
        const void *method=find_method_named(connection_class,methods[i],2,"MMDLNDNCGMA");
        if(!probe_signature(method,(const char*[]){"MMDLNDNCGMA","LKHPPBEGNOM&"},2) || !at_offset(method,offsets[i])){
            note("sync_trace_refused\tmethod=%s\n",methods[i]);return;}
        entries[i]=*(void *const*)method;
        if(!entries[i] || memcmp(entries[i],bytes,sizeof bytes)){note("sync_trace_refused\tentry_bytes\n");return;}
    }
    void *replacements[]={(void*)sync_damage_0,(void*)sync_damage_1};
    for(int i=0;i<2;++i){int result=native_hook_install(&sync_damage_hooks[i],entries[i],replacements[i],bytes,sizeof bytes,(void**)&sync_damage_original[i]);
        if(result!=HOOK_OK){for(int j=i-1;j>=0;--j)if(native_hook_remove(&sync_damage_hooks[j])!=HOOK_OK)__builtin_trap();
            note("sync_trace_refused\thook=%d\n",result);return;}}
    sync_ready=1;note("sync_trace_ready\tversion=1\tintervention=0\tmax_events=%u\tpacket_payloads=0\n",SYNC_EVENT_LIMIT);
}
#endif
