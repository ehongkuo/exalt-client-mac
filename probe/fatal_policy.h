#ifndef FATAL_POLICY_H
#define FATAL_POLICY_H
#include <stdint.h>
#include <limits.h>
enum { FATAL_PASS, FATAL_REQUEST, FATAL_BLOCK, FATAL_LATE, FATAL_INVALID };
enum { FATAL_REASON_NONE, FATAL_REASON_LETHAL, FATAL_REASON_STALE, FATAL_REASON_CAPACITY };
#define FATAL_HIT_CAPACITY 128
#define FATAL_QUIET_WINDOW_NS 800000000ULL
#define FATAL_HEALTHY_GAP_NS 1000000000ULL
#define FATAL_MIN_TICK_GAP_NS 20000000ULL
/* Regeneration credited when matching an HP drop to hits: the median of recent
 * HP-increase rates (robust to occasional heals and max-HP caps), a default before
 * any increase is seen, and a ceiling so sustained healing cannot widen matching
 * without bound. A local estimate may also exceed the server's by a few percent. */
#define FATAL_REGEN_HP_PER_S 20
#define FATAL_REGEN_MAX_HP_PER_S 100
#define FATAL_REGEN_SAMPLES 5
#define FATAL_DAMAGE_SLACK_PERCENT 10
typedef struct { uint64_t ns; int damage; } FatalHit;
typedef struct {
 uintptr_t player,connection,map;
 int64_t pending,projected,overflow;
 int attempted,blocking,reason,last_hp,have_hp;
 uint64_t last_update_ns,cadence_anchor_ns,interval_ns,jitter_ns,snapshots;
 uint64_t last_damage_ns,damage_sequence,last_tick_ns,healthy_since_ns;
 uint64_t rebases,last_rebase_ns,last_hp_ns;
 /* HP decreases no tracked prefix of hits can explain; evidence of untracked loss. */
 uint64_t unexplained;int64_t last_unexplained;
 int64_t regen_rates[FATAL_REGEN_SAMPLES];unsigned regen_count,regen_head; /* HP per second */
 int64_t last_rebase_pending;
 uint32_t tick_sequence,server_time;
 unsigned have_tick;
 unsigned head,count;
 FatalHit hits[FATAL_HIT_CAPACITY];
} FatalPolicy;
static inline void fatal_reset(FatalPolicy *p,uintptr_t player,uintptr_t connection,uintptr_t map) {
 *p=(FatalPolicy){.player=player,.connection=connection,.map=map,.interval_ns=200000000ULL};
}
/* Quiet settlement allowance, NOT a proven network bound or acknowledgement.
 * A full quiet interval AND healthy progressing ticks AND a new HP-bearing tick
 * are required. Never expire individual hits during continuing combat. */
static inline uint64_t fatal_window_ns(const FatalPolicy *p) {
 (void)p;
 return FATAL_QUIET_WINDOW_NS;
}
static inline void fatal_tick(FatalPolicy *p,uint64_t now) {
 if(p->last_update_ns && now<p->last_update_ns)return;
 if(p->cadence_anchor_ns && now-p->cadence_anchor_ns>=20000000ULL){
  uint64_t gap=now-p->cadence_anchor_ns;
  if(gap>1000000000ULL)gap=1000000000ULL;
  uint64_t deviation=gap>p->interval_ns?gap-p->interval_ns:p->interval_ns-gap;
  p->interval_ns=(7*p->interval_ns+gap)/8;
  p->jitter_ns=deviation>p->jitter_ns?deviation:7*p->jitter_ns/8;
  p->cadence_anchor_ns=now;
 } else if(!p->cadence_anchor_ns)p->cadence_anchor_ns=now;
 p->last_update_ns=now;
}
static inline void fatal_pop(FatalPolicy *p) {
 p->pending-=p->hits[p->head].damage;
 p->head=(p->head+1)%FATAL_HIT_CAPACITY;--p->count;
}
/* Regeneration that could have offset part of a drop since the last snapshot. */
static inline int64_t fatal_regen_rate(const FatalPolicy *p) {
 if(!p->regen_count)return FATAL_REGEN_HP_PER_S;
 int64_t sorted[FATAL_REGEN_SAMPLES];unsigned n=p->regen_count;
 for(unsigned i=0;i<n;++i){
  int64_t v=p->regen_rates[i];unsigned j=i;
  for(;j && sorted[j-1]>v;--j)sorted[j]=sorted[j-1];
  sorted[j]=v;
 }
 int64_t median=sorted[n/2];
 return median<FATAL_REGEN_MAX_HP_PER_S?median:FATAL_REGEN_MAX_HP_PER_S;
}
static inline int64_t fatal_regen_tolerance(const FatalPolicy *p,uint64_t now) {
 uint64_t elapsed=p->last_hp_ns && now>p->last_hp_ns?now-p->last_hp_ns:0;
 if(elapsed>1000000000ULL)elapsed=1000000000ULL;
 return 1+(int64_t)((elapsed*(uint64_t)fatal_regen_rate(p)+999999999ULL)/1000000000ULL);
}
static inline void fatal_regen_sample(FatalPolicy *p,int hp,uint64_t now) {
 if(!p->have_hp || hp<=p->last_hp || !p->last_hp_ns || now<p->last_hp_ns+FATAL_MIN_TICK_GAP_NS)return;
 int64_t rate=(int64_t)(((uint64_t)(hp-p->last_hp)*1000000000ULL)/(now-p->last_hp_ns));
 p->regen_rates[p->regen_head]=rate;p->regen_head=(p->regen_head+1)%FATAL_REGEN_SAMPLES;
 if(p->regen_count<FATAL_REGEN_SAMPLES)++p->regen_count;
}
static inline void fatal_server_hp(FatalPolicy *p,int hp,uint64_t now) {
 if(p->last_update_ns && now<p->last_update_ns)return;
 ++p->snapshots;
 if(hp<=0 || p->blocking){
  p->pending=0;p->overflow=0;p->head=0;p->count=0;
 } else {
  fatal_regen_sample(p,hp,now);
  /* An HP increase is not a damage acknowledgement; the higher baseline itself
   * supplies observed healing credit exactly once. */
  int64_t debit=p->have_hp && p->last_hp>hp?(int64_t)p->last_hp-hp:0;
  if(debit>0 && p->overflow){
   /* Capacity escape already requested: keep the aggregate net-debit rule. */
   while(debit>0 && p->count){
    FatalHit *hit=&p->hits[p->head];
    if(debit>=hit->damage){debit-=hit->damage;fatal_pop(p);}
    else {hit->damage-=(int)debit;p->pending-=debit;debit=0;}
   }
   if(debit>0){int64_t credit=debit<p->overflow?debit:p->overflow;p->overflow-=credit;p->pending-=credit;}
  } else if(debit>0 && p->count){
   /* Retire whole hits only when the oldest ones explain the drop: their sum is
    * at least the drop and exceeds it by no more than possible regeneration plus
    * a small local overestimate. Anything else (a much smaller drop, or one larger
    * than every pending hit) may be untracked damage with the hits still
    * unapplied, so retire nothing and restart the quiet interval. Amounts inside
    * that window remain indistinguishable from the hits. */
   int64_t sum=0;unsigned k=0;
   while(k<p->count && sum<debit)sum+=p->hits[(p->head+k++)%FATAL_HIT_CAPACITY].damage;
   int64_t slack=fatal_regen_tolerance(p,now)+sum*FATAL_DAMAGE_SLACK_PERCENT/100;
   if(sum>=debit && sum-debit<=slack){while(k--)fatal_pop(p);}
   else {++p->unexplained;p->last_unexplained=debit;p->last_damage_ns=now;}
  }
 }
 p->last_hp=hp;p->have_hp=1;p->last_hp_ns=now;p->projected=(int64_t)hp-p->pending;
 if(hp>0 && !p->blocking){p->attempted=0;p->reason=FATAL_REASON_NONE;}
}
/* Called once after a completed authoritative tick, never from polling or a
 * standalone stat setter. entry_ns prevents handler runtime from aging reports.
 * sequence_at_entry prevents a reentrant new input being erased by this tick.
 * Timestamps are used only for progress; their clock is not compared with ours. */
static inline int fatal_server_tick(FatalPolicy *p,int hp,uint64_t entry_ns,
                                   uint32_t tick_sequence,uint32_t server_time,
                                   uint64_t sequence_at_entry,int hp_assigned) {
 if(p->last_update_ns && entry_ns<p->last_update_ns){p->healthy_since_ns=0;return 0;}
 if(p->have_tick){
  uint32_t ticks=tick_sequence-p->tick_sequence,stamp=server_time-p->server_time;
  if(!ticks || ticks>=0x80000000U || !stamp || stamp>=0x80000000U){
   p->healthy_since_ns=0;return 0;
  }
  uint64_t gap=entry_ns-p->last_tick_ns;
  if(gap<FATAL_MIN_TICK_GAP_NS || gap>FATAL_HEALTHY_GAP_NS || ticks!=1)
   p->healthy_since_ns=entry_ns;
 } else p->healthy_since_ns=entry_ns;
 if(!p->healthy_since_ns)p->healthy_since_ns=entry_ns;
 p->have_tick=1;p->tick_sequence=tick_sequence;p->server_time=server_time;
 p->last_tick_ns=entry_ns;fatal_tick(p,entry_ns);
 uint64_t window=fatal_window_ns(p);
 if(p->blocking || hp<=0 || !p->pending || !hp_assigned || !p->last_damage_ns ||
    sequence_at_entry!=p->damage_sequence || entry_ns<p->last_damage_ns ||
    entry_ns-p->last_damage_ns<window || entry_ns-p->healthy_since_ns<window)return 0;
 p->last_rebase_pending=p->pending;p->last_rebase_ns=entry_ns;++p->rebases;
 p->pending=0;p->overflow=0;p->head=0;p->count=0;
 p->last_hp=hp;p->have_hp=1;p->last_hp_ns=entry_ns;p->projected=hp;
 return 1;
}
static inline int fatal_damage(FatalPolicy *p,int hp,int damage,uint64_t now) {
 if(p->blocking)return FATAL_BLOCK;
 if(damage<0 || p->pending>INT64_MAX-damage)return FATAL_INVALID;
 if(hp<=0)return FATAL_LATE;
 if(!p->have_hp){p->have_hp=1;p->last_hp=hp;}
 if(!p->last_update_ns)fatal_tick(p,now);
 if(damage>0){
  p->last_damage_ns=now;++p->damage_sequence;
  if(p->count<FATAL_HIT_CAPACITY){
   p->hits[(p->head+p->count)%FATAL_HIT_CAPACITY]=(FatalHit){.ns=now,.damage=damage};++p->count;
  } else p->overflow+=damage;
 }
 p->pending+=damage;p->projected=(int64_t)hp-p->pending;
 uint64_t cadence=2*p->interval_ns+4*p->jitter_ns;
 if(cadence>2000000000ULL)cadence=2000000000ULL;
 uint64_t stale=3*cadence;if(stale<1500000000ULL)stale=1500000000ULL;
 int reason=p->pending>0 && p->projected<=0?FATAL_REASON_LETHAL:
     damage>0 && p->overflow>0?FATAL_REASON_CAPACITY:
     damage>0 && now>=p->last_update_ns && now-p->last_update_ns>stale?FATAL_REASON_STALE:FATAL_REASON_NONE;
 if(!p->attempted && reason){p->attempted=1;p->reason=reason;return FATAL_REQUEST;}
 return FATAL_PASS;
}
static inline void fatal_requested(FatalPolicy *p,int local_nexusing) { p->blocking=local_nexusing!=0; }
#endif
