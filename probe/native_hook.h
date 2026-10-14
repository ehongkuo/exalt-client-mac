#ifndef NATIVE_HOOK_H
#define NATIVE_HOOK_H
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

enum { HOOK_OK, HOOK_BYTES, HOOK_REGION, HOOK_ALLOC, HOOK_PROTECTION, HOOK_STATE };
typedef struct {
    void *entry, *trampoline;
    size_t length, allocation;
    vm_prot_t protection;
    unsigned char original[32];
    int installed;
} NativeHook;
static inline void native_jump(unsigned char *where, void *destination) {
    const unsigned char opcode[6]={0xff,0x25,0,0,0,0};
    memcpy(where,opcode,6);memcpy(where+6,&destination,sizeof destination);
}
static inline int native_hook_write(NativeHook *h,const unsigned char *bytes) {
    size_t page=(size_t)getpagesize();
    mach_vm_address_t begin=(uintptr_t)h->entry & ~(page-1);
    mach_vm_size_t size=((uintptr_t)h->entry+h->length-begin+page-1) & ~(page-1);
    if(mach_vm_protect(mach_task_self(),begin,size,FALSE,VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY)!=KERN_SUCCESS)
        return HOOK_PROTECTION;
    memcpy(h->entry,bytes,h->length);sys_icache_invalidate(h->entry,h->length);
    if(mach_vm_protect(mach_task_self(),begin,size,FALSE,h->protection)!=KERN_SUCCESS) {
        memcpy(h->entry,h->original,h->length);sys_icache_invalidate(h->entry,h->length);
        if(mach_vm_protect(mach_task_self(),begin,size,FALSE,h->protection)!=KERN_SUCCESS) __builtin_trap();
        return HOOK_PROTECTION;
    }
    return HOOK_OK;
}
/* Only audited, whole-instruction prologues without relative operands are supported.
 * Installation/removal must happen while the caller knows this entry is quiescent. */
static inline int native_hook_install(NativeHook *h,void *entry,void *replacement,
                                     const unsigned char *expected,size_t length,void **original) {
    if(h->installed || length<14 || length>sizeof h->original) return HOOK_STATE;
    mach_vm_address_t region=(uintptr_t)entry;mach_vm_size_t size=0;
    vm_region_basic_info_data_64_t info;mach_msg_type_number_t count=VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object=MACH_PORT_NULL;
    kern_return_t kr=mach_vm_region(mach_task_self(),&region,&size,VM_REGION_BASIC_INFO_64,(vm_region_info_t)&info,&count,&object);
    if(object!=MACH_PORT_NULL)mach_port_deallocate(mach_task_self(),object);
    if(kr!=KERN_SUCCESS || region>(uintptr_t)entry || (uintptr_t)entry+length>region+size ||
       !(info.protection&VM_PROT_READ) || !(info.protection&VM_PROT_EXECUTE))return HOOK_REGION;
    if(memcmp(entry,expected,length))return HOOK_BYTES;
    size_t allocation=(size_t)getpagesize();
    unsigned char *trampoline=mmap(NULL,allocation,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
    if(trampoline==MAP_FAILED)return HOOK_ALLOC;
    memcpy(trampoline,entry,length);native_jump(trampoline+length,(unsigned char*)entry+length);
    sys_icache_invalidate(trampoline,length+14);
    if(mprotect(trampoline,allocation,PROT_READ|PROT_EXEC)){munmap(trampoline,allocation);return HOOK_PROTECTION;}
    *h=(NativeHook){.entry=entry,.trampoline=trampoline,.length=length,.allocation=allocation,.protection=info.protection};
    memcpy(h->original,entry,length);
    unsigned char patch[32];memset(patch,0x90,length);native_jump(patch,replacement);
    *original=trampoline;
    int result=native_hook_write(h,patch);
    if(result!=HOOK_OK){*original=NULL;munmap(trampoline,allocation);memset(h,0,sizeof *h);return result;}
    h->installed=1;return HOOK_OK;
}
static inline int native_hook_remove(NativeHook *h) {
    if(!h->installed)return HOOK_STATE;
    int result=native_hook_write(h,h->original);
    if(result==HOOK_OK){munmap(h->trampoline,h->allocation);h->installed=0;}
    return result;
}
#endif
