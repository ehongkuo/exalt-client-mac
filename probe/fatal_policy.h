#ifndef FATAL_POLICY_H
#define FATAL_POLICY_H
#include <stdint.h>
#include <limits.h>
enum { FATAL_PASS, FATAL_REQUEST, FATAL_BLOCK, FATAL_LATE, FATAL_INVALID };
typedef struct {
 uintptr_t player,connection,map;
 int64_t pending,projected;
 int attempted,blocking,has_bound;
} FatalPolicy;
/* Negative breath is the inactive sentinel. Zero means exhausted; frostbite
 * values above 100 occur in the live trace and must also trigger. */
static inline int fatal_environment_hazard(int breath,int frostbite) {
 if(frostbite>=100)return 1;
 if(breath==0)return 2;
 return 0;
}
static inline void fatal_reset(FatalPolicy *p,uintptr_t player,uintptr_t connection,uintptr_t map) {
 *p=(FatalPolicy){.player=player,.connection=connection,.map=map};
}
/* HP values do not acknowledge particular reports. Retain all uncertain damage
 * until the validated player/connection/map scope changes. The bound cannot rise
 * on healing, repeated or stale assignments; this deliberately escapes early. */
static inline int64_t fatal_candidate(const FatalPolicy *p,int hp) {
 if(hp<0 && p->pending>INT64_MAX+(int64_t)hp+1)return INT64_MIN;
 return (int64_t)hp-p->pending;
}
static inline void fatal_server_hp(FatalPolicy *p,int hp) {
 int64_t candidate=fatal_candidate(p,hp);
 if(!p->has_bound || candidate<p->projected)p->projected=candidate;
 p->has_bound=1;
 /* Permit one new request after another live HP update, never clear an escape. */
 if(hp>0 && !p->blocking)p->attempted=0;
}
static inline int fatal_damage(FatalPolicy *p,int hp,int damage) {
 if(p->blocking)return FATAL_BLOCK;
 if(damage<0 || p->pending>INT64_MAX-damage)return FATAL_INVALID;
 if(hp<=0)return FATAL_LATE;
 int64_t previous=p->projected;
 p->pending+=damage;
 int64_t candidate=fatal_candidate(p,hp);
 if(p->has_bound){
  int64_t debited=previous<INT64_MIN+damage?INT64_MIN:previous-damage;
  if(debited<candidate)candidate=debited;
 }
 p->projected=candidate;p->has_bound=1;
 if(!p->attempted && p->pending>0 && p->projected<=0){p->attempted=1;return FATAL_REQUEST;}
 return FATAL_PASS;
}
static inline void fatal_requested(FatalPolicy *p,int local_nexusing) { p->blocking=local_nexusing!=0; }
#endif
