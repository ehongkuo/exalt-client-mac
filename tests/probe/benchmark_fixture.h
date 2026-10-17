/* Included only by the synthetic game fixture in GUARD_BENCHMARK builds. */
void benchmark_reset(int hp) {assigned_hp=hp;next_stats_hp=hp;socket_nexusing=0;}
uint64_t benchmark_reads(void) {return benchmark_field_reads;}
static void benchmark_run(void *unused) {
 (void)unused;
 void (*run)(const char*,int,int)=dlsym(RTLD_DEFAULT,"guard_benchmark");assert(run);
 run("tick",0,300);run("projectile",1,300);run("incoming_update",2,300);
 run("unrelated_send",3,300);run("terrain_notify",4,300);run("lethal_request",5,100);run("mixed_hit_update",6,300);
 fflush(stdout);exit(0);
}
int main(void) {
 dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW,1100*NSEC_PER_MSEC),dispatch_get_main_queue(),NULL,benchmark_run);
 return guard_fixture_main();
}
