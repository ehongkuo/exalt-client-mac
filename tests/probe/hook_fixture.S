.text
.globl _probe_fixture
.p2align 12
_probe_fixture:
#ifdef BAD_REPORT_BYTES
 nop
#endif
 pushq %rbp
 movq %rsp, %rbp
 pushq %r15
 pushq %r14
 pushq %r13
 pushq %r12
 pushq %rbx
 subq $0x18, %rsp
 movq 0x10(%rbp), %rax
 movq %rax, (%rsp)
 movq 0x18(%rbp), %rax
 movq %rax, 8(%rsp)
 callq _fixture_body
 addq $0x18, %rsp
 popq %rbx
 popq %r12
 popq %r13
 popq %r14
 popq %r15
 popq %rbp
 retq

.p2align 12

.globl _notify_fixture
.p2align 12
_notify_fixture:
 pushq %rbp
 movq %rsp, %rbp
 pushq %r15
 pushq %r14
 pushq %r13
 pushq %r12
 pushq %rbx
 pushq %rax
 subq $0x20, %rsp
 movq 0x10(%rbp), %rax
 movq %rax, (%rsp)
 movq 0x18(%rbp), %rax
 movq %rax, 8(%rsp)
 movq 0x20(%rbp), %rax
 movq %rax, 16(%rsp)
 callq _notify_fixture_body
 addq $0x20, %rsp
 popq %rax
 popq %rbx
 popq %r12
 popq %r13
 popq %r14
 popq %r15
 popq %rbp
 retq
.p2align 12

.globl _incoming_fixture
.p2align 12
_incoming_fixture:
#ifdef BAD_REPORT_BYTES
 nop
#endif
 pushq %rbp
 movq %rsp,%rbp
 pushq %r15
 pushq %r14
 pushq %r12
 pushq %rbx
 movl %edx,%r15d
 callq _incoming_fixture_body
 popq %rbx
 popq %r12
 popq %r14
 popq %r15
 popq %rbp
 retq
.p2align 12
.globl _hp_fixture
_hp_fixture:
 pushq %rbp
 movq %rsp,%rbp
 pushq %r15
 pushq %r14
 pushq %r13
 pushq %r12
 pushq %rbx
 pushq %rax
 callq _hp_fixture_body
 popq %rax
 popq %rbx
 popq %r12
 popq %r13
 popq %r14
 popq %r15
 popq %rbp
 retq
.p2align 12
.globl _nexus_fixture
_nexus_fixture:
 pushq %rbp
 movq %rsp,%rbp
 pushq %r15
 pushq %r14
 pushq %rbx
 subq $0x48,%rsp
 movq %rdi,%r14
 callq _nexus_fixture_body
 addq $0x48,%rsp
 popq %rbx
 popq %r14
 popq %r15
 popq %rbp
 retq
.p2align 12

.globl _hp_assignment_fixture
.p2align 12
_hp_assignment_fixture:
 pushq %rbp
 movq %rsp,%rbp
 movl %esi,0x20c(%rdi)
 movq (%rdi),%rax
 movq 0x718(%rax),%rcx
 movq 0x720(%rax),%rsi
 popq %rbp
 jmpq *%rcx
.p2align 12

.globl _damage_fixture
.p2align 12
_damage_fixture:
 pushq %rbp
 movq %rsp,%rbp
 pushq %r15
 pushq %r14
 pushq %rbx
 subq $0x18,%rsp
 movss %xmm0,-0x20(%rbp)
 callq _damage_fixture_body
 addq $0x18,%rsp
 popq %rbx
 popq %r14
 popq %r15
 popq %rbp
 retq
.p2align 12
.globl _death_fixture
_death_fixture:
 pushq %rbp
 movq %rsp,%rbp
 pushq %r15
 pushq %r14
 pushq %r13
 pushq %r12
 pushq %rbx
 pushq %rax
 callq _death_fixture_body
 popq %rax
 popq %rbx
 popq %r12
 popq %r13
 popq %r14
 popq %r15
 popq %rbp
 retq
.p2align 12

.globl _death_audit_fixture
.p2align 12
_death_audit_fixture:
 pushq %rbp
 movq %rsp,%rbp
 movq 0x140(%rdi),%rdi
 testq %rdi,%rdi
 je death_audit_missing
 xorl %edx,%edx
 popq %rbp
 jmp _death_audit_body
death_audit_missing:
 popq %rbp
 retq
.p2align 12

.globl _update_fixture
.p2align 12
_update_fixture:
 pushq %rbp
 movq %rsp,%rbp
 pushq %r15
 pushq %r14
 pushq %r13
 pushq %r12
 pushq %rbx
 subq $0x28,%rsp
 callq _update_fixture_body
 addq $0x28,%rsp
 popq %rbx
 popq %r12
 popq %r13
 popq %r14
 popq %r15
 popq %rbp
 retq
.p2align 12
.globl _stats_fixture
_stats_fixture:
 pushq %rbp
 movq %rsp,%rbp
 pushq %r15
 pushq %r14
 pushq %r13
 pushq %r12
 pushq %rbx
 subq $0x98,%rsp
 callq _stats_fixture_body
 addq $0x98,%rsp
 popq %rbx
 popq %r12
 popq %r13
 popq %r14
 popq %r15
 popq %rbp
 retq
.p2align 12
