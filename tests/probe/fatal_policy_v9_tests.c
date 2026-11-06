#include "../../probe/fatal_policy_v9.h"
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
 assert(sum==p->pending && sum>=0 && !p->rebases);
}
static void hit(FatalPolicy *p,int hp,int damage,int ms) {assert(fatal_damage(p,hp,damage,MS(ms))==FATAL_PASS);}
int main(void) {
 FatalPolicy p;

 /* Accounting clears the oldest hits by the damage an update applied, exactly. */
 fresh(&p,200);hit(&p,200,50,1);hit(&p,200,60,2);
 assert(!tick(&p,150,400,1) && p.pending==60 && p.count==1 && p.settled==1 && p.projected==90);
 invariant(&p);

 /* Heal and hit in one update (heal capture, 881 -> 859 with "+80" and a 103 hit pending):
  * 80 + 22 = 102 applied, and the 1 HP left is regeneration. */
 fresh(&p,881);hit(&p,881,103,1);fatal_heal(&p,80);
 assert(!tick(&p,859,400,1) && !p.pending && p.residue_cleared==1 && p.projected==859);

 /* Report order is application order (heal capture 31.9-33.4 s): 103, 113, 103 pending,
  * cleared by updates of (+80, -22), -112, (+80, -22). */
 fresh(&p,799);hit(&p,799,103,1);hit(&p,799,113,2);hit(&p,799,103,3);
 fatal_heal(&p,80);tick(&p,777,200,1);assert(p.pending==216 && p.count==2);
 tick(&p,665,400,1);assert(p.pending==103 && p.count==1);
 fatal_heal(&p,80);tick(&p,643,600,1);assert(!p.pending && p.residue_cleared==3 && !p.suspended);

 /* Two heals in one update (+80 and +90 for +171) apply nothing and explain the rise. */
 fresh(&p,627);hit(&p,627,40,1);fatal_heal(&p,80);fatal_heal(&p,90);
 tick(&p,798,200,1);assert(p.pending==40 && !p.unexplained);

 /* At full HP a heal is capped: 885 -> 853 with "+80" applied a 113 hit (minus regen). */
 fresh(&p,885);hit(&p,885,113,1);fatal_heal(&p,80);
 tick(&p,853,400,1);assert(!p.pending && p.residue_cleared==1);

 /* A heal without text makes accounting clear less, never more (D, conservative). */
 fresh(&p,200);hit(&p,200,80,1);
 assert(!tick(&p,220,300,1) && p.pending==80 && p.projected==140);
 assert(fatal_damage(&p,220,150,MS(400))==FATAL_REQUEST && p.reason==FATAL_REASON_LETHAL);
 /* With its text, the same update clears the hit (D removed). */
 fresh(&p,200);hit(&p,200,80,1);fatal_heal(&p,100);
 tick(&p,220,300,1);assert(!p.pending && p.projected==220);
 assert(fatal_damage(&p,220,150,MS(400))==FATAL_PASS);

 /* Heal credit carries over updates that omit HP, so the sum stays exact. */
 fresh(&p,500);hit(&p,500,80,1);fatal_heal(&p,80);
 for(int ms=200;ms<=600;ms+=200)assert(!fatal_server_tick(&p,500,MS(ms),p.tick_sequence+1,p.server_time+200,p.damage_sequence,0));
 hit(&p,500,50,650);tick(&p,450,800,1);assert(!p.pending);

 /* Regeneration residue applies only to a hit the update partly cleared: small beach hits
  * survive a +1 HP snapshot, and an overestimate remainder above r stays (F). */
 fresh(&p,41);
 const int damage[]={6,8,8,8,8};const int times[]={33,100,133,183,200};
 for(unsigned i=0;i<5;++i)hit(&p,41,damage[i],times[i]);
 assert(p.pending==38 && p.projected==3);
 fatal_server_hp(&p,42,MS(201));assert(p.pending==38 && p.projected==4);
 assert(fatal_damage(&p,42,8,MS(233))==FATAL_REQUEST && p.projected==-4);
 fresh(&p,100);hit(&p,100,3,1);tick(&p,100,200,1);assert(p.pending==3);
 fresh(&p,300);hit(&p,300,50,1);tick(&p,260,400,1);assert(p.pending==10);
 for(int ms=600;ms<=3000;ms+=200)assert(!tick(&p,260,ms,0));
 assert(p.pending==10);
 fatal_regen(&p,20);assert(p.regen==FATAL_REGEN_MAX);fatal_regen(&p,-1);assert(!p.regen);

 /* An unexplained decrease suspends accounting for the map; pending hits are kept. */
 fresh(&p,885);tick(&p,773,200,1);assert(p.suspended && p.unexplained==1);
 hit(&p,773,100,300);tick(&p,673,600,1);assert(p.pending==100 && p.projected==573);
 fatal_reset(&p,1,2,4);assert(!p.suspended && p.regen==FATAL_REGEN_DEFAULT);

 /* Damage over time: the drain allowance is projected and kept out of accounting. */
 fresh(&p,300);fatal_drain(&p,4);assert(p.projected==296);
 hit(&p,300,50,1);assert(p.projected==246);
 tick(&p,247,200,1);assert(!p.pending && !p.unexplained && p.projected==243); /* 53 - 4 = 49, 1 residue */
 tick(&p,244,400,1);assert(!p.unexplained); /* Bleeding alone stays within the allowance. */
 fatal_drain(&p,0);assert(p.projected==244);

 /* Final burst of the heal capture: server 481 with 417 HP not yet applied, so the lethal
  * 98 hit requests Nexus at -34 (the character died 328 ms later). */
 fresh(&p,588);
 hit(&p,588,103,0);tick(&p,590,100,1);hit(&p,590,98,150);hit(&p,590,103,250);hit(&p,590,103,251);
 fatal_heal(&p,90);tick(&p,681,300,1);assert(p.pending==407);
 hit(&p,681,98,350);hit(&p,681,113,499);
 tick(&p,481,500,1);assert(p.pending==417 && p.count==4);
 assert(fatal_damage(&p,481,98,MS(600))==FATAL_REQUEST && p.reason==FATAL_REASON_LETHAL && p.projected==-34);

 /* Plan gaps against v8's pinned outcomes. */
 /* A: a hit applied after 800 ms of healthy ticks is no longer forgotten. Server truth
  * 400-150-200-100=-50, and the last hit now requests Nexus. */
 fresh(&p,400);for(int ms=200;ms<=400;ms+=200)assert(!tick(&p,400,ms,1));
 hit(&p,400,150,400);
 for(int ms=600;ms<=1200;ms+=200)assert(!tick(&p,400,ms,1));
 assert(p.pending==150 && !p.rebases);
 hit(&p,400,200,1300);
 assert(fatal_damage(&p,400,100,MS(1350))==FATAL_REQUEST && p.projected==-50);
 /* B: an untracked loss equal to a pending hit still clears it (remaining assumption). */
 fresh(&p,200);hit(&p,200,100,1);
 assert(!tick(&p,100,100,1) && !p.pending && p.projected==100);
 assert(fatal_damage(&p,100,60,MS(200))==FATAL_PASS && p.projected==40);
 /* C: server damage far above the local calculation is now unexplained; the hit stays. */
 fresh(&p,100);hit(&p,100,40,1);
 tick(&p,1,200,1);assert(p.suspended && p.pending==40 && p.projected==-39);
 /* E: unchanged stale escape. */
 fresh(&p,500);assert(fatal_damage(&p,500,20,MS(2100))==FATAL_REQUEST);
 assert(p.reason==FATAL_REASON_STALE && p.projected==480);

 /* Unchanged from v8: latch, block, retry after a positive HP, capacity, invalid input. */
 fresh(&p,200);hit(&p,200,50,1);hit(&p,200,60,2);
 assert(fatal_damage(&p,200,90,MS(3))==FATAL_REQUEST && p.projected==0);
 fatal_requested(&p,1);fatal_heal(&p,30);fatal_server_hp(&p,250,MS(4));
 assert(!p.pending && !p.count && !p.heal && p.projected==250 && p.blocking);
 assert(fatal_damage(&p,250,50,MS(5))==FATAL_BLOCK);
 fresh(&p,100);assert(fatal_damage(&p,100,100,MS(1))==FATAL_REQUEST);fatal_requested(&p,0);
 assert(fatal_damage(&p,100,1,MS(2))==FATAL_PASS && p.attempted);
 fatal_server_hp(&p,40,MS(200));assert(!p.attempted && p.pending==41);
 assert(fatal_damage(&p,40,50,MS(201))==FATAL_REQUEST);
 fresh(&p,100000);
 for(unsigned i=0;i<FATAL_HIT_CAPACITY;++i)assert(fatal_damage(&p,100000,1,MS(1)+i)==FATAL_PASS);
 assert(fatal_damage(&p,100000,1,MS(2))==FATAL_REQUEST && p.reason==FATAL_REASON_CAPACITY);
 assert(p.overflow==1 && p.pending==129);invariant(&p);
 tick(&p,99871,200,1);assert(!p.pending && !p.overflow);invariant(&p);
 fresh(&p,100);assert(fatal_damage(&p,0,100,MS(1))==FATAL_LATE);
 assert(fatal_damage(&p,100,-1,MS(2))==FATAL_INVALID);
 fatal_heal(&p,-5);fatal_heal(&p,FATAL_HEAL_MAX+1);assert(!p.heal);
 p.pending=INT64_MAX;assert(fatal_damage(&p,100,1,MS(9001))==FATAL_INVALID);
 fatal_server_hp(&p,INT_MIN,MS(9002));assert(p.projected==INT_MIN && !p.pending);

 /* Long mixed run: the ledger stays consistent and nothing ever rebases. */
 fresh(&p,100000);
 const int gaps[]={200,200,350,40,1000,1200,200,700};uint64_t t=MS(0);int hp=100000;
 for(int i=0;i<20000;++i){
  t+=(uint64_t)gaps[i%8]*1000000ULL;if(i%5==0)fatal_heal(&p,7);
  hp+=i%5==0?7-3:-3;fatal_server_hp(&p,hp,t);
  (void)fatal_server_tick(&p,hp,t,p.tick_sequence+1,p.server_time+200,p.damage_sequence,1);
  (void)fatal_damage(&p,hp,3,t+1);invariant(&p);
 }
 assert(p.pending<=3 && !p.suspended);
 uint64_t last=p.last_update_ns;fatal_tick(&p,last-1);assert(p.last_update_ns==last);

 printf("Fatal policy v9: accounting, heal text, report order, residue, drain, suspension, final burst, gaps A-C/E and v8 latch/capacity passed; policy_bytes=%zu\n",sizeof p);
}
