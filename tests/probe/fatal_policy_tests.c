#include "../../probe/fatal_policy.h"
#include <assert.h>
#include <stdio.h>
#define MS(x) ((uint64_t)(x)*1000000ULL+1)
static void fresh(FatalPolicy *p,int hp) {fatal_reset(p,1,2,3);fatal_server_hp(p,hp,MS(0));(void)fatal_server_tick(p,hp,MS(0),1,1000,0,1);}
static int tick(FatalPolicy *p,int hp,int ms,int has_hp) {
 fatal_server_hp(p,hp,MS(ms));
 return fatal_server_tick(p,hp,MS(ms),p->tick_sequence+1,p->server_time+200,p->damage_sequence,has_hp);
}
static void invariant(const FatalPolicy *p) {
 int64_t sum=p->overflow;
 assert(p->count<=FATAL_HIT_CAPACITY && p->head<FATAL_HIT_CAPACITY);
 for(unsigned i=0;i<p->count;++i)sum+=p->hits[(p->head+i)%FATAL_HIT_CAPACITY].damage;
 assert(sum==p->pending && sum>=0);
 assert(fatal_window_ns(p)==800000000ULL);
}
int main(void) {
 FatalPolicy p;fresh(&p,200);
 assert(fatal_damage(&p,200,50,MS(1))==FATAL_PASS);
 assert(fatal_damage(&p,200,60,MS(2))==FATAL_PASS && p.pending==110);
 assert(fatal_damage(&p,200,90,MS(3))==FATAL_REQUEST && p.projected==0 && p.reason==FATAL_REASON_LETHAL);
 fatal_requested(&p,1);fatal_server_hp(&p,250,MS(4));
 assert(!p.pending && !p.count && p.projected==250 && p.blocking);
 assert(fatal_damage(&p,250,50,MS(5))==FATAL_BLOCK);
 fatal_reset(&p,1,2,4);assert(!p.pending && !p.blocking && !p.count);

 /* Exact beach failure: a +1 HP snapshot must not erase a fresh 38-damage burst. */
 fresh(&p,41);
 const int damage[]={6,8,8,8,8};const int times[]={33,100,133,183,200};
 for(unsigned i=0;i<5;++i)assert(fatal_damage(&p,41,damage[i],MS(times[i]))==FATAL_PASS);
 assert(p.pending==38 && p.projected==3);
 fatal_server_hp(&p,42,MS(201));assert(p.pending==38 && p.projected==4);
 assert(fatal_damage(&p,42,8,MS(233))==FATAL_REQUEST && p.projected==-4);

 /* Wider retained beach context, guard-19822 snapshot SHA-256
  * 9727a5330aad1526c068a6a9cf5430869a576f184f75e47cffde1f29874d531a.
  * A prior 3-damage hit and net loss of 2 is explained by the hit plus 1 HP of
  * regeneration, so the whole hit retires. */
 fresh(&p,43);assert(fatal_damage(&p,43,0,MS(0))==FATAL_PASS);
 assert(fatal_damage(&p,43,3,MS(150))==FATAL_PASS);
 fatal_server_hp(&p,41,MS(317));assert(p.pending==0 && !p.unexplained);
 const int wider_times[]={350,417,450,500,517};
 for(unsigned i=0;i<5;++i)assert(fatal_damage(&p,41,damage[i],MS(wider_times[i]))==FATAL_PASS);
 fatal_server_hp(&p,42,MS(518));assert(p.pending==38);
 assert(fatal_damage(&p,42,8,MS(550))==FATAL_REQUEST && p.projected==-4);

 /* HP loss retires whole hits oldest-first when they explain it. This is
  * inference, not proof of individual report acceptance. */
 fresh(&p,200);assert(fatal_damage(&p,200,50,MS(10))==FATAL_PASS);
 assert(fatal_damage(&p,200,60,MS(20))==FATAL_PASS);
 fatal_server_hp(&p,150,MS(100));assert(p.pending==60 && p.count==1 && !p.unexplained);
 fatal_server_hp(&p,150,MS(110));assert(p.pending==60);
 fatal_server_hp(&p,170,MS(120));assert(p.pending==60 && p.projected==110);
 fatal_server_hp(&p,111,MS(320));assert(!p.pending && !p.unexplained); /* 60 hit, 1 regen */
 invariant(&p);
 /* Two hits applied in one update retire together; regen beyond the bound does not. */
 fresh(&p,200);assert(fatal_damage(&p,200,50,MS(10))==FATAL_PASS);
 assert(fatal_damage(&p,200,60,MS(20))==FATAL_PASS);
 fatal_server_hp(&p,92,MS(200));assert(!p.pending && !p.count); /* 110 - 2 regen */
 fresh(&p,200);assert(fatal_damage(&p,200,50,MS(10))==FATAL_PASS);
 fatal_server_hp(&p,170,MS(200));assert(p.pending==50 && p.unexplained==1 && p.last_unexplained==30);
 /* A drop larger than all pending hits is unexplained too: the hits stay pending
  * and the quiet interval restarts. */
 fresh(&p,200);assert(fatal_damage(&p,200,50,MS(10))==FATAL_PASS);
 fatal_server_hp(&p,120,MS(200));assert(p.pending==50 && p.unexplained==1 && p.projected==70);
 assert(p.last_damage_ns==MS(200));
 /* Regeneration credit grows with time since the last snapshot, capped at 1 s. */
 assert(fatal_regen_tolerance(&p,MS(200))==1 && fatal_regen_tolerance(&p,MS(700))==11);
 assert(fatal_regen_tolerance(&p,MS(5200))==21);
 invariant(&p);

 /* Healing supplies a new baseline without individually expiring old hits.
  * Only a quiet interval with healthy ticks and an HP stat can clear them. */
 fresh(&p,935);assert(fatal_damage(&p,935,703,MS(1))==FATAL_PASS);
 for(int ms=200;ms<=800;ms+=200){assert(!tick(&p,1206,ms,1));assert(p.pending==703);}
 assert(tick(&p,1206,1000,1));assert(!p.pending && p.projected==1206 && p.rebases==1);
 for(int i=0;i<3;++i)assert(fatal_damage(&p,1206,110,MS(1020+i))==FATAL_PASS);
 assert(p.pending==330 && p.projected==876);

 /* The selected threshold is exactly 800 ms, independent of jitter. */
 fresh(&p,1000);assert(fatal_damage(&p,1000,100,MS(100))==FATAL_PASS);
 for(int ms=200;ms<=800;ms+=200)assert(!tick(&p,1000,ms,1));
 FatalPolicy boundary=p;
 assert(!tick(&p,1000,899,1) && p.pending==100);
 p=boundary;assert(tick(&p,1000,900,1) && !p.pending);
 p.interval_ns=1000000000ULL;p.jitter_ns=1000000000ULL;
 assert(fatal_window_ns(&p)==800000000ULL);

 /* Continuous inputs never age out, even while healing masks every hit. */
 fresh(&p,10000);
 for(int ms=100;ms<=6100;ms+=200){
  assert(fatal_damage(&p,10000,10,MS(ms))==FATAL_PASS);
  assert(!tick(&p,10000,ms+100,1));
 }
 assert(p.pending==310 && !p.rebases);invariant(&p);

 /* A last-moment new input postpones the WHOLE quiet rebase. */
 fresh(&p,1000);assert(fatal_damage(&p,1000,100,MS(1))==FATAL_PASS);
 for(int ms=200;ms<=800;ms+=200)assert(!tick(&p,1000,ms,1));
 assert(fatal_damage(&p,1000,1,MS(899))==FATAL_PASS);
 assert(!tick(&p,1000,1000,1) && p.pending==101);
 for(int ms=1200;ms<=1600;ms+=200)assert(!tick(&p,1000,ms,1));
 assert(tick(&p,1000,1800,1));

 /* Unchanged-HP ticks keep liveness but are not new HP-bearing snapshots. */
 fresh(&p,1000);assert(fatal_damage(&p,1000,100,MS(1))==FATAL_PASS);
 for(int ms=200;ms<=3000;ms+=200)assert(!tick(&p,1000,ms,0));
 assert(p.pending==100 && !p.rebases);
 assert(tick(&p,1000,3200,1) && !p.pending);

 /* A standalone setter after a quiet interval cannot stand in for a tick. */
 fresh(&p,1000);assert(fatal_damage(&p,1000,100,MS(1))==FATAL_PASS);
 fatal_server_hp(&p,1000,MS(10000));assert(p.pending==100 && !p.rebases);

 /* A stall and compressed backlog require a fresh healthy interval. */
 fresh(&p,1000);assert(fatal_damage(&p,1000,100,MS(1))==FATAL_PASS);
 assert(!tick(&p,1000,4000,1));assert(!tick(&p,1000,4001,1));
 for(int ms=4200;ms<=4800;ms+=200)assert(!tick(&p,1000,ms,1));
 assert(tick(&p,1000,5000,1) && !p.pending);

 /* Duplicate, out-of-order and skipped tick identifiers cannot settle damage. */
 fresh(&p,1000);assert(fatal_damage(&p,1000,100,MS(1))==FATAL_PASS);
 for(int ms=200;ms<=800;ms+=200)assert(!tick(&p,1000,ms,1));
 assert(!fatal_server_tick(&p,1000,MS(1000),p.tick_sequence,p.server_time,p.damage_sequence,1));
 assert(p.pending==100);
 assert(!fatal_server_tick(&p,1000,MS(1200),p.tick_sequence-1,p.server_time-200,p.damage_sequence,1));
 assert(!fatal_server_tick(&p,1000,MS(1400),p.tick_sequence+2,p.server_time+400,p.damage_sequence,1));
 for(int ms=1600;ms<=2000;ms+=200)assert(!tick(&p,1000,ms,1));
 assert(tick(&p,1000,2200,1) && !p.pending);

 /* Handler reentrancy: a damage event during update processing survives it. */
 fresh(&p,1000);assert(fatal_damage(&p,1000,100,MS(1))==FATAL_PASS);
 for(int ms=200;ms<=800;ms+=200)assert(!tick(&p,1000,ms,1));
 uint64_t sequence=p.damage_sequence;
 assert(fatal_damage(&p,1000,10,MS(2200))==FATAL_PASS);
 fatal_server_hp(&p,1000,MS(2201));
 assert(!fatal_server_tick(&p,1000,MS(2200),p.tick_sequence+1,p.server_time+200,sequence,1));
 assert(p.pending==110);

 /* Protocol counters can wrap; backwards local clocks cannot rebase. */
 fresh(&p,1000);p.tick_sequence=UINT32_MAX;p.server_time=UINT32_MAX-100;
 assert(fatal_damage(&p,1000,100,MS(1))==FATAL_PASS);
 assert(!fatal_server_tick(&p,1000,MS(200),0,99,p.damage_sequence,1));
 assert(p.tick_sequence==0 && p.server_time==99);
 assert(!fatal_server_tick(&p,1000,MS(100),1,299,p.damage_sequence,1));
 assert(p.pending==100);

 /* Continuous masked healing is inherently ambiguous. Keep its exposure bounded;
  * at low HP a conservative escape is expected, rather than inventing a heal. */
 fresh(&p,100);assert(fatal_damage(&p,100,60,MS(1))==FATAL_PASS);
 fatal_server_hp(&p,100,MS(200));assert(p.pending==60);
 assert(fatal_damage(&p,100,60,MS(201))==FATAL_REQUEST);

 /* A failed request forwards damage and retries only after a fresh positive HP
  * observation; its local Nexusing latch is never fabricated. */
 fresh(&p,100);assert(fatal_damage(&p,100,100,MS(1))==FATAL_REQUEST);fatal_requested(&p,0);
 assert(fatal_damage(&p,100,1,MS(2))==FATAL_PASS && p.attempted);
 fatal_server_hp(&p,40,MS(200));assert(!p.attempted && p.pending==101 && p.unexplained==1);
 assert(fatal_damage(&p,40,50,MS(201))==FATAL_REQUEST);

 /* Stalled updates never make old damage disappear on the next local hit. */
 fresh(&p,1000);assert(fatal_damage(&p,1000,100,MS(1))==FATAL_PASS);
 assert(fatal_damage(&p,1000,1,MS(2000))==FATAL_REQUEST);
 assert(p.reason==FATAL_REASON_STALE && p.pending==101);
 fatal_server_hp(&p,1000,MS(3000));assert(p.pending==101 && p.projected==899);

 /* Buffer exhaustion requests escape and retains overflow as aggregate debt. */
 fresh(&p,100000);
 for(unsigned i=0;i<FATAL_HIT_CAPACITY;++i)assert(fatal_damage(&p,100000,1,MS(1)+i)==FATAL_PASS);
 assert(fatal_damage(&p,100000,1,MS(2))==FATAL_REQUEST && p.reason==FATAL_REASON_CAPACITY);
 assert(p.overflow==1 && p.pending==129);invariant(&p);
 fatal_requested(&p,0);fatal_server_hp(&p,99000,MS(200));assert(!p.pending && !p.count && !p.overflow);

 fresh(&p,100);assert(fatal_damage(&p,0,100,MS(1))==FATAL_LATE);
 assert(fatal_damage(&p,100,-1,MS(2))==FATAL_INVALID);
 assert(fatal_damage(&p,100,0,MS(9000))==FATAL_PASS && !p.count);
 p.pending=INT64_MAX;assert(fatal_damage(&p,100,1,MS(9001))==FATAL_INVALID);
 fatal_server_hp(&p,INT_MIN,MS(9002));assert(p.projected==INT_MIN && !p.pending);

 /* Cadence/jitter still informs stale detection, not the fixed 800 ms wait.
  * Backwards clock samples do not
  * wrap the elapsed-time arithmetic or move the heartbeat backwards. */
 fresh(&p,100000);
 const int gaps[]={200,200,350,40,1000,1200,200,700};uint64_t t=MS(0);
 for(int i=0;i<20000;++i){
  t+=(uint64_t)gaps[i%8]*1000000ULL;fatal_server_hp(&p,100000-3*i,t);
  (void)fatal_server_tick(&p,100000-3*i,t,p.tick_sequence+1,p.server_time+200,p.damage_sequence,1);
  (void)fatal_damage(&p,100000-3*i,3,t+1);invariant(&p);
 }
 uint64_t last=p.last_update_ns;fatal_tick(&p,last-1);assert(p.last_update_ns==last);

 /* Known gaps from docs/nexus-hardening-plan.md. These pin CURRENT v8 outcomes,
  * including the two missed escapes; a fix must update the matching assertion. */
 /* A: a hit settled later than 800 ms during healthy ticks is forgotten. Server
  * truth 400-150-200-100=-50, yet neither later hit requests Nexus. */
 fresh(&p,400);for(int ms=200;ms<=400;ms+=200)assert(!tick(&p,400,ms,1));
 assert(fatal_damage(&p,400,150,MS(400))==FATAL_PASS);
 for(int ms=600;ms<=1000;ms+=200)assert(!tick(&p,400,ms,1));
 assert(tick(&p,400,1200,1) && !p.pending && p.last_rebase_pending==150);
 assert(fatal_damage(&p,400,200,MS(1300))==FATAL_PASS);
 assert(fatal_damage(&p,400,100,MS(1350))==FATAL_PASS && p.projected==100);

 /* B, coincident amounts: an untracked 100 HP loss exactly matches the tracked
  * 100-damage hit and retires it. Server truth 200-100-100=0; still missed. */
 fresh(&p,200);assert(fatal_damage(&p,200,100,MS(1))==FATAL_PASS);
 assert(!tick(&p,100,100,1) && !p.pending && p.projected==100);
 assert(fatal_damage(&p,100,60,MS(200))==FATAL_PASS && p.projected==40);
 /* B, unequal amounts: a 70 untracked loss cannot be the pending 100 hit, so the
  * hit stays pending and the next hit escapes (server truth 200-70-100-60). */
 fresh(&p,200);assert(fatal_damage(&p,200,100,MS(1))==FATAL_PASS);
 assert(!tick(&p,130,100,1) && p.pending==100 && p.unexplained==1 && p.projected==30);
 assert(fatal_damage(&p,130,60,MS(200))==FATAL_REQUEST && p.reason==FATAL_REASON_LETHAL);

 /* C: if the server applies 100 for a hit computed as 40, the excess drop is
  * unexplained, so the hit stays pending and the next input escapes. */
 fresh(&p,100);assert(fatal_damage(&p,100,40,MS(1))==FATAL_PASS && p.projected==60);
 assert(!tick(&p,1,200,1) && p.pending==40 && p.unexplained==1 && p.projected==-39);
 assert(fatal_damage(&p,1,0,MS(250))==FATAL_REQUEST);

 /* D: a same-update heal hides a hit; conservative early escape (real HP 70). */
 fresh(&p,200);assert(fatal_damage(&p,200,80,MS(1))==FATAL_PASS);
 assert(!tick(&p,220,300,1) && p.pending==80 && p.projected==140);
 assert(fatal_damage(&p,220,150,MS(400))==FATAL_REQUEST && p.reason==FATAL_REASON_LETHAL);

 /* E: any positive hit after a 2 s update stall escapes, regardless of HP. */
 fresh(&p,500);assert(fatal_damage(&p,500,20,MS(2100))==FATAL_REQUEST);
 assert(p.reason==FATAL_REASON_STALE && p.projected==480);

 /* F: a 40 drop for a 50 hit is within regeneration plus the overestimate slack,
  * so the whole hit retires and no remainder lingers across omitted-HP ticks. */
 fresh(&p,300);assert(fatal_damage(&p,300,50,MS(1))==FATAL_PASS);
 assert(!tick(&p,260,400,1) && !p.pending && !p.unexplained);
 for(int ms=600;ms<=3000;ms+=200)assert(!tick(&p,260,ms,0));
 assert(!p.pending && !p.rebases);

 /* Learned regeneration: +7 per 200 ms (35 HP/s, as in guard-88966) lets a 90 hit
  * explain an 81 drop; a 1 HP top-up at max HP and a 69 heal do not move the median. */
 fresh(&p,600);
 const int rises[]={607,614,621,690,691};
 for(int i=0;i<5;++i)assert(!tick(&p,rises[i],200*(i+1),1));
 assert(p.regen_count==5 && fatal_regen_rate(&p)==35);
 assert(fatal_damage(&p,691,90,MS(1100))==FATAL_PASS);
 assert(!tick(&p,610,1200,1) && !p.pending && !p.unexplained);
 /* Sustained large healing is capped, so it cannot widen matching without bound. */
 fresh(&p,100);
 for(int i=1;i<=5;++i)assert(!tick(&p,100+100*i,200*i,1));
 assert(fatal_regen_rate(&p)==FATAL_REGEN_MAX_HP_PER_S);
 printf("Fatal policy: beach replay, quiet settlement, healing, ongoing damage, omitted HP, stalls/backlog, identifier ordering/wrap, reentrancy, capacity, latch, known gaps A-F and explained-drop retirement passed; policy_bytes=%zu ledger_bytes=%zu\n",sizeof p,sizeof p.hits);
}
