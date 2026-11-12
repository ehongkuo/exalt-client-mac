#include "../../probe/fatal_policy_v10.h"
#include <assert.h>
#include <stdio.h>
#define MS(x) ((uint64_t)(x)*1000000ULL+1)
/* Ticks every 200 ms, built at base + 200 j, each answered by one reply, as in test_proof.py. */
static uint32_t base=1000;
static int tick(FatalPolicy *p,int j,int hp,uint32_t rtt) {
 fatal_server_hp(p,hp,MS(200*j));
 int cleared=fatal_server_tick(p,MS(200*j),(uint32_t)j+1,base+200U*(uint32_t)j,rtt);
 fatal_reply(p,base+200U*(uint32_t)j);
 return cleared;
}
static void invariant(const FatalPolicy *p) {
 int64_t sum=p->overflow;
 assert(p->count<=FATAL_HIT_CAPACITY && p->head<FATAL_HIT_CAPACITY);
 for(unsigned i=0;i<p->count;++i)sum+=p->hits[(p->head+i)%FATAL_HIT_CAPACITY].damage;
 assert(sum==p->pending && sum>=0);
}
static void hit(FatalPolicy *p,int hp,int damage,int ms) {assert(fatal_damage(p,hp,damage,MS(ms))==FATAL_PASS);}
/* Runs ticks 0..n-1 with one 60 hit at 50 ms; returns the tick that cleared it, or -1. */
static int run(const uint32_t *rtts,int n) {
 FatalPolicy p;fatal_reset(&p,1,2,3);int at=-1;
 for(int j=0;j<n;++j){
  if(tick(&p,j,300,rtts[j]) && at<0)at=j;
  if(!j)hit(&p,300,60,50);
  invariant(&p);
 }
 return at;
}
int main(void) {
 FatalPolicy p;

 /* Tick 3's new round trip 300 dates reply 1 (sent after the hit) at 1500; with c = 200 the
  * first update built at or after 1700 clears it: tick 4. */
 assert(run((uint32_t[]){250,260,310,300,290,280},6)==4);
 /* A repeated round trip proves nothing; tick 4's 500 dates reply 1 at 1700, cleared at tick 5. */
 assert(run((uint32_t[]){250,260,310,310,500,280},6)==5);
 /* A proof of the reply sent before the hit proves nothing about it. */
 assert(run((uint32_t[]){250,260,310,310,310,310},6)==-1);
 /* Build times may wrap. */
 base=0xffffff00U;assert(run((uint32_t[]){250,260,310,300,290,280},6)==4);base=1000;

 /* HP drops never clear hits: an untracked 112 loss with a 113 hit pending leaves it pending (B). */
 fatal_reset(&p,1,2,3);tick(&p,0,900,250);hit(&p,900,113,50);
 tick(&p,1,788,250);assert(p.pending==113 && p.projected==675);
 /* A hit the server reduced (93 at full HP, HP changed by 2) clears by proof; HP is then the truth. */
 fatal_reset(&p,1,2,3);tick(&p,0,500,250);hit(&p,500,93,50);
 tick(&p,1,498,260);tick(&p,2,498,310);tick(&p,3,498,300);assert(p.pending==93);
 tick(&p,4,498,290);assert(!p.pending && p.projected==498 && p.cleared==1);

 /* A stall (834 ms late hit, no new round trip) keeps the hit pending: no quiet rebase (A). */
 fatal_reset(&p,1,2,3);tick(&p,0,400,250);hit(&p,400,80,50);
 for(int j=1;j<=15;++j)tick(&p,j,320,250);
 assert(p.pending==80 && p.projected==240);
 /* ... and a heal without text doesn't clear it either (D). */
 tick(&p,16,400,250);assert(p.pending==80);

 /* Final burst of the heal session: server HP 481 with 417 pending; the next 99 is lethal. */
 fatal_reset(&p,1,2,3);tick(&p,0,481,250);
 hit(&p,481,113,10);hit(&p,481,103,110);hit(&p,481,98,210);hit(&p,481,103,310);
 assert(fatal_damage(&p,481,99,MS(410))==FATAL_REQUEST && p.reason==FATAL_REASON_LETHAL && p.projected==-35);

 /* A tick without the field (0) keeps the last value, so the same value after it is no proof. */
 fatal_reset(&p,1,2,3);tick(&p,0,300,250);hit(&p,300,60,50);
 tick(&p,1,300,260);tick(&p,2,300,310);tick(&p,3,300,0);tick(&p,4,300,310);tick(&p,5,300,310);
 assert(p.pending==60 && p.rtt==310);

 /* A non-progressing tick is ignored. */
 fatal_reset(&p,1,2,3);tick(&p,0,300,250);
 assert(!fatal_server_tick(&p,MS(250),1,base,999) && p.rtt==250);

 /* Stale and capacity escapes are unchanged; overflow clears once its reply is proven. */
 fatal_reset(&p,1,2,3);tick(&p,0,300,250);
 assert(fatal_damage(&p,300,1,MS(2000))==FATAL_REQUEST && p.reason==FATAL_REASON_STALE);
 fatal_reset(&p,1,2,3);tick(&p,0,100000,250);
 for(int i=0;i<FATAL_HIT_CAPACITY;++i)hit(&p,100000,1,1+i/10);
 assert(fatal_damage(&p,100000,1,MS(20))==FATAL_REQUEST && p.reason==FATAL_REASON_CAPACITY);
 hit(&p,100000,1,30);invariant(&p);assert(p.overflow==2);
 tick(&p,1,100000,260);tick(&p,2,100000,310);tick(&p,3,100000,300);tick(&p,4,100000,290);
 assert(!p.pending && !p.overflow && !p.count);

 /* Phase 3 G drain over one 200 ms update: bleeding 4, full frostbite 33, no oxygen 20. */
 fatal_reset(&p,1,2,3);tick(&p,0,64,250);tick(&p,1,64,250);
 fatal_drain(&p,0,-1,-1);assert(p.drain==0);
 fatal_drain(&p,0x8000,-1,-1);assert(p.drain==4);
 fatal_drain(&p,0x7fff,-1,99);assert(p.drain==0);   /* other bits, frostbite not yet full */
 fatal_drain(&p,0,-1,100);assert(p.drain==33);
 fatal_drain(&p,0,-1,101);assert(p.drain==33);
 fatal_drain(&p,0,0,-1);assert(p.drain==20);         /* breath 0: suffocating */
 fatal_drain(&p,0,50,-1);assert(p.drain==0);
 fatal_drain(&p,0x8000,0,100);assert(p.drain==57);
 /* A 60 hit at 64 HP survives alone but is lethal while bleeding. */
 fatal_drain(&p,0,-1,-1);assert(fatal_damage(&p,64,60,MS(250))==FATAL_PASS && p.projected==4);
 fatal_reset(&p,1,2,3);tick(&p,0,64,250);tick(&p,1,64,250);fatal_drain(&p,0x8000,-1,-1);
 assert(fatal_damage(&p,64,60,MS(250))==FATAL_REQUEST && p.reason==FATAL_REASON_LETHAL && p.projected==0);
 /* The drain stays in the projection across updates and scales with the measured interval. */
 tick(&p,2,64,260);assert(p.projected==64-60-4);
 p.interval_ns=400000000ULL;fatal_drain(&p,0,0,-1);assert(p.drain==40);
 /* Drain alone, with no hit pending, never escapes. */
 fatal_reset(&p,1,2,3);tick(&p,0,10,250);fatal_drain(&p,0,0,-1);
 assert(fatal_damage(&p,10,0,MS(50))==FATAL_PASS && p.projected==-10);

 /* Death or a requested Nexus clears everything. */
 fatal_reset(&p,1,2,3);tick(&p,0,300,250);hit(&p,300,60,50);fatal_server_hp(&p,0,MS(100));
 assert(!p.pending);
 puts("fatal policy v10 tests passed");
 return 0;
}
