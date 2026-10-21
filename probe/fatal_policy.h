#ifndef FATAL_POLICY_H
#define FATAL_POLICY_H
#include <stdint.h>
#include <limits.h>
enum { FATAL_PASS, FATAL_REQUEST, FATAL_BLOCK, FATAL_LATE, FATAL_INVALID };
enum { FATAL_REASON_NONE, FATAL_REASON_LETHAL, FATAL_REASON_STALE, FATAL_REASON_CAPACITY };
#define FATAL_HIT_CAPACITY 128
#define FATAL_MIN_WINDOW_NS 400000000ULL
#define FATAL_MAX_WINDOW_NS 2000000000ULL
typedef struct { uint64_t ns; int damage; } FatalHit;
typedef struct {
 uintptr_t player,connection,map;
 int64_t pending,projected,overflow;
 int attempted,blocking,reason,last_hp,have_hp;
 uint64_t last_update_ns,cadence_anchor_ns,interval_ns,jitter_ns,snapshots;
 unsigned head,count;
 FatalHit hits[FATAL_HIT_CAPACITY];
} FatalPolicy;
static inline void fatal_reset(FatalPolicy *p,uintptr_t player,uintptr_t connection,uintptr_t map) {
 *p=(FatalPolicy){.player=player,.connection=connection,.map=map,.interval_ns=200000000ULL};
}
/* Timing is a bounded heuristic, NOT a per-hit server acknowledgement. */
static inline uint64_t fatal_window_ns(const FatalPolicy *p) {
 uint64_t window=2*p->interval_ns+4*p->jitter_ns;
 return window<FATAL_MIN_WINDOW_NS?FATAL_MIN_WINDOW_NS:window>FATAL_MAX_WINDOW_NS?FATAL_MAX_WINDOW_NS:window;
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
static inline void fatal_server_hp(FatalPolicy *p,int hp,uint64_t now) {
 fatal_tick(p,now);++p->snapshots;
 if(hp<=0 || p->blocking){
  p->pending=0;p->overflow=0;p->head=0;p->count=0;
 } else {
  /* Net HP loss retires the oldest estimates first. Healing may mask damage,
   * so this can retain too much; an HP increase is not a damage acknowledgement.
   * The higher baseline itself supplies observed healing credit exactly once. */
  int64_t debit=p->have_hp && p->last_hp>hp?(int64_t)p->last_hp-hp:0;
  while(debit>0 && p->count){
   FatalHit *hit=&p->hits[p->head];
   if(debit>=hit->damage){debit-=hit->damage;fatal_pop(p);}
   else {hit->damage-=(int)debit;p->pending-=debit;debit=0;}
  }
  if(debit>0 && p->overflow){int64_t credit=debit<p->overflow?debit:p->overflow;p->overflow-=credit;p->pending-=credit;}
  /* Age retirement requires a fresh HP observation. A local hit cannot erase
   * estimates merely because a timer elapsed during a network stall. */
  uint64_t window=fatal_window_ns(p);
  while(p->count && now>=p->hits[p->head].ns && now-p->hits[p->head].ns>=window)fatal_pop(p);
 }
 p->last_hp=hp;p->have_hp=1;p->projected=(int64_t)hp-p->pending;
 if(hp>0 && !p->blocking){p->attempted=0;p->reason=FATAL_REASON_NONE;}
}
static inline int fatal_damage(FatalPolicy *p,int hp,int damage,uint64_t now) {
 if(p->blocking)return FATAL_BLOCK;
 if(damage<0 || p->pending>INT64_MAX-damage)return FATAL_INVALID;
 if(hp<=0)return FATAL_LATE;
 if(!p->have_hp){p->have_hp=1;p->last_hp=hp;}
 if(!p->last_update_ns)fatal_tick(p,now);
 if(damage>0){
  if(p->count<FATAL_HIT_CAPACITY){
   p->hits[(p->head+p->count)%FATAL_HIT_CAPACITY]=(FatalHit){.ns=now,.damage=damage};++p->count;
  } else p->overflow+=damage;
 }
 p->pending+=damage;p->projected=(int64_t)hp-p->pending;
 uint64_t stale=3*fatal_window_ns(p);if(stale<1500000000ULL)stale=1500000000ULL;
 int reason=p->pending>0 && p->projected<=0?FATAL_REASON_LETHAL:
     damage>0 && p->overflow>0?FATAL_REASON_CAPACITY:
     damage>0 && now>=p->last_update_ns && now-p->last_update_ns>stale?FATAL_REASON_STALE:FATAL_REASON_NONE;
 if(!p->attempted && reason){p->attempted=1;p->reason=reason;return FATAL_REQUEST;}
 return FATAL_PASS;
}
static inline void fatal_requested(FatalPolicy *p,int local_nexusing) { p->blocking=local_nexusing!=0; }
#endif
