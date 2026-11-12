#ifndef FATAL_POLICY_H
#define FATAL_POLICY_H
/* Candidate policy v10 (hardening plan Phase 1): a pending hit clears only by the ordering proof.
 * Hit reports and tick replies share one ordered connection, so once a tick's round-trip field
 * dates the server's receipt of a reply sent after a hit, the hit reached the server by then.
 * HP changes and elapsed time never clear a hit; server HP is only the baseline. */
#include <stdint.h>
#include <limits.h>
enum { FATAL_PASS, FATAL_REQUEST, FATAL_BLOCK, FATAL_LATE, FATAL_INVALID };
enum { FATAL_REASON_NONE, FATAL_REASON_LETHAL, FATAL_REASON_STALE, FATAL_REASON_CAPACITY };
#define FATAL_HIT_CAPACITY 128
#define FATAL_REPLY_CAPACITY 64  /* Older replies can't be dated, which only delays clearing. */
#define FATAL_PROOF_CAPACITY 16  /* Dropping the oldest proof only delays clearing: newer ones cover more. */
#ifndef FATAL_PROOF_MARGIN_MS
#define FATAL_PROOF_MARGIN_MS 200 /* c: measured 0 with 91 ms margin, plus one update interval. */
#endif
typedef struct { uint64_t ns,reply; int damage; } FatalHit;
typedef struct { uint64_t replies; uint32_t bound; } FatalProof;
typedef struct {
 uintptr_t player,connection,map;
 int64_t pending,projected,overflow;
 int drain; /* Phase 3 G: damage over time expected before the next update. */
 int attempted,blocking,reason,last_hp,have_hp;
 uint64_t last_update_ns,cadence_anchor_ns,interval_ns,jitter_ns,snapshots;
 uint64_t replies,proved,overflow_reply,proofs,cleared;
 uint32_t tick_sequence,server_time,rtt;
 unsigned have_tick,head,count,proof_head,proof_count;
 uint32_t reply_build[FATAL_REPLY_CAPACITY];
 FatalProof proof[FATAL_PROOF_CAPACITY];
 FatalHit hits[FATAL_HIT_CAPACITY];
} FatalPolicy;
static inline void fatal_reset(FatalPolicy *p,uintptr_t player,uintptr_t connection,uintptr_t map) {
 *p=(FatalPolicy){.player=player,.connection=connection,.map=map,.interval_ns=200000000ULL};
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
static inline void fatal_clear_all(FatalPolicy *p) { p->pending=0;p->overflow=0;p->head=0;p->count=0; }
/* Server HP is the baseline only: it already includes every heal and untracked loss. */
static inline void fatal_server_hp(FatalPolicy *p,int hp,uint64_t now) {
 if(p->last_update_ns && now<p->last_update_ns)return;
 ++p->snapshots;
 if(hp<=0 || p->blocking)fatal_clear_all(p);
 p->last_hp=hp;p->have_hp=1;p->projected=(int64_t)hp-p->pending-p->drain;
 if(hp>0 && !p->blocking){p->attempted=0;p->reason=FATAL_REASON_NONE;}
}
/* Called when the client sends its reply to the tick built at server_time, in send order. */
static inline void fatal_reply(FatalPolicy *p,uint32_t server_time) {
 p->reply_build[p->replies++%FATAL_REPLY_CAPACITY]=server_time;
}
/* Called once per completed tick with its build time and round-trip field (ms). Returns the
 * number of hits cleared. Build times are compared by signed difference, so they may wrap. */
static inline int fatal_server_tick(FatalPolicy *p,uint64_t entry_ns,uint32_t tick_sequence,
                                    uint32_t server_time,uint32_t rtt) {
 if(p->last_update_ns && entry_ns<p->last_update_ns)return 0;
 uint32_t previous=p->server_time,previous_rtt=p->rtt;int had=p->have_tick;
 if(had && (!(tick_sequence-p->tick_sequence) || (int32_t)(server_time-previous)<=0))return 0;
 p->have_tick=1;p->tick_sequence=tick_sequence;p->server_time=server_time;
 if(rtt)p->rtt=rtt; /* 0: no field read for this tick; keep the last value. */
 fatal_tick(p,entry_ns);
 /* A repeated value may mean no new reply arrived, so it proves nothing. */
 if(had && rtt && rtt!=previous_rtt){
  uint64_t first=p->replies>FATAL_REPLY_CAPACITY?p->replies-FATAL_REPLY_CAPACITY:0;
  for(uint64_t k=first;k<p->replies;++k){
   uint32_t bound=p->reply_build[k%FATAL_REPLY_CAPACITY]+rtt;
   if((int32_t)(bound-previous)>0 && (int32_t)(server_time-bound)>=0){ /* Oldest match proves least. */
    if(p->proof_count==FATAL_PROOF_CAPACITY){p->proof_head=(p->proof_head+1)%FATAL_PROOF_CAPACITY;--p->proof_count;}
    p->proof[(p->proof_head+p->proof_count++)%FATAL_PROOF_CAPACITY]=(FatalProof){.replies=k+1,.bound=bound};
    ++p->proofs;break;
   }
  }
 }
 /* Bounds rise with each tick, so due proofs are at the head. */
 while(p->proof_count){
  FatalProof *f=&p->proof[p->proof_head];
  if((int32_t)(server_time-f->bound)<FATAL_PROOF_MARGIN_MS)break;
  if(f->replies>p->proved)p->proved=f->replies;
  p->proof_head=(p->proof_head+1)%FATAL_PROOF_CAPACITY;--p->proof_count;
 }
 int cleared=0;
 while(p->count && p->hits[p->head].reply<p->proved){
  p->pending-=p->hits[p->head].damage;p->head=(p->head+1)%FATAL_HIT_CAPACITY;--p->count;++cleared;
 }
 if(p->overflow && !p->count && p->overflow_reply<p->proved){p->pending-=p->overflow;p->overflow=0;}
 p->cleared+=cleared;
 if(p->have_hp)p->projected=(int64_t)p->last_hp-p->pending-p->drain;
 return cleared;
}
/* Phase 3 G rates in HP per second: bleeding 4 per 200 ms update, frostbite the 33 per update
 * worst case measured in the Ice Citadel, suffocation about 100/s (approximate until captured). */
#define FATAL_BLEED_HP_S 20
#define FATAL_FROSTBITE_HP_S 165
#define FATAL_SUFFOCATION_HP_S 100
#define FATAL_BLEEDING 0x8000u  /* condition word 0 */
#define FATAL_FROSTBITE_FULL 100
/* Sets the drain expected over one update interval from the player's condition word 0 and the
 * breath and frostbite meters (-1 when the map has none). Call before fatal_damage. */
static inline void fatal_drain(FatalPolicy *p,uint32_t conditions,int breath,int frostbite) {
 uint64_t rate=(conditions&FATAL_BLEEDING?FATAL_BLEED_HP_S:0)+(frostbite>=FATAL_FROSTBITE_FULL?FATAL_FROSTBITE_HP_S:0)+
               (breath==0?FATAL_SUFFOCATION_HP_S:0);
 p->drain=(int)((rate*p->interval_ns+999999999ULL)/1000000000ULL);
}
static inline int fatal_damage(FatalPolicy *p,int hp,int damage,uint64_t now) {
 if(p->blocking)return FATAL_BLOCK;
 if(damage<0 || p->pending>INT64_MAX-damage)return FATAL_INVALID;
 if(hp<=0)return FATAL_LATE;
 if(!p->have_hp){p->have_hp=1;p->last_hp=hp;}
 if(!p->last_update_ns)fatal_tick(p,now);
 if(damage>0){
  /* Paired with the next reply the client sends, which travels behind this report. */
  if(p->count<FATAL_HIT_CAPACITY && !p->overflow){
   p->hits[(p->head+p->count)%FATAL_HIT_CAPACITY]=(FatalHit){.ns=now,.reply=p->replies,.damage=damage};++p->count;
  } else {p->overflow+=damage;p->overflow_reply=p->replies;}
 }
 p->pending+=damage;p->projected=(int64_t)hp-p->pending-p->drain;
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
