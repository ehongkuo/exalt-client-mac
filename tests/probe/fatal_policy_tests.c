#include "../../probe/fatal_policy.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
 FatalPolicy p={0};fatal_reset(&p,1,2,3);
 assert(fatal_damage(&p,200,50)==FATAL_PASS);
 fatal_server_hp(&p,200); /* unchanged update cannot acknowledge the hit */
 assert(p.pending==50 && p.projected==150);
 assert(fatal_damage(&p,200,50)==FATAL_PASS);
 fatal_server_hp(&p,250); /* healing or stale higher HP cannot restore the bound */
 assert(p.pending==100 && p.projected==100);
 assert(fatal_damage(&p,250,50)==FATAL_PASS && p.projected==50);
 assert(fatal_damage(&p,250,50)==FATAL_REQUEST && p.projected==0);
 fatal_requested(&p,1);fatal_server_hp(&p,250);
 assert(p.pending==200 && p.projected==0 && p.blocking);
 assert(fatal_damage(&p,250,50)==FATAL_BLOCK);
 fatal_reset(&p,1,2,4);
 assert(!p.pending && !p.has_bound && !p.blocking);
 assert(fatal_damage(&p,200,50)==FATAL_PASS); /* projectile */
 fatal_server_hp(&p,180); /* unidentified DOT or a report: no false acknowledgement */
 assert(p.pending==50 && p.projected==130);
 assert(fatal_damage(&p,180,60)==FATAL_PASS && p.projected==70); /* ground */
 fatal_server_hp(&p,180);
 assert(fatal_damage(&p,180,70)==FATAL_REQUEST && p.projected==0); /* area */
 fatal_requested(&p,0);
 assert(fatal_damage(&p,180,50)==FATAL_PASS && p.attempted && p.pending==230);
 fatal_server_hp(&p,180);assert(!p.attempted && !p.blocking && p.pending==230);
 assert(fatal_damage(&p,180,1)==FATAL_REQUEST); /* retry after update, no same-burst request loop */
 fatal_reset(&p,1,2,5);
 assert(fatal_damage(&p,0,100)==FATAL_LATE);
 assert(fatal_damage(&p,100,-1)==FATAL_INVALID);
 assert(fatal_damage(&p,100,0)==FATAL_PASS && !p.attempted);
 p.pending=INT64_MAX;p.projected=INT64_MIN;p.has_bound=1;
 assert(fatal_damage(&p,100,1)==FATAL_INVALID);
 fatal_server_hp(&p,INT_MIN);assert(p.projected==INT64_MIN);
 puts("Fatal policy: delayed HP, healing, mixed damage, scope reset, failed request and overflow passed");
}
