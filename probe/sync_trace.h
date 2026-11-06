#ifndef SYNC_TRACE_H
#define SYNC_TRACE_H
/* Observation-only, build-checked decoded fields. No payloads, packet mutation,
 * acknowledgement inference, or production inclusion. Phases 40..47 are separate
 * from prediction events. update_context is the local player ID in this schema.
 * Phase 47 is floating text over the local player (heal amounts such as "+50"),
 * recorded at the outermost MapObjectUIManager text call. */
#if !defined(EXALT_HIT_PROBE) || defined(EXALT_CLIENT_FATAL)
#error Synchronization tracing requires the observation-only diagnostic build
#endif
typedef void (*SyncDamageFunction)(void *,void *,void **,const void *);
static SyncDamageFunction sync_damage_original[1];
static NativeHook sync_damage_hooks[1];
/* Text variants carry (kind, string, Nullable<Color32>, x, y, z); amount variants carry
 * (kind, int, Color32 or Nullable<Color32>, delay). Both colors fit one integer register. */
typedef void (*SyncStringText)(void *,int,void *,uint64_t,float,float,float,const void *);
typedef void (*SyncAmountText)(void *,int,int,uint64_t,float,const void *);
#define SYNC_TEXT_METHODS 6
static void *sync_text_original[SYNC_TEXT_METHODS];
static NativeHook sync_text_hooks[SYNC_TEXT_METHODS];
static void *sync_text_owner_field;
static int sync_text_ready,sync_text_depth;
static void *sync_classes[4],*sync_fields[4][7],*sync_player_id_field;
static int sync_ready;
static unsigned sync_events;
#define SYNC_EVENT_LIMIT 90000U /* About 90 minutes of tick traffic, for extended sessions. */
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
/* First integer in the text and whether a '+' precedes it; 0 and found=0 when none. */
static int sync_text_amount(const char *text,int *found,int *plus) {
    *found=0;*plus=0;
    for(const char *c=text;*c;++c){
        if(*c<'0' || *c>'9')continue;
        long value=0;*found=1;*plus=c>text && c[-1]=='+';
        while(*c>='0' && *c<='9' && value<100000000)value=value*10+(*c++-'0');
        return (int)value;
    }
    return 0;
}
/* Records only text owned by the local player, and only for the outermost call, since
 * the amount variants format their text and pass it on to a text variant. */
static int sync_text_owned(void *self) {
    void *player=sync_text_ready && !sync_text_depth && sync_events<SYNC_EVENT_LIMIT && probe_active()?probe_player():NULL;
    return player && read_reference(self,sync_text_owner_field)==player;
}
static void sync_text_record(int which,int kind,uint64_t color,int amount,int found,int plus,const char *text) {
    void *connection=read_reference(probe_player(),connection_field);if(!connection)return;
    /* Variants 0..3 take Nullable<Color32> (has-value byte, then RGBA); 4..5 take Color32. */
    uint32_t rgba=which<4?(color & 0xff?(uint32_t)(color>>8):0):(uint32_t)color;
    ProbeEvent e=sync_snapshot(47,connection);e.flag3=which;e.flag2=kind;e.owner=(int)rgba;
    e.value=amount;e.flag0=found;e.flag1=plus;sync_publish(e);
    note("sync_object_text\tevent=%llu\tkind=%d\tcolor=%#x\ttext=%s\n",(unsigned long long)e.id,kind,rgba,text);
}
static void sync_string_text(void *self,int kind,void *text,uint64_t color,float x,float y,float z,const void *info,int which) {
    if(text && sync_text_owned(self)){
        char buffer[49];read_text(text,buffer,sizeof buffer);int found,plus,amount=sync_text_amount(buffer,&found,&plus);
        sync_text_record(which,kind,color,amount,found,plus,buffer);
    }
    /* Always forward exactly once. */
    ++sync_text_depth;((SyncStringText)sync_text_original[which])(self,kind,text,color,x,y,z,info);--sync_text_depth;
}
static void sync_amount_text(void *self,int kind,int amount,uint64_t color,float delay,const void *info,int which) {
    if(sync_text_owned(self))sync_text_record(which,kind,color,amount,1,0,"");
    ++sync_text_depth;((SyncAmountText)sync_text_original[which])(self,kind,amount,color,delay,info);--sync_text_depth;
}
#define SYNC_STRING_TEXT(n) static void sync_text_##n(void *s,int k,void *t,uint64_t c,float x,float y,float z,const void *i) {sync_string_text(s,k,t,c,x,y,z,i,n);}
#define SYNC_AMOUNT_TEXT(n) static void sync_text_##n(void *s,int k,int a,uint64_t c,float d,const void *i) {sync_amount_text(s,k,a,c,d,i,n);}
SYNC_STRING_TEXT(0) SYNC_STRING_TEXT(1) SYNC_AMOUNT_TEXT(2) SYNC_AMOUNT_TEXT(3) SYNC_AMOUNT_TEXT(4) SYNC_AMOUNT_TEXT(5)
static int sync_text_param(const void *method,uint32_t index,const char *expected) {
    char *type=il2cpp_type_get_name(il2cpp_method_get_param(method,index));
    int match=type && !strcmp(type,expected);if(type)il2cpp_free(type);return match;
}
/* MapObjectUIManager's floating-text entry points on 2ce88d8b: two text variants and four
 * amount variants (cloned copies included). Optional; a refusal leaves the rest running. */
static void sync_text_install(const void *game) {
    static const struct {const char *name;uintptr_t offset;uint32_t params;const char *second;unsigned length;} methods[SYNC_TEXT_METHODS]={
        {"JKPGIMHGALD",0x1967f70,6,"System.String",17},{"ShowFloatingText",0x1968e80,6,"System.String",17},
        {"ShowFloatingText",0x196af70,4,"System.Int32",17},{"GDFCPFJPMMA",0x196bd30,4,"System.Int32",17},
        {"JCDLPNEGOCB",0x19683a0,4,"System.Int32",15},{"EAKJIOHGGMM",0x1968b00,4,"System.Int32",15}};
    static const unsigned char wide[]={0x55,0x48,0x89,0xe5,0x41,0x57,0x41,0x56,0x41,0x55,0x41,0x54,0x53,0x48,0x83,0xec},
        narrow[]={0x55,0x48,0x89,0xe5,0x41,0x57,0x41,0x56,0x41,0x54,0x53,0x48,0x83,0xec,0x10};
    void *replacements[]={(void*)sync_text_0,(void*)sync_text_1,(void*)sync_text_2,(void*)sync_text_3,(void*)sync_text_4,(void*)sync_text_5};
    void *klass=il2cpp_class_from_name(game,"DecaGames.RotMG.Managers.Game.MapObjects","MapObjectUIManager");
    sync_text_owner_field=klass?typed_field(klass,"AIPGCEGAMOB","LKHPPBEGNOM"):NULL;
    if(!sync_text_owner_field){note("sync_text_refused\towner_field\n");return;}
    void *entries[SYNC_TEXT_METHODS];unsigned char bytes[SYNC_TEXT_METHODS][17];
    for(int i=0;i<SYNC_TEXT_METHODS;++i){
        const void *method=find_method_named(klass,methods[i].name,methods[i].params,"DGKAANOAENH");
        /* Same-named overloads: at_offset picks the build-checked one. */
        if(method && !at_offset(method,methods[i].offset)){
            void *iterator=NULL;const void *m;method=NULL;
            while((m=il2cpp_class_get_methods(klass,&iterator)))if(at_offset(m,methods[i].offset)){method=m;break;}
        }
        if(!method || il2cpp_method_get_param_count(method)!=methods[i].params || !sync_text_param(method,0,"DGKAANOAENH") ||
           !sync_text_param(method,1,methods[i].second) || strcmp(safe(il2cpp_method_get_name(method)),methods[i].name)){
            note("sync_text_refused\tmethod=%s\n",methods[i].name);return;}
        entries[i]=*(void *const*)method;
        if(methods[i].length==17){memcpy(bytes[i],wide,sizeof wide);bytes[i][16]=methods[i].params==6?0x58:0x18;}
        else memcpy(bytes[i],narrow,sizeof narrow);
        if(!entries[i] || memcmp(entries[i],bytes[i],methods[i].length)){note("sync_text_refused\tentry_bytes=%s\n",methods[i].name);return;}
    }
    for(int i=0;i<SYNC_TEXT_METHODS;++i){int result=native_hook_install(&sync_text_hooks[i],entries[i],replacements[i],bytes[i],methods[i].length,&sync_text_original[i]);
        if(result!=HOOK_OK){for(int j=i-1;j>=0;--j)if(native_hook_remove(&sync_text_hooks[j])!=HOOK_OK)__builtin_trap();
            note("sync_text_refused\thook=%d\n",result);return;}}
    sync_text_ready=1;
}
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
    /* Build b09e1a2d removed the second handler (KMNAOFNEMKK). */
    const char *methods[]={"DJCPAGLIIBO"};
    const uintptr_t offsets[]={0x926410};
    const unsigned char bytes[]={0x55,0x48,0x89,0xe5,0x41,0x57,0x41,0x56,0x41,0x55,0x41,0x54,0x53,0x50,0x49,0x89,0xd6};
    void *entries[1];
    for(int i=0;i<1;++i){
        const void *method=find_method_named(connection_class,methods[i],2,"MMDLNDNCGMA");
        if(!probe_signature(method,(const char*[]){"MMDLNDNCGMA","LKHPPBEGNOM&"},2) || !at_offset(method,offsets[i])){
            note("sync_trace_refused\tmethod=%s\n",methods[i]);return;}
        entries[i]=*(void *const*)method;
        if(!entries[i] || memcmp(entries[i],bytes,sizeof bytes)){note("sync_trace_refused\tentry_bytes\n");return;}
    }
    void *replacements[]={(void*)sync_damage_0};
    for(int i=0;i<1;++i){int result=native_hook_install(&sync_damage_hooks[i],entries[i],replacements[i],bytes,sizeof bytes,(void**)&sync_damage_original[i]);
        if(result!=HOOK_OK){for(int j=i-1;j>=0;--j)if(native_hook_remove(&sync_damage_hooks[j])!=HOOK_OK)__builtin_trap();
            note("sync_trace_refused\thook=%d\n",result);return;}}
    sync_text_install(game);
    sync_ready=1;note("sync_trace_ready\tversion=3\tintervention=0\tmax_events=%u\tpacket_payloads=0\tobject_text=%d\n",SYNC_EVENT_LIMIT,sync_text_ready);
}
#endif
