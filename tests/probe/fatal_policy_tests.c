#include "../../probe/fatal_policy.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
 FatalPolicy p={0};fatal_reset(&p,1,2,3);
 assert(fatal_damage(&p,200,50)==FATAL_PASS);
 assert(fatal_damage(&p,200,60)==FATAL_PASS && p.pending==110);
 assert(fatal_damage(&p,200,90)==FATAL_REQUEST && p.projected==0);
 fatal_requested(&p,1);fatal_server_hp(&p,250);
 assert(!p.pending && p.projected==250 && p.blocking);
 assert(fatal_damage(&p,250,50)==FATAL_BLOCK);
 fatal_reset(&p,1,2,4);
 assert(!p.pending && !p.blocking);
 /* Live false escape: prior 703 damage, recovery, 10 damage, more healing,
  * then three 110 hits at 1206 HP. Version 2 incorrectly predicted -108. */
 assert(fatal_damage(&p,935,703)==FATAL_PASS);
 fatal_server_hp(&p,1154);
 assert(fatal_damage(&p,1154,10)==FATAL_PASS);
 const int healing[]={1169,1174,1189,1204,1206};
 for(unsigned i=0;i<sizeof healing/sizeof *healing;++i)fatal_server_hp(&p,healing[i]);
 for(int i=0;i<3;++i)assert(fatal_damage(&p,1206,110)==FATAL_PASS);
 assert(p.pending==330 && p.projected==876);
 /* A full-HP update may include damage offset by healing. It must rebase too. */
 fatal_server_hp(&p,1206);assert(!p.pending && p.projected==1206);
 for(int i=0;i<1000;++i){assert(fatal_damage(&p,1206,110)==FATAL_PASS);fatal_server_hp(&p,1206);}
 fatal_reset(&p,1,2,5);
 assert(fatal_damage(&p,100,100)==FATAL_REQUEST);fatal_requested(&p,0);
 assert(fatal_damage(&p,100,1)==FATAL_PASS && p.attempted);
 fatal_server_hp(&p,40);assert(!p.attempted && !p.pending);
 assert(fatal_damage(&p,40,50)==FATAL_REQUEST);
 fatal_reset(&p,1,2,6);
 assert(fatal_damage(&p,0,100)==FATAL_LATE);
 assert(fatal_damage(&p,100,-1)==FATAL_INVALID);
 assert(fatal_damage(&p,100,0)==FATAL_PASS && !p.attempted);
 p.pending=INT64_MAX;assert(fatal_damage(&p,100,1)==FATAL_INVALID);
 fatal_server_hp(&p,INT_MIN);assert(p.projected==INT_MIN && !p.pending);
 puts("Fatal policy: authoritative windows, full-HP recovery regression, mixed bursts, failure retry and overflow passed");
}
