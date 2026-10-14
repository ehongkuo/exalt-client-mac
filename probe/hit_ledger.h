#ifndef HIT_LEDGER_H
#define HIT_LEDGER_H
#include <limits.h>
#include <stdint.h>
enum { LEDGER_STABLE, LEDGER_NEW, LEDGER_HP_CHANGED, LEDGER_MAX_CHANGED, LEDGER_INVALID };
typedef struct { uintptr_t identity; uint64_t window; int hp,max,valid,crossed; int64_t pending; } HitLedger;
typedef struct { int valid,crossed; int64_t projected; } HitEstimate;
/* A window ends whenever the observed HP changes. This is a diagnostic hypothesis,
 * not acknowledgement-based reconciliation suitable for an armed guard. */
static inline int ledger_sample(HitLedger *s,uintptr_t identity,int hp,int max) {
    if(!identity || hp<0 || max<=0 || hp>max){s->valid=0;s->pending=0;return LEDGER_INVALID;}
    int reason=!s->valid||s->identity!=identity?LEDGER_NEW:s->max!=max?LEDGER_MAX_CHANGED:s->hp!=hp?LEDGER_HP_CHANGED:LEDGER_STABLE;
    if(reason!=LEDGER_STABLE){s->pending=0;s->crossed=0;++s->window;}
    s->identity=identity;s->hp=hp;s->max=max;s->valid=1;return reason;
}
static inline HitEstimate ledger_hit(HitLedger *s,int damage,int threshold) {
    if(!s->valid || damage<0 || threshold<0 || threshold>100 || s->pending>INT64_MAX-damage)
        return (HitEstimate){0};
    int64_t previous=(int64_t)s->hp-s->pending;
    s->pending+=damage;
    int64_t projected=(int64_t)s->hp-s->pending;
    int crossed=damage>0 && threshold>0 && !s->crossed && (double)previous*100>s->max*(double)threshold && (double)projected*100<=s->max*(double)threshold;
    if(crossed)s->crossed=1;
    return (HitEstimate){1,crossed,projected};
}
#endif
