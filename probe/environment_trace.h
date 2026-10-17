#ifndef ENVIRONMENT_TRACE_H
#define ENVIRONMENT_TRACE_H
/* Standalone diagnostics only. No payloads or raw object addresses are retained.
 * Phase 31 records outgoing message type IDs. Phase 32 contains GameAssembly
 * return addresses, correlated with the triggering event. Stack unwinding is
 * best effort; missing frames never establish absence of a producer. */
static _Atomic uint64_t environment_trace_events,environment_trace_stacks,environment_trace_skipped;
static void *environment_trace_classes[64];
static struct { uint64_t caller;void *klass; } environment_trace_sends[128];
static unsigned environment_trace_class_count,environment_trace_send_count;
static uint64_t environment_trace_until,environment_trace_generation;
static int environment_trace_window(void) {
    if(!environment_trace_enabled || in_nexus)return 0;
    if(environment_trace_generation!=probe_generation){
        environment_trace_generation=probe_generation;environment_trace_until=0;
    }
    uint64_t now=monotonic_ns();
    if(damage_context_generation==probe_generation &&
       (((damage_context_mask&4) && damage_context_frostbite>=90) ||
        ((damage_context_mask&2) && damage_context_breath>=0 && damage_context_breath<=10)))
        environment_trace_until=now+2000000000ULL;
    return now<environment_trace_until;
}
static void environment_trace(ProbeEvent trigger,uint64_t caller,void *klass) {
    if(environment_trace_events>=8192){++environment_trace_skipped;return;}
    ++environment_trace_events;
    if(trigger.phase==31){
        unsigned type=0;
        if(klass){
            for(;type<environment_trace_class_count;++type)if(environment_trace_classes[type]==klass)break;
            if(type==environment_trace_class_count && type<64){
                environment_trace_classes[environment_trace_class_count++]=klass;
                note("environment_message_type\tid=%u\tname=%.160s\n",type+1,il2cpp_class_get_name(klass));
            }
        }
        trigger.callsite=caller;trigger.owner=klass && type<64?(int)type+1:0;
        probe_emit(trigger);
        /* Repeated sends still have individual timestamps; unwind the first
         * occurrence of each caller/type pair to keep this capture bounded. */
        unsigned i=0;
        for(;i<environment_trace_send_count;++i)
            if(environment_trace_sends[i].caller==caller && environment_trace_sends[i].klass==klass)return;
        if(i==128){++environment_trace_skipped;return;}
        environment_trace_sends[i].caller=caller;environment_trace_sends[i].klass=klass;++environment_trace_send_count;
    }
    if(environment_trace_stacks>=256){++environment_trace_skipped;return;}
    ++environment_trace_stacks;
    void *frames[20];int count=backtrace(frames,20);
    for(int i=0;i<count;++i){
        uint64_t offset=probe_callsite(frames[i]);if(!offset)continue;
        ProbeEvent frame=trigger;frame.id=++probe_sequence;frame.phase=32;
        frame.correlation=trigger.id;frame.callsite=offset;frame.value=trigger.phase;frame.owner=i;
        probe_emit(frame);
    }
}
#endif
