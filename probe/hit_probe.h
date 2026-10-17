#ifndef HIT_PROBE_H
#define HIT_PROBE_H
#include "native_hook.h"
#include <pthread.h>

typedef void (*ReportFunction)(void *,uint32_t,int,const void *);
typedef void (*NotifyFunction)(void *,uint8_t,int,void *,uint8_t,void *,uint8_t,uint8_t,const void *);
typedef void (*HPFunction)(void *,int,const void *);
typedef void (*NexusFunction)(void *,const void *);
static ReportFunction report_original;
static NotifyFunction notify_original;
static HPFunction hp_original;
static NexusFunction nexus_original;
typedef int (*DamageFunction)(void *,float,const void *);
typedef void (*DeathFunction)(void *,void *,const void *);
static DamageFunction damage_original;
static DeathFunction death_original;
#ifndef HIT_PROBE_TEST
static void *probe_projectile_class;
#endif
typedef void (*UpdateFunction)(void *,void *,const void *);
typedef void (*StatsFunction)(void *,void *,void *,uint8_t,const void *);
static UpdateFunction update_original;
static StatsFunction stats_original;
static void *probe_tick_field,*probe_time_field;
static uint64_t probe_update_context;
static int probe_update_source;
static NativeHook probe_hooks[9];
typedef void (*SendFunction)(void *,void *,const void *);
static SendFunction send_original;
/* Audited only for EXALT_GAME_SHA256 in damage_paths.json. */
#define TERRAIN_NOTIFY_CALLER 0x196ed65UL
#define AREA_NOTIFY_CALLER 0x183f7beUL
#define TERRAIN_SEND_CALLER 0x196ed90UL /* report helper tail-calls SendMessage */
#define AREA_SEND_CALLER 0x183f880UL
#define SEND_OFFSET 0x199e310UL
static _Atomic uintptr_t fatal_block_socket;
static int probe_installed,probe_attempted;
static char probe_main_key;
static int probe_on_main(void) { return pthread_main_np() || dispatch_get_specific(&probe_main_key)==&probe_main_key; }
static uintptr_t probe_game_base;
static uint64_t probe_sequence,probe_generation;
static void *probe_map,*probe_identity;
#ifdef EXALT_HIT_PROBE
static void *probe_connection;
static int probe_nexus=-1;
#endif
static int probe_last_hp=-1,probe_last_max=-1;
static uint64_t probe_last_report,probe_last_report_ns,probe_last_report_generation;
static uint32_t probe_last_bullet;
static int probe_last_owner;
static _Atomic uint64_t probe_off_main,probe_drops;
#define PROBE_CAPACITY 2048
/* Phases: report entry/return 1/2, notification 3, sampled HP 4,
 * HP assignment entry/return 5/6, manual Nexus entry/return 7/8, identity/map 9, notification return 10, damage entry/return 11/12,
 * death screen entry/return 13/14, positive-to-nonpositive HP 15. */
typedef struct {
    uint64_t id,ns,generation,callsite,correlation,projectile,work_ns;
    int phase,owner,value,hp,max,in_nexus,valid,flag0,flag1,flag2,flag3;
    uint32_t bullet;
    uint64_t update_context;
    int tick_sequence;uint32_t server_time;int update_source;
} ProbeEvent;
#include "fatal_policy.h"
static FatalPolicy fatal_policy;
static int fatal_enabled,fatal_invoking,fatal_death_logged;
static uint64_t fatal_meter_retry_ns;
static int fatal_meter_saw_breath;
#ifdef EXALT_HIT_PROBE
static int fatal_verify_hp;
#endif
static void *fatal_socket_class,*fatal_socket_field,*fatal_nexusing_field;
static void *fatal_player_handle,*fatal_connection_handle,*fatal_socket_handle;
static _Atomic uintptr_t fatal_block_player,fatal_block_connection;
static _Atomic uint64_t fatal_off_main_reports,fatal_off_main_notifications;
static _Atomic uint64_t fatal_requests,fatal_reports_dropped,fatal_notifications_dropped;
#include "flight_recorder.h"
static FlightRecorder *probe_flight;
static int probe_zero_hp=-1;
static uint64_t probe_zero_generation;
static void hit_probe_open(const char *folder) {
#ifdef EXALT_CLIENT_FATAL
    (void)folder;fatal_enabled=1;
#else
    const char *active=getenv("EXALT_FATAL_INTERVENTION");fatal_enabled=active && !strcmp(active,"1");
    /* Diagnostic-only synthetic lethal threshold. Never writes game HP and is
     * deliberately unavailable in the production client. */
    const char *verify=getenv("EXALT_VERIFY_ONE_HP");
    fatal_verify_hp=fatal_enabled && verify && !strcmp(verify,"1");
    if(fatal_verify_hp)note("damage_verification\teffective_hp=1\tgame_hp_unchanged=1\n");
    probe_flight=flight_open(folder,start_ns,start_epoch);
    if(!probe_flight)note("hit_probe_refused\tflight_recorder\n");
#endif
}
static ProbeEvent probe_events[PROBE_CAPACITY];
static _Atomic uint64_t probe_head,probe_tail;
static uint64_t probe_callsite(void *address) {
    uintptr_t value=(uintptr_t)address;
    return value>=probe_game_base && value-probe_game_base<0x6000000UL?value-probe_game_base:0;
}
static void probe_publish(ProbeEvent e) {
    if(probe_flight)flight_publish(probe_flight,e);
    uint64_t head=atomic_load_explicit(&probe_head,memory_order_relaxed);
    if(head-atomic_load_explicit(&probe_tail,memory_order_acquire)==PROBE_CAPACITY){atomic_fetch_add(&probe_drops,1);return;}
    probe_events[head%PROBE_CAPACITY]=e;
    atomic_store_explicit(&probe_head,head+1,memory_order_release);
}
static void probe_emit(ProbeEvent e) {
#ifdef EXALT_CLIENT_FATAL
    if(e.phase<20)return;
#endif
    probe_publish(e);
    if(probe_zero_generation!=e.generation){probe_zero_generation=e.generation;probe_zero_hp=-1;}
    if(e.max>0) {
        if(probe_zero_hp>0 && e.hp<=0) {
            ProbeEvent zero=e;zero.id=++probe_sequence;zero.ns=monotonic_ns();
            zero.phase=15;zero.value=e.phase;zero.correlation=e.id;probe_publish(zero);
        }
        probe_zero_hp=e.hp;
    }
}
static void *probe_player(void) {
    void *player=player_handle?il2cpp_gchandle_get_target(player_handle):NULL;
    return player && il2cpp_object_get_class(player)==player_class?player:NULL;
}
static int probe_active(void) {
#ifdef EXALT_CLIENT_FATAL
    if(!config.death && !fatal_policy.blocking)return 0;
#endif
    return probe_on_main() && !atomic_load_explicit(&finished,memory_order_acquire);
}
static ProbeEvent probe_snapshot(int phase,void *player,void *caller) {
    uint64_t begin=monotonic_ns();
    int changed=probe_map!=last_map_info || probe_identity!=player;
#ifdef EXALT_HIT_PROBE
    void *current_connection=player && connection_field?read_reference(player,connection_field):NULL;
    changed=changed || current_connection!=probe_connection || probe_nexus!=in_nexus;
    probe_connection=current_connection;probe_nexus=in_nexus;
#endif
    if(changed) {
        probe_map=last_map_info;probe_identity=player;++probe_generation;
        probe_last_report=0;probe_last_hp=-1;probe_last_max=-1;
    }
    ProbeEvent e={.id=++probe_sequence,.ns=begin,.phase=phase,.generation=probe_generation,
        .callsite=probe_callsite(caller),.in_nexus=in_nexus,.hp=-1,.max=-1};
    if(player && guard_ok && player_hp_field && max_field) {
        il2cpp_field_get_value(player,player_hp_field,&e.hp);
        il2cpp_field_get_value(player,max_field,&e.max);
        e.valid=e.hp>=0 && e.max>0 && e.hp<=e.max;
    }
    e.update_context=probe_update_context;e.update_source=probe_update_source;
    if(player && probe_tick_field && probe_time_field){
        void *connection=read_reference(player,connection_field);
        if(connection){il2cpp_field_get_value(connection,probe_tick_field,&e.tick_sequence);il2cpp_field_get_value(connection,probe_time_field,&e.server_time);}
    }
    e.work_ns=monotonic_ns()-begin;
#ifdef EXALT_HIT_PROBE
    if(changed){ProbeEvent identity=e;identity.phase=9;probe_emit(identity);e.id=++probe_sequence;}
#endif
    return e;
}
/* Fatal phases 20-28 use numeric aliases: projectile = retained damage,
 * update_context = signed projected HP, flag1 = blocking. Neither is a pointer. */
static void fatal_emit(int phase,void *player,uint64_t correlation,int value,int status,int exception) {
    ProbeEvent e=probe_snapshot(phase,player,NULL);e.correlation=correlation;e.value=value;
    e.projectile=(uint64_t)fatal_policy.pending;e.update_context=(uint64_t)fatal_policy.projected;
    e.flag0=status;e.flag1=fatal_policy.blocking;e.flag2=exception;probe_emit(e);
}
static void fatal_clear(void *player,int reason) {
    int was_blocking=fatal_policy.blocking;
    if(fatal_policy.player)fatal_emit(25,player,0,was_blocking,reason,0);
    atomic_store_explicit(&fatal_block_socket,0,memory_order_release);
    atomic_store_explicit(&fatal_block_connection,0,memory_order_release);
    atomic_store_explicit(&fatal_block_player,0,memory_order_release);
    release(&fatal_player_handle);release(&fatal_connection_handle);release(&fatal_socket_handle);
    fatal_policy=(FatalPolicy){0};fatal_death_logged=0;
    fatal_meter_retry_ns=0;fatal_meter_saw_breath=0;
#ifdef EXALT_CLIENT_FATAL
    live_data.death_blocking=0;live_data.death_pending=0;live_data.death_predicted=0;
#endif
}
static int fatal_sync(void *player) {
#ifdef EXALT_CLIENT_FATAL
    static int last_mode=-1;
    int mode=(config.death?1:0)+(config.armed?2:0);
    if(mode!=last_mode){if(fatal_policy.player && !fatal_policy.blocking)fatal_clear(player,3);last_mode=mode;}
    if(!config.death && !fatal_policy.blocking)return 0;
#endif
    if(!fatal_enabled || !guard_ok || !map_ok || map_unknown_logged || !last_map_info)return 0;
    if(in_nexus){if(fatal_policy.player)fatal_clear(player,1);return 0;}
    if(!player || validated_player!=(uintptr_t)player)return 0;
    void *connection=read_reference(player,connection_field);if(!connection)return 0;
    if(fatal_policy.player && (fatal_policy.player!=(uintptr_t)player || fatal_policy.connection!=(uintptr_t)connection || fatal_policy.map!=(uintptr_t)last_map_info))
        fatal_clear(player,2);
    if(!fatal_policy.player)fatal_reset(&fatal_policy,(uintptr_t)player,(uintptr_t)connection,(uintptr_t)last_map_info);
    return 1;
}
static void *damage_breath_field,*damage_frostbite_field;
static int fatal_local_nexusing(void *connection) {
    void *socket=read_reference(connection,fatal_socket_field);
    if(!socket || il2cpp_object_get_class(socket)!=fatal_socket_class)return 0;
    uint8_t value=0;il2cpp_field_get_value(socket,fatal_nexusing_field,&value);return value!=0;
}
#ifdef EXALT_HIT_PROBE
static void *damage_conditions_field;
static uint64_t damage_context_next_ns,damage_context_generation,damage_context_bits;
static int damage_context_breath=-1,damage_context_frostbite=-1,damage_context_nexusing=-1,damage_context_mask=-1;
/* Phase 29: projectile is an opaque condition bitset, value/owner are raw breath/frostbite
 * meters, flag0 is the availability mask (1/2/4/8), flag1 is local Nexusing. */
static void damage_context_emit(void *player,uint64_t correlation) {
    if(!probe_active() || !player || player!=probe_player())return;
    uint64_t now=monotonic_ns();
    if(!correlation && now<damage_context_next_ns)return;
    damage_context_next_ns=now+20000000ULL;
    uint64_t bits=0;int breath=-1,frostbite=-1,nexusing=-1,mask=0;
    if(damage_conditions_field){
        void *array=read_reference(player,damage_conditions_field);
        /* Audited Intel IL2CPP Int32[]: length API plus elements at +0x20. */
        if(array && il2cpp_array_length(array)>=2){
            uint32_t words[2];memcpy(words,(char*)array+0x20,sizeof words);
            bits=(uint64_t)words[0] | ((uint64_t)words[1]<<32);mask|=1;
        }
    }
    if(damage_breath_field){il2cpp_field_get_value(player,damage_breath_field,&breath);mask|=2;}
    if(damage_frostbite_field){il2cpp_field_get_value(player,damage_frostbite_field,&frostbite);mask|=4;}
    void *connection=read_reference(player,connection_field);
    if(connection && fatal_socket_field && fatal_socket_class && fatal_nexusing_field){
        void *socket=read_reference(connection,fatal_socket_field);
        if(socket && il2cpp_object_get_class(socket)==fatal_socket_class){
            nexusing=fatal_local_nexusing(connection);mask|=8;
        }
    }
    ProbeEvent e=probe_snapshot(29,player,NULL);
    if(!correlation && damage_context_generation==e.generation && damage_context_mask==mask && damage_context_bits==bits &&
       damage_context_breath==breath && damage_context_frostbite==frostbite && damage_context_nexusing==nexusing)return;
    damage_context_generation=e.generation;damage_context_mask=mask;damage_context_bits=bits;damage_context_breath=breath;
    damage_context_frostbite=frostbite;damage_context_nexusing=nexusing;
    e.flag2=1; /* Corrected Int32[] condition provenance; legacy phase 29 used a sprite key. */
    e.projectile=bits;e.value=breath;e.owner=frostbite;e.flag0=mask;e.flag1=nexusing>0;
    e.correlation=correlation;e.work_ns=monotonic_ns()-now;probe_emit(e);
}
#endif
#ifdef EXALT_CLIENT_FATAL
static void fatal_record(void *player,int hp,int result) {
    int max=0;il2cpp_field_get_value(player,max_field,&max);
    uint64_t now=monotonic_ns();
    Record r={.epoch=start_epoch+(double)(now-start_ns)/1e9,.action=GUARD_NEXUS_DEATH,
              .result=result,.slot=-1,.player_hp=hp,.player_max=max};
    record_event(&r);
    note("guard_death_nexus\thp=%d\tpending=%lld\tpredicted=%lld\tresult=%d\n",
         hp,(long long)fatal_policy.pending,(long long)fatal_policy.projected,result);
}
#endif
static int fatal_intervene_reason(void *player,int damage,uint64_t calculation,int hazard) {
    if(!fatal_sync(player))return damage;
    int hp=0;il2cpp_field_get_value(player,player_hp_field,&hp);
    int prediction_hp=hp;
#ifdef EXALT_HIT_PROBE
    if(fatal_verify_hp && hp>0)prediction_hp=1;
#endif
    int decision;
    if(hazard){
        if(hp<=0 || fatal_policy.blocking)return damage;
        fatal_policy.attempted=1;decision=FATAL_REQUEST;
        note("guard_environment_nexus\treason=%s\thp=%d\n",hazard==1?"frostbite_limit":"oxygen_exhausted",hp);
    }else decision=fatal_damage(&fatal_policy,prediction_hp,damage);
    if(decision==FATAL_REQUEST) {
        fatal_emit(20,player,calculation,damage,decision,0);
#ifdef EXALT_CLIENT_FATAL
        if(!config.armed){fatal_record(player,hp,RESULT_DRY);goto prediction_done;}
#endif
        void *connection=(void*)fatal_policy.connection;
        fatal_player_handle=il2cpp_gchandle_new(player,0);
        fatal_connection_handle=il2cpp_gchandle_new(connection,0);
        void *socket=read_reference(connection,fatal_socket_field);
        if(socket && il2cpp_object_get_class(socket)==fatal_socket_class)fatal_socket_handle=il2cpp_gchandle_new(socket,0);
        if(!fatal_player_handle || !fatal_connection_handle || !fatal_socket_handle){
            release(&fatal_player_handle);release(&fatal_connection_handle);release(&fatal_socket_handle);
            fatal_emit(22,player,calculation,damage,0,2);
#ifdef EXALT_CLIENT_FATAL
            fatal_record(player,hp,RESULT_UNAVAILABLE);
#endif
            return damage;
        }
        int already=fatal_local_nexusing(connection);void *exception=NULL;
        fatal_emit(21,player,calculation,damage,already,0);
        if(!already){++fatal_requests;fatal_invoking=1;
            il2cpp_runtime_invoke(nexus_method,connection,NULL,&exception);fatal_invoking=0;}
        int local=!exception && socket==read_reference(connection,fatal_socket_field) && fatal_local_nexusing(connection);
        fatal_requested(&fatal_policy,local);
        if(local){
            atomic_store_explicit(&fatal_block_socket,(uintptr_t)socket,memory_order_release);
            atomic_store_explicit(&fatal_block_player,(uintptr_t)player,memory_order_release);
            atomic_store_explicit(&fatal_block_connection,(uintptr_t)connection,memory_order_release);
        } else {release(&fatal_player_handle);release(&fatal_connection_handle);release(&fatal_socket_handle);}
        fatal_emit(22,player,calculation,damage,local,exception!=NULL);
#ifdef EXALT_CLIENT_FATAL
        live_data.death_blocking=fatal_policy.blocking;
        if(!already)fatal_record(player,hp,local?RESULT_CALLED:exception?RESULT_EXCEPTION:RESULT_UNAVAILABLE);
#endif
    }
#ifdef EXALT_CLIENT_FATAL
prediction_done:
    live_data.death_pending=fatal_policy.pending;live_data.death_predicted=fatal_policy.projected;
#endif
    fatal_emit(27,player,calculation,damage,decision,0);
    return fatal_policy.blocking?0:damage;
}
static int fatal_intervene(void *player,int damage,uint64_t calculation) {
    return fatal_intervene_reason(player,damage,calculation,0);
}
/* These meters describe server-owned hazards. Escape proactively; never pretend
 * that suppressing an incoming HP assignment cancels damage at the server. */
static void fatal_meter_tick(void *player,uint64_t now) {
    if(!fatal_sync(player) || fatal_policy.blocking || now<fatal_meter_retry_ns)return;
    int breath=-1,frostbite=-1;
    if(damage_breath_field)il2cpp_field_get_value(player,damage_breath_field,&breath);
    if(damage_frostbite_field)il2cpp_field_get_value(player,damage_frostbite_field,&frostbite);
    if(breath>0)fatal_meter_saw_breath=1;
    int hazard=fatal_environment_hazard(breath,frostbite);
    if(hazard==2 && !fatal_meter_saw_breath)return; /* default zero is not evidence of exhaustion */
    if(!hazard)return;
    fatal_meter_retry_ns=now+1000000000ULL; /* bounded retries, including dry run */
    (void)fatal_intervene_reason(player,0,0,hazard);
}
static void report_observed(void *self,uint32_t bullet,int owner,const void *info) {
    if(!probe_on_main()){atomic_fetch_add(&probe_off_main,1);
        if(self && atomic_load_explicit(&fatal_block_connection,memory_order_acquire)==(uintptr_t)self){atomic_fetch_add(&fatal_off_main_reports,1);return;}
        report_original(self,bullet,owner,info);return;}
    void *player=probe_player();
    if(self && atomic_load_explicit(&fatal_block_connection,memory_order_acquire)==(uintptr_t)self){
        ++fatal_reports_dropped;ProbeEvent blocked=probe_snapshot(23,player,__builtin_return_address(0));
        blocked.bullet=bullet;blocked.owner=owner;blocked.projectile=(uint64_t)fatal_policy.pending;
        blocked.update_context=(uint64_t)fatal_policy.projected;blocked.flag1=1;probe_emit(blocked);return;
    }
    int observe=probe_active() && player && read_reference(player,connection_field)==self;
    ProbeEvent e={0};
    if(observe) {
        e=probe_snapshot(1,player,__builtin_return_address(0));e.bullet=bullet;e.owner=owner;
        probe_last_report=e.id;probe_last_report_ns=e.ns;probe_last_report_generation=e.generation;
        probe_last_bullet=bullet;probe_last_owner=owner;probe_emit(e);
    }
    report_original(self,bullet,owner,info);
    if(observe){ProbeEvent returned=probe_snapshot(2,player,NULL);returned.correlation=e.id;returned.bullet=bullet;returned.owner=owner;probe_emit(returned);}
}
static void send_observed(void *self,void *message,const void *info) {
    uint64_t caller=probe_callsite(__builtin_return_address(0));
#ifdef HIT_PROBE_BOUNDARY_TEST
    if(info==(void*)0x5678)caller=HIT_PROBE_BOUNDARY_TEST;
#endif
#ifdef HIT_PROBE_MIXED_TEST
    if(info==(void*)0x6001)caller=TERRAIN_SEND_CALLER;
    if(info==(void*)0x6002)caller=AREA_SEND_CALLER;
#endif
    /* Exact caller and retained socket only. Nexus and all other messages pass.
     * No IL2CPP access off-main; the atomic latch is published after acceptance. */
    if((caller==TERRAIN_SEND_CALLER || caller==AREA_SEND_CALLER) && self &&
       atomic_load_explicit(&fatal_block_socket,memory_order_acquire)==(uintptr_t)self){
        if(probe_on_main()){
            ProbeEvent e=probe_snapshot(30,probe_player(),NULL);e.callsite=caller;probe_emit(e);
        }
        return;
    }
    send_original(self,message,info);
}
static void notify_observed(void *self,uint8_t flag0,int value,void *conditions,uint8_t flag1,void *projectile,uint8_t a,uint8_t b,const void *info) {
    if(!probe_on_main()){atomic_fetch_add(&probe_off_main,1);
        uint64_t caller=probe_callsite(__builtin_return_address(0));
        int local=caller==NOTIFY_CALLER || caller==TERRAIN_NOTIFY_CALLER || caller==AREA_NOTIFY_CALLER;
#ifdef HIT_PROBE_TEST
        local=1;
#endif
        if(self && local && atomic_load_explicit(&fatal_block_player,memory_order_acquire)==(uintptr_t)self){atomic_fetch_add(&fatal_off_main_notifications,1);return;}
        notify_original(self,flag0,value,conditions,flag1,projectile,a,b,info);return;}
    uint64_t caller=probe_callsite(__builtin_return_address(0));
#ifdef HIT_PROBE_BOUNDARY_TEST
    caller=HIT_PROBE_BOUNDARY_TEST==TERRAIN_SEND_CALLER?TERRAIN_NOTIFY_CALLER:AREA_NOTIFY_CALLER;
#endif
#ifdef HIT_PROBE_MIXED_TEST
    caller=a==2?TERRAIN_NOTIFY_CALLER:a==3?AREA_NOTIFY_CALLER:NOTIFY_CALLER;
#endif
#if defined(HIT_PROBE_TEST) && !defined(HIT_PROBE_BOUNDARY_TEST) && !defined(HIT_PROBE_MIXED_TEST)
    int local_projectile=1;
#else
    int local_projectile=caller==NOTIFY_CALLER;
#endif
    int local_boundary=caller==TERRAIN_NOTIFY_CALLER || caller==AREA_NOTIFY_CALLER;
    if(probe_active() && self==probe_player() && local_boundary && fatal_enabled)
        (void)fatal_intervene(self,value,0); /* Final damage, before HP effects and report. */
    if(self && (local_projectile || local_boundary) && atomic_load_explicit(&fatal_block_player,memory_order_acquire)==(uintptr_t)self){
        ++fatal_notifications_dropped;ProbeEvent blocked=probe_snapshot(24,self,NULL);blocked.callsite=caller;
        blocked.value=value;blocked.flag1=1;probe_emit(blocked);return;
    }
    int observe=probe_active() && self==probe_player();
    ProbeEvent e={0};
    if(observe) {
        e=probe_snapshot(3,self,__builtin_return_address(0));
        e.value=value;e.flag0=flag0;e.flag1=flag1;e.flag2=a;e.flag3=b;e.projectile=(uintptr_t)projectile;
        /* A temporal association, not a damage acknowledgement or deduplication key. */
        if(probe_last_report && probe_last_report_generation==e.generation && e.ns>=probe_last_report_ns && e.ns-probe_last_report_ns<10000000ULL
#ifndef HIT_PROBE_TEST
           && e.callsite==NOTIFY_CALLER
#endif
        ){e.correlation=probe_last_report;e.bullet=probe_last_bullet;e.owner=probe_last_owner;probe_last_report=0;}
        probe_emit(e);
#ifdef EXALT_HIT_PROBE
        damage_context_emit(self,e.id);
#endif
    }
    notify_original(self,flag0,value,conditions,flag1,projectile,a,b,info);
    if(observe){ProbeEvent after=probe_snapshot(10,self,NULL);after.correlation=e.id;after.projectile=(uintptr_t)projectile;after.value=value;probe_emit(after);}
}
static void hp_observed(void *self,int value,const void *info) {
    if(!probe_on_main()){atomic_fetch_add(&probe_off_main,1);hp_original(self,value,info);return;}
    int observe=probe_active() && self==probe_player();
    ProbeEvent e={0};
    if(observe){e=probe_snapshot(5,self,__builtin_return_address(0));e.value=value;if(!e.update_context && e.callsite==ZERO_HP_CALLER)e.update_source=3;
        probe_emit(e);
#ifdef EXALT_HIT_PROBE
        damage_context_emit(self,e.id);
#endif
    }
    hp_original(self,value,info);
    if(observe){ProbeEvent after=probe_snapshot(6,self,NULL);after.correlation=e.id;after.value=value;after.update_context=e.update_context;after.update_source=e.update_source;probe_emit(after);
        if(fatal_enabled && fatal_policy.player==(uintptr_t)self && (after.update_source==1 || after.update_source==2)){
            fatal_server_hp(&fatal_policy,after.hp);fatal_emit(28,self,after.id,after.hp,after.update_source,0);
            /* A positive authoritative value can reveal a lethal conservative
             * bound while older reports remain uncertain. Escape now; never
             * suppress or change the authoritative assignment itself. */
            if(after.hp>0 && !fatal_policy.blocking && fatal_policy.pending>0 && fatal_policy.projected<=0)
                (void)fatal_intervene(self,0,after.id);
#ifdef EXALT_CLIENT_FATAL
            live_data.death_pending=fatal_policy.pending;live_data.death_predicted=fatal_policy.projected;
#endif
        }
        if(fatal_enabled && fatal_policy.blocking && after.hp<=0 && !fatal_death_logged){fatal_death_logged=1;fatal_emit(26,self,after.id,after.hp,0,0);}}
}
static void nexus_observed(void *self,const void *info) {
    if(!probe_on_main()){atomic_fetch_add(&probe_off_main,1);nexus_original(self,info);return;}
    void *player=probe_player();
    int observe=probe_active() && player && read_reference(player,connection_field)==self;
    ProbeEvent e={0};
    if(observe){e=probe_snapshot(7,player,__builtin_return_address(0));e.flag0=fatal_invoking;probe_emit(e);probe_last_report=0;}
    nexus_original(self,info);
    if(observe){ProbeEvent after=probe_snapshot(8,player,NULL);after.correlation=e.id;probe_emit(after);}
}
static int damage_observed(void *raw_arg,float input,const void *raw_info) {
    if(!probe_on_main()){atomic_fetch_add(&probe_off_main,1);return damage_original(raw_arg,input,raw_info);}
    uint64_t caller=probe_callsite(__builtin_return_address(0));
#ifdef HIT_PROBE_BAD_ARGUMENT_TEST
    caller=DAMAGE_CALLER;
#endif
    void *player=probe_player();
    int audited=1;
#if !defined(HIT_PROBE_TEST) || defined(HIT_PROBE_BAD_ARGUMENT_TEST)
    audited=caller==DAMAGE_CALLER;
#endif
#ifdef HIT_PROBE_UNAUDITED_TEST
    audited=0;
#endif
    int observe=probe_active() && player;
#ifndef EXALT_HIT_PROBE
    observe=observe && audited;
#endif
    /* The audited caller does not populate an instance argument. Preserve opaque
     * native arguments, but never inspect them or use them as projectile IDs. */
    ProbeEvent e={0};
    if(observe){e=probe_snapshot(11,player,NULL);e.callsite=caller;e.flag0=audited;e.flag1=1;
        memcpy(&e.flag3,&input,sizeof input);probe_emit(e);}
    int result=damage_original(raw_arg,input,raw_info);
    uint64_t calculation=0;
    if(observe){ProbeEvent after=probe_snapshot(12,player,NULL);after.correlation=e.id;
        after.value=result;after.flag3=e.flag3;after.flag0=audited;after.flag1=1;after.callsite=caller;calculation=after.id;probe_emit(after);}
    return observe && audited && fatal_enabled?fatal_intervene(player,result,calculation):result;
}
static void death_observed(void *self,void *message,const void *info) {
    if(!probe_on_main()){atomic_fetch_add(&probe_off_main,1);death_original(self,message,info);return;}
    int observe=probe_active() && gui_handle && self==il2cpp_gchandle_get_target(gui_handle);
    ProbeEvent e={0};
    if(observe){e=probe_snapshot(13,probe_player(),__builtin_return_address(0));probe_emit(e);}
    death_original(self,message,info);
    if(observe){ProbeEvent after=probe_snapshot(14,probe_player(),NULL);after.correlation=e.id;probe_emit(after);}
}
static void update_observed(void *self,void *opaque_message,const void *info) {
    if(!probe_on_main()){atomic_fetch_add(&probe_off_main,1);update_original(self,opaque_message,info);return;}
    void *player=probe_player();
    int observe=probe_active() && player && self==read_reference(player,connection_field);
    ProbeEvent e={0};uint64_t saved_context=probe_update_context;int saved_source=probe_update_source;
    if(observe){e=probe_snapshot(16,player,__builtin_return_address(0));e.update_context=e.id;e.update_source=1;
        probe_update_context=e.id;probe_update_source=1;probe_emit(e);}
    update_original(self,opaque_message,info);
    if(observe){ProbeEvent after=probe_snapshot(17,player,NULL);after.correlation=e.id;probe_emit(after);}
    probe_update_context=saved_context;probe_update_source=saved_source;
}
static void stats_observed(void *self,void *actor,void *opaque_stats,uint8_t flag,const void *info) {
    if(!probe_on_main()){atomic_fetch_add(&probe_off_main,1);stats_original(self,actor,opaque_stats,flag,info);return;}
    void *player=probe_player();
    int observe=probe_active() && player && actor==player && self==read_reference(player,connection_field);
    ProbeEvent e={0};uint64_t saved_context=probe_update_context;int saved_source=probe_update_source;
    if(observe){e=probe_snapshot(18,player,__builtin_return_address(0));e.flag0=flag;
        if(!probe_update_context){probe_update_context=e.id;probe_update_source=2;}
        e.update_context=probe_update_context;e.update_source=probe_update_source;probe_emit(e);}
    stats_original(self,actor,opaque_stats,flag,info);
    if(observe){ProbeEvent after=probe_snapshot(19,player,NULL);after.correlation=e.id;after.flag0=flag;probe_emit(after);}
    probe_update_context=saved_context;probe_update_source=saved_source;
}
#ifndef HIT_PROBE_TEST
static int probe_signature(const void *method,const char **types,uint32_t count) {
    if(!method || il2cpp_method_get_param_count(method)!=count)return 0;
    for(uint32_t i=0;i<count;++i) {
        char *type=il2cpp_type_get_name(il2cpp_method_get_param(method,i));
        int match=type && !strcmp(type,types[i]);if(type)il2cpp_free(type);
        if(!match)return 0;
    }
    return 1;
}
#endif
static void probe_install(void) {
#ifdef EXALT_CLIENT_FATAL
    if(probe_attempted || !config.death)return;
#else
    if(probe_attempted || !probe_flight)return;
#endif
#ifndef HIT_PROBE_TEST
    if(!in_nexus || !map_ok || map_unknown_logged || !guard_ok || !probe_player())return;
#endif
    Dl_info image;
    if(!dladdr((const void*)il2cpp_domain_get,&image) || !image.dli_fbase)return;
    probe_game_base=(uintptr_t)image.dli_fbase;probe_attempted=1;
    dispatch_queue_set_specific(dispatch_get_main_queue(),&probe_main_key,&probe_main_key,NULL);
    void *entries[9]={0};
#ifdef HIT_PROBE_TEST
    const char *names[]={"incoming_fixture","notify_fixture","hp_fixture","nexus_fixture","damage_fixture","death_fixture","update_fixture","stats_fixture","send_fixture"};
    for(int i=0;i<9;++i)entries[i]=dlsym(RTLD_DEFAULT,names[i]);
    probe_tick_field=(void*)990;probe_time_field=(void*)991;
    fatal_socket_field=(void*)992;fatal_nexusing_field=(void*)993;fatal_socket_class=(void*)50;
#ifndef HIT_PROBE_NO_CONTEXT_TEST
    damage_breath_field=(void*)1002;damage_frostbite_field=(void*)1003;
#ifdef EXALT_HIT_PROBE
    damage_conditions_field=(void*)1001;
#endif
#endif
#else
    size_t count=0;const void **assemblies=il2cpp_domain_get_assemblies(il2cpp_domain_get(),&count);
    for(size_t i=0;i<count;++i){const void *image=il2cpp_assembly_get_image(assemblies[i]);
        if(!strcmp(safe(il2cpp_image_get_name(image)),"Assembly-CSharp.dll"))probe_projectile_class=il2cpp_class_from_name(image,DAMAGE_OFFSET_NAMESPACE,DAMAGE_OFFSET_OWNER);}
    if(fatal_enabled || probe_flight){
        fatal_socket_field=typed_field(connection_class,"NIDFCHODLIH","DecaGames.RotMG.Managers.Net.SocketManager");
        for(size_t i=0;i<count;++i){const void *image=il2cpp_assembly_get_image(assemblies[i]);
            if(!strcmp(safe(il2cpp_image_get_name(image)),"Assembly-CSharp.dll"))fatal_socket_class=il2cpp_class_from_name(image,"DecaGames.RotMG.Managers.Net","SocketManager");}
        if(fatal_socket_class)fatal_nexusing_field=typed_field(fatal_socket_class,"FCOJPHFICAG","System.Boolean");
        if(fatal_enabled && (!fatal_socket_field || !fatal_nexusing_field)){note("hit_probe_refused\tfatal_nexus_fields\n");return;}
    }
#ifdef EXALT_HIT_PROBE
    void *entity=ancestor_named(player_class,"LKHPPBEGNOM");
    damage_conditions_field=entity?typed_field(entity,"COHCKAPOLCA","System.Int32[]"):NULL;
#endif
    damage_breath_field=typed_field(player_class,"NMLPJEBCBAE","System.Int32");
    damage_frostbite_field=typed_field(player_class,"DLNIODKGIKA","System.Int32");
    if(!probe_projectile_class){note("hit_probe_refused\tprojectile_class\n");return;}
    probe_tick_field=typed_field(connection_class,"PNIHHODGAEE","System.Int32");
    probe_time_field=typed_field(connection_class,"FIAJOKGHGGK","System.UInt32");
    if(!probe_tick_field || !probe_time_field){note("hit_probe_refused\tupdate_fields\n");return;}
    const void *methods[]={find_method_named(connection_class,HIT_REPORT_OFFSET_NAME,2,"System.UInt32"),
        find_method_named(player_class,HIT_NOTIFY_OFFSET_NAME,7,"System.Boolean"),
        find_method_named(ancestor_named(player_class,"LKHPPBEGNOM"),HP_ASSIGN_OFFSET_NAME,1,"System.Int32"),
        find_method_named(connection_class,NEXUS_OFFSET_NAME,0,NULL),
        find_method_named(probe_projectile_class,DAMAGE_OFFSET_NAME,1,"System.Single"),
        find_method_named(gui_class,DEATH_SCREEN_OFFSET_NAME,1,"LPBNPHKMNNG"),
        find_method_named(connection_class,UPDATE_OFFSET_NAME,1,"OODFCLBKDJJ"),
        find_method_named(connection_class,STATS_OFFSET_NAME,3,"LKHPPBEGNOM"),
        find_method_named(fatal_socket_class,"SendMessage",1,"DCBCCBKEIHN")};
    const char *rtypes[]={"System.UInt32","System.Int32"};
    const char *ntypes[]={"System.Boolean","System.Int32","System.Collections.Generic.List<System.Byte>","System.Boolean","HBEAKBIHANL","System.Boolean","System.Boolean"};
    const char *htypes[]={"System.Int32"};
    const char *dtypes[]={"System.Single"},*stypes[]={"LPBNPHKMNNG"};
    const char *utypes[]={"OODFCLBKDJJ"},*atypes[]={"LKHPPBEGNOM","System.Collections.Generic.List<CGOECEPGBBG>","System.Boolean"};
    const uintptr_t offsets[]={HIT_REPORT_OFFSET,HIT_NOTIFY_OFFSET,HP_ASSIGN_OFFSET,NEXUS_OFFSET,DAMAGE_OFFSET,DEATH_SCREEN_OFFSET,UPDATE_OFFSET,STATS_OFFSET,SEND_OFFSET};
    if(!probe_signature(methods[0],rtypes,2)||!probe_signature(methods[1],ntypes,7)||
       !probe_signature(methods[2],htypes,1)||!probe_signature(methods[3],NULL,0)||!probe_signature(methods[4],dtypes,1)||!probe_signature(methods[5],stypes,1)||!probe_signature(methods[6],utypes,1)||!probe_signature(methods[7],atypes,3)||!probe_signature(methods[8],(const char*[]){"DCBCCBKEIHN"},1)) {
        note("hit_probe_refused\tmethod_validation\n");return;
    }
    for(int i=0;i<9;++i){if(!at_offset(methods[i],offsets[i])){note("hit_probe_refused\tmethod_offset\n");return;}entries[i]=*(void *const*)methods[i];}
#endif
#ifdef HIT_PROBE_TEST
#define send_prologue notify_prologue
#else
    static const unsigned char send_prologue[]={0x55,0x48,0x89,0xe5,0x41,0x56,0x53,0x49,0x89,0xf6,0x48,0x89,0xfb,0x48,0x8b,0x47,0x28};
    /* New boundaries must match in full before ANY hook is installed. */
    static const unsigned char terrain_report_call[]={0xe8,0xb0,0x00,0xed,0xff};
    static const unsigned char terrain_send_tail[]={0xe9,0xf0,0xf3,0x15,0x00};
    static const unsigned char area_send_call[]={0xe8,0x90,0xea,0x15,0x00};
    if(memcmp((void*)(probe_game_base+TERRAIN_SEND_CALLER-5),terrain_report_call,5) ||
       memcmp((void*)(probe_game_base+0x183ef1bUL),terrain_send_tail,5) ||
       memcmp((void*)(probe_game_base+AREA_SEND_CALLER-5),area_send_call,5)){
        note("hit_probe_refused\treport_boundary_bytes\n");return;
    }
    const uintptr_t sites[]={TERRAIN_NOTIFY_CALLER,AREA_NOTIFY_CALLER};
    const unsigned char dispatches[][6]={{0xff,0x90,0x98,8,0,0},{0xff,0x93,0x98,8,0,0}};
    for(int i=0;i<2;++i)if(memcmp((void*)(probe_game_base+sites[i]-6),dispatches[i],6)){
        note("hit_probe_refused\tboundary_bytes\n");return;
    }
#endif
    const unsigned char *bytes[]={report_prologue,notify_prologue,hp_prologue,nexus_prologue,damage_prologue,death_prologue,update_prologue,stats_prologue,send_prologue};
    size_t lengths[]={sizeof report_prologue,sizeof notify_prologue,sizeof hp_prologue,sizeof nexus_prologue,sizeof damage_prologue,sizeof death_prologue,sizeof update_prologue,sizeof stats_prologue,sizeof send_prologue};
    void *replacements[]={(void*)report_observed,(void*)notify_observed,(void*)hp_observed,(void*)nexus_observed,(void*)damage_observed,(void*)death_observed,(void*)update_observed,(void*)stats_observed,(void*)send_observed};
    void **originals[]={(void**)&report_original,(void**)&notify_original,(void**)&hp_original,(void**)&nexus_original,(void**)&damage_original,(void**)&death_original,(void**)&update_original,(void**)&stats_original,(void**)&send_original};
    for(int i=0;i<9;++i)if(!entries[i]||memcmp(entries[i],bytes[i],lengths[i])){note("hit_probe_refused\tentry_bytes\tindex=%d\n",i);return;}
    for(int i=0;i<9;++i){int result=native_hook_install(&probe_hooks[i],entries[i],replacements[i],bytes[i],lengths[i],originals[i]);
        if(result!=HOOK_OK){for(int j=i-1;j>=0;--j)if(native_hook_remove(&probe_hooks[j])!=HOOK_OK)__builtin_trap();note("hit_probe_refused\tredirect_error=%d\n",result);return;}}
    #undef send_prologue
    note("environment_guard_ready\tbreath=%d\tfrostbite=%d\n",damage_breath_field!=NULL,damage_frostbite_field!=NULL);
    probe_installed=1;note("fatal_policy\tversion=2\treconciliation=retain_uncertain\thealing_credit=0\n");note("hit_probe_ready\tv7\tfatal_intervention=%d\n",fatal_enabled);
#ifdef EXALT_HIT_PROBE
    note("damage_context_ready\tconditions=%d\tbreath=%d\tfrostbite=%d\n",damage_conditions_field!=NULL,damage_breath_field!=NULL,damage_frostbite_field!=NULL);
    note("damage_build\tsha256=%s\n",EXALT_GAME_SHA256);
#endif
}
static void hit_probe_tick(void *player,uint64_t now) {
#ifndef EXALT_CLIENT_FATAL
    config.armed=0;
#endif
    (void)now;
    if(!ready)return;
    probe_install();
#ifdef EXALT_CLIENT_FATAL
    live_data.death_status=probe_installed?1:probe_attempted?-1:0;
#endif
    if(!probe_installed)return;
    if(fatal_enabled)fatal_meter_tick(player,now);
#ifdef EXALT_CLIENT_FATAL
    live_data.death_blocking=fatal_policy.blocking;
    live_data.death_pending=fatal_policy.pending;live_data.death_predicted=fatal_policy.projected;
    return;
#endif
    ProbeEvent e=probe_snapshot(4,player,NULL);
    if(e.hp!=probe_last_hp || e.max!=probe_last_max){e.phase=4;probe_emit(e);probe_last_hp=e.hp;probe_last_max=e.max;}
#ifdef EXALT_HIT_PROBE
    damage_context_emit(player,0);
#endif
}
static void hit_probe_drain(void) {
#ifdef EXALT_CLIENT_FATAL
    if(!probe_installed)return;
#endif
    uint64_t tail=atomic_load_explicit(&probe_tail,memory_order_relaxed);
    while(tail!=atomic_load_explicit(&probe_head,memory_order_acquire)) {
        ProbeEvent e=probe_events[tail%PROBE_CAPACITY];
        fprintf(logfile,"hit_probe_v4\t%llu\t%llu\t%.6f\t%d\t%llu\t%llu\t%llu\t%u\t%d\t%d\t%d\t%d\t%d\t%d\t%llu\t%d\t%d\t%d\t%d\t%llu\t%llu\t%d\t%u\t%d\n",
            e.id,e.ns,start_epoch+(double)(e.ns-start_ns)/1e9,e.phase,e.generation,e.callsite,e.correlation,
            e.bullet,e.owner,e.value,e.hp,e.max,e.in_nexus,e.valid,e.projectile,e.flag0,e.flag1,e.flag2,e.flag3,e.work_ns,e.update_context,e.tick_sequence,e.server_time,e.update_source);
        atomic_store_explicit(&probe_tail,++tail,memory_order_release);
    }
    static uint64_t last_counters;
    uint64_t now=monotonic_ns();
    if(now-last_counters>=1000000000ULL || atomic_load_explicit(&finished,memory_order_acquire)){
        last_counters=now;
        if(probe_flight){atomic_store(&probe_flight->dropped,atomic_load(&probe_drops));atomic_store(&probe_flight->off_main,atomic_load(&probe_off_main));msync(probe_flight,sizeof *probe_flight,MS_ASYNC);}
        if(fatal_enabled)fprintf(logfile,"fatal_summary\trequests=%llu\treports_suppressed=%llu\tnotifications_suppressed=%llu\toff_main_reports_suppressed=%llu\toff_main_notifications_suppressed=%llu\tblocking=%d\n",
            fatal_requests,fatal_reports_dropped,fatal_notifications_dropped,atomic_load(&fatal_off_main_reports),atomic_load(&fatal_off_main_notifications),atomic_load(&fatal_block_connection)!=0);
        fprintf(logfile,"hit_probe_summary\tdropped=%llu\toff_main_calls=%llu\tcomplete=%d\n",
            atomic_load(&probe_drops),atomic_load(&probe_off_main),atomic_load(&finished));
    }
}
#endif
