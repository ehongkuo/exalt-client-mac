#ifndef FATAL_POLICY_H
#define FATAL_POLICY_H
/* Candidate policy v9: per-hit settlement by accounting (docs/nexus-hardening-plan.md,
 * Phase 1 Rule 1). Not active: hit_probe.h still includes fatal_policy.h (v8). The API
 * matches v8 so probe/policy_replay.c can compile either, plus fatal_heal, fatal_drain
 * and fatal_regen. The ordering proof (Rule 2) is not implemented yet, and no rule clears
 * a hit because time passed: whatever accounting cannot clear stays pending. */
#include <stdint.h>
#include <limits.h>
enum { FATAL_PASS, FATAL_REQUEST, FATAL_BLOCK, FATAL_LATE, FATAL_INVALID };
enum { FATAL_REASON_NONE, FATAL_REASON_LETHAL, FATAL_REASON_STALE, FATAL_REASON_CAPACITY };
#define FATAL_POLICY_VERSION 9
#define FATAL_HIT_CAPACITY 128
#define FATAL_HEALTHY_GAP_NS 1000000000ULL
#define FATAL_MIN_TICK_GAP_NS 20000000ULL
#define FATAL_REGEN_DEFAULT 3 /* Captures show 1-3 HP per update. */
#define FATAL_REGEN_MAX 5
#define FATAL_HEAL_MAX 100000
typedef struct { uint64_t ns; int damage; } FatalHit;
typedef struct {
 uintptr_t player,connection,map;
 int64_t pending,projected,overflow;
 int attempted,blocking,reason,last_hp,have_hp;
 uint64_t last_update_ns,cadence_anchor_ns,interval_ns,jitter_ns,snapshots;
 uint64_t last_damage_ns,damage_sequence,last_tick_ns,healthy_since_ns;
 uint64_t rebases,last_rebase_ns; /* Always 0 in v9; kept for the replay output. */
 int64_t last_rebase_pending;
 uint32_t tick_sequence,server_time;
 unsigned have_tick;
 /* Accounting: heal text since the last HP observation, the damage-over-time allowance
  * per update, the regeneration residue limit, and the suspension latch. */
 int64_t heal;
 int drain,regen,suspended;
 uint64_t settled,residue_cleared,unexplained;
 unsigned head,count;
 FatalHit hits[FATAL_HIT_CAPACITY];
} FatalPolicy;
static inline void fatal_reset(FatalPolicy *p,uintptr_t player,uintptr_t connection,uintptr_t map) {
 *p=(FatalPolicy){.player=player,.connection=connection,.map=map,.interval_ns=200000000ULL,.regen=FATAL_REGEN_DEFAULT};
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
static inline void fatal_project(FatalPolicy *p,int hp) { p->projected=(int64_t)hp-p->pending-p->drain; }
static inline void fatal_pop(FatalPolicy *p) {
 p->pending-=p->hits[p->head].damage;
 p->head=(p->head+1)%FATAL_HIT_CAPACITY;--p->count;
}
/* Heal text shown over the player ("+N"). It arrives in the same frame as, and before,
 * the HP update that applies it, and equals the HP actually gained. It must be reported
 * before that update's fatal_server_hp; credit carries over until an HP observation. */
static inline void fatal_heal(FatalPolicy *p,int amount) {
 if(amount>0 && amount<=FATAL_HEAL_MAX && p->heal<INT64_MAX-amount)p->heal+=amount;
}
/* Damage-over-time allowance per update while an effect is active (0 when none). */
static inline void fatal_drain(FatalPolicy *p,int per_update) {
 p->drain=per_update>0?per_update:0;
 if(p->have_hp)fatal_project(p,p->last_hp);
}
/* Regeneration residue limit per update, capped at FATAL_REGEN_MAX. */
static inline void fatal_regen(FatalPolicy *p,int per_update) {
 p->regen=per_update<0?0:per_update>FATAL_REGEN_MAX?FATAL_REGEN_MAX:per_update;
}
/* Rule 1, accounting. The server applies hits in report order, so an observation that
 * applied A damage contains the oldest A of pending hits. A = heal text - HP change,
 * minus the drain allowance: regeneration is left out, so A is a lower bound. */
static inline void fatal_server_hp(FatalPolicy *p,int hp,uint64_t now) {
 if(p->last_update_ns && now<p->last_update_ns)return;
 ++p->snapshots;
 if(hp<=0 || p->blocking){
  p->pending=0;p->overflow=0;p->head=0;p->count=0;p->heal=0;
 } else if(p->have_hp){
  int64_t applied=p->heal+(int64_t)p->last_hp-hp-p->drain;p->heal=0;
  /* More applied than everything pending (plus regeneration) means a loss no report
   * explains: decreases can no longer be trusted for this map. */
  if(applied>p->pending+p->regen){++p->unexplained;p->suspended=1;}
  if(!p->suspended && applied>0){
   int64_t debit=applied;int partial=0;
   while(debit>0 && p->count){
    FatalHit *hit=&p->hits[p->head];
    if(debit>=hit->damage){debit-=hit->damage;fatal_pop(p);++p->settled;}
    else {hit->damage-=(int)debit;p->pending-=debit;debit=0;partial=1;}
   }
   if(debit>0 && p->overflow){int64_t credit=debit<p->overflow?debit:p->overflow;p->overflow-=credit;p->pending-=credit;}
   /* Only a hit this update partly cleared can be a regeneration residue; a small hit
    * that no update has touched stays pending. */
   if(partial && p->count && p->hits[p->head].damage<=p->regen){
    p->residue_cleared+=(uint64_t)p->hits[p->head].damage;fatal_pop(p);++p->settled;
   }
  }
 } else p->heal=0;
 p->last_hp=hp;p->have_hp=1;fatal_project(p,hp);
 if(hp>0 && !p->blocking){p->attempted=0;p->reason=FATAL_REASON_NONE;}
}
/* Called once after a completed authoritative tick. Tracks liveness and cadence for the
 * stale escape; it never clears hits (v8's 800 ms quiet rebase is removed). */
static inline int fatal_server_tick(FatalPolicy *p,int hp,uint64_t entry_ns,
                                   uint32_t tick_sequence,uint32_t server_time,
                                   uint64_t sequence_at_entry,int hp_assigned) {
 (void)hp;(void)sequence_at_entry;(void)hp_assigned;
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
 return 0;
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
 p->pending+=damage;fatal_project(p,hp);
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
