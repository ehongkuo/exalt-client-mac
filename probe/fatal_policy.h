#ifndef FATAL_POLICY_H
#define FATAL_POLICY_H
#include <stdint.h>
#include <limits.h>
enum { FATAL_PASS, FATAL_REQUEST, FATAL_BLOCK, FATAL_LATE, FATAL_INVALID };
typedef struct {
 uintptr_t player,connection,map;
 int64_t pending,projected;
 int attempted,blocking;
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
/* A new authoritative HP assignment starts a new prediction window, matching
 * the previously working client. Damage accumulates only until that boundary.
 * The assignment does not acknowledge individual reports; server ordering is
 * still a limitation. Never carry stale combat damage across healing forever. */
static inline void fatal_server_hp(FatalPolicy *p,int hp) {
 p->pending=0;p->projected=hp;
 if(hp>0 && !p->blocking)p->attempted=0;
}
static inline int fatal_damage(FatalPolicy *p,int hp,int damage) {
 if(p->blocking)return FATAL_BLOCK;
 if(damage<0 || p->pending>INT64_MAX-damage)return FATAL_INVALID;
 if(hp<=0)return FATAL_LATE;
 p->pending+=damage;p->projected=(int64_t)hp-p->pending;
 if(!p->attempted && p->pending>0 && p->projected<=0){p->attempted=1;return FATAL_REQUEST;}
 return FATAL_PASS;
}
static inline void fatal_requested(FatalPolicy *p,int local_nexusing) { p->blocking=local_nexusing!=0; }
#endif
