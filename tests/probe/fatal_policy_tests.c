#include "../../probe/fatal_policy.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
 FatalPolicy p={0};fatal_reset(&p,1,2,3);
 assert(fatal_damage(&p,200,50)==FATAL_PASS);
 assert(fatal_damage(&p,200,50)==FATAL_PASS);
 assert(fatal_damage(&p,200,50)==FATAL_PASS);
 assert(fatal_damage(&p,200,50)==FATAL_REQUEST);
 assert(p.projected==0 && p.pending==200);
 fatal_requested(&p,1);
 assert(fatal_damage(&p,200,50)==FATAL_BLOCK && p.pending==200);
 fatal_reset(&p,1,2,4);
 assert(p.pending==0 && !p.blocking);
 assert(fatal_damage(&p,100,50)==FATAL_PASS);
 fatal_server_hp(&p,50);
 assert(p.pending==0 && p.projected==50);
 assert(fatal_damage(&p,50,25)==FATAL_PASS);
 assert(p.projected==25 && p.pending==25);
 fatal_server_hp(&p,50); /* unchanged HP still replaces the baseline */
 assert(p.pending==0 && p.projected==50);
 assert(fatal_damage(&p,50,50)==FATAL_REQUEST);
 fatal_requested(&p,1);fatal_server_hp(&p,100);
 assert(p.pending==0 && p.projected==100 && p.blocking && p.attempted);
 assert(fatal_damage(&p,100,25)==FATAL_BLOCK);
 fatal_requested(&p,0);assert(!p.blocking);
 assert(fatal_damage(&p,100,50)==FATAL_PASS); /* no repeat requests after failure */
 fatal_reset(&p,1,2,5);assert(fatal_damage(&p,0,100)==FATAL_LATE);
 assert(fatal_damage(&p,100,-1)==FATAL_INVALID);
 fatal_reset(&p,1,2,5);assert(fatal_damage(&p,100,0)==FATAL_PASS);
 puts("Fatal policy: burst, server HP reconciliation, one request, failure and reset passed");
}
