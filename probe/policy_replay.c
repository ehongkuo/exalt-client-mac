/* Offline driver for probe/replay_policy.py. Feeds recorded inputs to the real
 * fatal_policy_v10.h in the same order as hit_probe.h and prints each decision.
 * Input lines:  G ns          new player/map scope (fatal_sync bootstrap)
 *               D ns hp dmg   audited damage at its intervention boundary
 *               H ns hp       incoming HP assignment return
 *               T ns          tick entry
 *               R ns hp seq time rtt   tick return (rtt: round-trip field, 0 if not traced)
 *               Y ns time     reply sent to the tick built at time
 * Output: one line per D/H/R with decision, pending, projected and hits cleared. */
#ifndef FATAL_POLICY_PATH
#define FATAL_POLICY_PATH "fatal_policy_v10.h"
#endif
#include FATAL_POLICY_PATH
#include <stdio.h>
#include <string.h>
int main(void) {
 static FatalPolicy p;char kind[2];unsigned long long ns;
 uint64_t entry_ns=0,entry_snapshots=0;int in_tick=0;
 while(scanf("%1s %llu",kind,&ns)==2){
  if(kind[0]=='G'){fatal_reset(&p,1,1,1);p.last_update_ns=ns;in_tick=0;continue;}
  if(kind[0]=='Y'){unsigned stamp=0;if(scanf("%u",&stamp)!=1)return 2;fatal_reply(&p,stamp);continue;}
  if(kind[0]=='T'){entry_ns=ns;entry_snapshots=p.snapshots;in_tick=1;continue;}
  int hp=0;
  if(kind[0]=='D'){int damage=0;if(scanf("%d %d",&hp,&damage)!=2)return 2;
   int decision=fatal_damage(&p,hp,damage,ns);
   /* Passive capture: no escape happened, so continue as an unconfirmed request. */
   if(decision==FATAL_REQUEST)fatal_requested(&p,0);
   printf("D %llu %d %d %d %lld %lld\n",ns,damage,decision,p.reason,(long long)p.pending,(long long)p.projected);
  } else if(kind[0]=='H'){if(scanf("%d",&hp)!=1)return 2;
   fatal_server_hp(&p,hp,ns);
   printf("H %llu %d %lld %lld\n",ns,hp,(long long)p.pending,(long long)p.projected);
  } else if(kind[0]=='R'){unsigned seq=0,stamp=0,rtt=0;if(scanf("%d %u %u %u",&hp,&seq,&stamp,&rtt)!=4)return 2;
   if(!in_tick){printf("R %llu %d 0 0 %lld\n",ns,hp,(long long)p.projected);continue;}
   in_tick=0;
   if(entry_snapshots==p.snapshots)fatal_server_hp(&p,hp,ns);
   int cleared=fatal_server_tick(&p,entry_ns,seq,stamp,rtt);
   printf("R %llu %d 0 %d %lld\n",ns,hp,cleared,(long long)p.projected);
  } else return 2;
 }
 return 0;
}
