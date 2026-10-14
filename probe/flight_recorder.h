#ifndef FLIGHT_RECORDER_H
#define FLIGHT_RECORDER_H
#include <stddef.h>
#define FLIGHT_CAPACITY 8192
/* Fixed format for recovery after process exit. Slots with odd sequence numbers
 * are incomplete and must be skipped. A wrap retains the most recent events. */
typedef struct { _Atomic uint64_t seq; ProbeEvent event; } FlightSlot;
typedef struct {
    char magic[8];uint32_t version,event_size;uint64_t capacity,start_ns;double epoch;
    _Atomic uint64_t count,dropped,off_main;
    FlightSlot slots[FLIGHT_CAPACITY];
} FlightRecorder;
_Static_assert(sizeof(ProbeEvent)==128,"Flight event layout changed");
_Static_assert(offsetof(FlightRecorder,slots)==64,"Flight header layout changed");
_Static_assert(sizeof(FlightSlot)==136,"Flight slot layout changed");
static inline FlightRecorder *flight_open(const char *folder,uint64_t start,double epoch) {
    char path[PATH_MAX];
    if(snprintf(path,sizeof path,"%s/hit-flight-%d.bin",folder,getpid())>=(int)sizeof path)return NULL;
    int fd=open(path,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW,0600);if(fd<0)return NULL;
    if(ftruncate(fd,sizeof(FlightRecorder))){close(fd);return NULL;}
    FlightRecorder *f=mmap(NULL,sizeof *f,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);close(fd);
    if(f==MAP_FAILED)return NULL;
    memset(f,0,sizeof *f);f->version=4;f->event_size=sizeof(ProbeEvent);f->capacity=FLIGHT_CAPACITY;
    f->start_ns=start;f->epoch=epoch;memcpy(f->magic,"EXHPRB4",8);return f;
}
static void flight_publish(FlightRecorder *f,ProbeEvent e) {
    uint64_t n=atomic_load_explicit(&f->count,memory_order_relaxed)+1;
    FlightSlot *slot=&f->slots[(n-1)%FLIGHT_CAPACITY];
    atomic_store_explicit(&slot->seq,n*2-1,memory_order_seq_cst);
    memcpy(&slot->event,&e,sizeof e);
    atomic_store_explicit(&slot->seq,n*2,memory_order_release);
    atomic_store_explicit(&f->count,n,memory_order_release);
}
#endif
