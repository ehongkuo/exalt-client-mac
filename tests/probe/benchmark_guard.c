/* Benchmark-only shim; never linked into the shipped guard. */
#include <dispatch/dispatch.h>
static void benchmark_noop(void *unused){(void)unused;}
/* The benchmark drains explicitly between batches. Keep exactly one consumer. */
#define dispatch_source_set_event_handler_f(s,h) dispatch_source_set_event_handler_f(s,(h)==drain?benchmark_noop:(h))
#include GUARD_BENCH_SOURCE
#undef dispatch_source_set_event_handler_f
#include <mach/task_info.h>
#include <sys/resource.h>
#include <assert.h>
extern void benchmark_reset(int);
extern uint64_t benchmark_reads(void);
extern void send_fixture(void *,void *,const void *);
static uint64_t bench_wall_ns(void) {
 struct timespec t;clock_gettime(CLOCK_UPTIME_RAW,&t);
 return (uint64_t)t.tv_sec*1000000000ULL+t.tv_nsec;
}
static uint64_t bench_cpu_ns(void) {
 struct timespec t;clock_gettime(CLOCK_PROCESS_CPUTIME_ID,&t);
 return (uint64_t)t.tv_sec*1000000000ULL+t.tv_nsec;
}
static int compare_ns(const void *a,const void *b) {
 uint64_t x=*(const uint64_t*)a,y=*(const uint64_t*)b;return (x>y)-(x<y);
}
__attribute__((visibility("default"))) void guard_benchmark(const char *name,int kind,int count) {
 uint64_t samples[1000];assert(count<=1000);
 if(kind && !probe_installed){fprintf(stderr,"benchmark hooks unavailable\n");exit(3);}
 benchmark_reset(1000000000);fatal_clear((void*)40,0);hit_probe_tick((void*)40,monotonic_ns());hit_probe_drain();
 uint64_t fields=benchmark_reads(),cpu=bench_cpu_ns(),drain_ns=0;
 for(int i=0;i<count;++i){
  if(kind==5){fatal_clear((void*)40,0);benchmark_reset(1);}
  uint64_t begin=bench_wall_ns();
  for(int j=0;j<100;++j){
   switch(kind){
   case 0:
#ifdef BENCH_FULL_TICK
    tick(NULL);
#else
    hit_probe_tick((void*)40,monotonic_ns());
#endif
    break;
   case 1:case 6:
    (void)damage_observed((void*)3,50.5f,(void*)0x5678);
    report_observed((void*)70,4000000000u,7,(void*)0x5678);
    notify_observed((void*)40,0,50,(void*)0x2345,1,(void*)0x3456,1,0,(void*)0x4567);
    if(kind==6)update_observed((void*)70,(void*)3,(void*)0x5678);
    break;
   case 2:update_observed((void*)70,(void*)3,(void*)0x5678);break;
   case 3:
#ifdef BENCH_HAS_SEND
    send_observed((void*)500,(void*)3,(void*)0x9876);
#else
    send_fixture((void*)500,(void*)3,(void*)0x9876);
#endif
    break;
   case 4:notify_observed((void*)40,0,50,(void*)0x2345,1,(void*)0x3456,2,0,(void*)0x4567);break;
   case 5:(void)damage_observed((void*)3,50.5f,(void*)0x5678);break;
   }
   if(kind==5)break;
  }
  samples[i]=bench_wall_ns()-begin;
  uint64_t draining=bench_wall_ns();hit_probe_drain();drain_ns+=bench_wall_ns()-draining;
 }
 fflush(logfile);cpu=bench_cpu_ns()-cpu;fields=benchmark_reads()-fields;
 qsort(samples,count,sizeof samples[0],compare_ns);
 struct task_vm_info vm={0};mach_msg_type_number_t size=TASK_VM_INFO_COUNT;
 task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&vm,&size);
 unsigned events=0;for(int i=0;i<9 && i<(int)(sizeof probe_hooks/sizeof *probe_hooks);++i)events+=(unsigned)probe_hooks[i].allocation;
 int batch=kind==5?1:100;
 printf("BENCH {\"name\":\"%s\",\"operations\":%d,\"p50_ns\":%.2f,\"p95_ns\":%.2f,\"p99_ns\":%.2f,\"cpu_ns_per_op\":%.2f,\"drain_ns_per_op\":%.2f,\"field_reads_per_op\":%.2f,\"resident_bytes\":%llu,\"footprint_bytes\":%llu,\"event_buffer_bytes\":%zu,\"trampoline_bytes\":%u,\"drops\":%llu}\n",name,count*batch,
  (double)samples[count/2]/batch,(double)samples[count*95/100]/batch,(double)samples[count*99/100]/batch,
  (double)cpu/(count*batch),(double)drain_ns/(count*batch),(double)fields/(count*batch),
  vm.resident_size,vm.phys_footprint,sizeof probe_events,events,(unsigned long long)atomic_load(&probe_drops));
}
