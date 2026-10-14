#include "../../probe/hit_ledger.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
 HitLedger s={0};
 assert(ledger_sample(&s,1,800,1000)==LEDGER_NEW);
 HitEstimate a=ledger_hit(&s,250,25);
 assert(a.projected==550 && !a.crossed);
 a=ledger_hit(&s,250,25);assert(a.projected==300 && !a.crossed);
 a=ledger_hit(&s,250,25);assert(a.projected==50 && a.crossed);
 a=ledger_hit(&s,250,25);assert(a.projected==-200 && !a.crossed);
 assert(ledger_sample(&s,1,50,1000)==LEDGER_HP_CHANGED);
 assert(s.pending==0 && s.window==2);
 a=ledger_hit(&s,0,25);assert(a.projected==50 && !a.crossed);
 assert(ledger_sample(&s,1,200,1000)==LEDGER_HP_CHANGED);
 a=ledger_hit(&s,50,25);assert(a.projected==150 && !a.crossed);
 assert(ledger_sample(&s,2,800,1000)==LEDGER_NEW);
 a=ledger_hit(&s,800,25);assert(a.projected==0 && a.crossed);
 assert(ledger_sample(&s,2,800,1100)==LEDGER_MAX_CHANGED);
 a=ledger_hit(&s,-1,25);assert(!a.valid && s.pending==0);
 a=ledger_hit(&s,1,0);assert(a.valid && !a.crossed);
 assert(ledger_sample(&s,0,800,1000)==LEDGER_INVALID);
 a=ledger_hit(&s,250,25);assert(!a.valid);
 puts("Same-frame burst, projected death, changed HP, healing, identity, max and invalid inputs passed");
}
