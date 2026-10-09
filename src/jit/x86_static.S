/*
 * Fixed code fragments copied by the x86-64 JIT (RandomX v1/v2, hardware AES).
 * Ported from RandomX's jit_compiler_x86_static.S and asm/*.inc
 * (Copyright (c) 2018-2019, tevador; BSD-3-Clause, see LICENSE).
 *
 * Never executed in place: x86.zig copies the bytes between consecutive
 * labels. RIP-relative references stay inside the fragment containing them.
 */

#define RANDOMX_SCRATCHPAD_MASK   (2097152 - 64)
#define RANDOMX_DATASET_BASE_MASK (2147483648 - 64)
#define RANDOMX_CACHE_MASK        (262144 * 16 - 1)
#define SUPERSCALAR_OFFSET        16384

.section .rodata.zrx_jit,"a",@progbits
.intel_syntax noprefix

.global zrx_prefetch_scratchpad
.hidden zrx_prefetch_scratchpad
zrx_prefetch_scratchpad:
  mov rdx, rax
  and eax, RANDOMX_SCRATCHPAD_MASK

  prefetcht0 [rsi+rax]
  ror rdx, 32
  and edx, RANDOMX_SCRATCHPAD_MASK

  prefetcht0 [rsi+rdx]
.global zrx_prefetch_scratchpad_end
.hidden zrx_prefetch_scratchpad_end
zrx_prefetch_scratchpad_end:

.balign 64
.global zrx_program_prologue
.hidden zrx_program_prologue
zrx_program_prologue:
  sub rsp, 456
  mov qword ptr [rsp+224], rbx
  mov qword ptr [rsp+232], rbp
  mov qword ptr [rsp+256], r12
  mov qword ptr [rsp+264], r13
  mov qword ptr [rsp+272], r14
  mov qword ptr [rsp+280], r15
  mov rbx, rcx
  mov qword ptr [rsp+448], rdi
  mov rcx, rdi
  mov rbp, qword ptr [rsi]
  mov rdi, qword ptr [rsi+8]
  mov rsi, rdx
  mov rax, rbp
  mov r8d, ebp
  ror rbp, 32
  mov r9d, ebp
  and r8d, RANDOMX_DATASET_BASE_MASK

  and r9d, RANDOMX_DATASET_BASE_MASK

  prefetchnta byte ptr [rdi+r8]
  prefetchnta byte ptr [rdi+r9]
  xor r8, r8
  xor r9, r9
  xor r10, r10
  xor r11, r11
  xor r12, r12
  xor r13, r13
  xor r14, r14
  xor r15, r15
  lea rcx, [rcx+120]
  movapd xmm8, xmmword ptr [rcx+72]
  movapd xmm9, xmmword ptr [rcx+88]
  movapd xmm10, xmmword ptr [rcx+104]
  movapd xmm11, xmmword ptr [rcx+120]
  movapd xmm13, xmmword ptr [rip+zrx_mantissa_mask]
  movapd xmm14, xmmword ptr [rip+zrx_exp240]
  movapd xmm15, xmmword ptr [rip+zrx_scale_mask]
  mov rdx, rax
  and eax, RANDOMX_SCRATCHPAD_MASK

  ror rdx, 32
  and edx, RANDOMX_SCRATCHPAD_MASK

  jmp zrx_program_loop_begin

.balign 64
zrx_mantissa_mask:
  .byte 255, 255, 255, 255, 255, 255, 255, 0, 255, 255, 255, 255, 255, 255, 255, 0
zrx_exp240:
  .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
zrx_scale_mask:
  .byte 0, 0, 0, 0, 0, 0, 240, 128, 0, 0, 0, 0, 0, 0, 240, 128

.balign 64
.global zrx_program_loop_begin
.hidden zrx_program_loop_begin
zrx_program_loop_begin:
  nop

.global zrx_program_loop_load
.hidden zrx_program_loop_load
zrx_program_loop_load:
  lea rcx, [rsi+rax]
  mov qword ptr [rsp+8], rcx
  xor r8,  qword ptr [rcx+0]
  xor r9,  qword ptr [rcx+8]
  xor r10, qword ptr [rcx+16]
  xor r11, qword ptr [rcx+24]
  xor r12, qword ptr [rcx+32]
  xor r13, qword ptr [rcx+40]
  xor r14, qword ptr [rcx+48]
  xor r15, qword ptr [rcx+56]
  lea rcx, [rsi+rdx]
  mov qword ptr [rsp+16], rcx
  cvtdq2pd xmm0, qword ptr [rcx+0]
  cvtdq2pd xmm1, qword ptr [rcx+8]
  cvtdq2pd xmm2, qword ptr [rcx+16]
  cvtdq2pd xmm3, qword ptr [rcx+24]
  cvtdq2pd xmm4, qword ptr [rcx+32]
  cvtdq2pd xmm5, qword ptr [rcx+40]
  cvtdq2pd xmm6, qword ptr [rcx+48]
  cvtdq2pd xmm7, qword ptr [rcx+56]
  andps xmm4, xmm13
  andps xmm5, xmm13
  andps xmm6, xmm13
  andps xmm7, xmm13
  orps xmm4, xmm14
  orps xmm5, xmm14
  orps xmm6, xmm14
  orps xmm7, xmm14

.global zrx_program_start
.hidden zrx_program_start
zrx_program_start:
  nop

.global zrx_program_read_dataset
.hidden zrx_program_read_dataset
zrx_program_read_dataset:
  mov ecx, ebp
  and ecx, RANDOMX_DATASET_BASE_MASK

  xor r8, qword ptr [rdi+rcx]
  xor rbp, rax
  mov edx, ebp
  ror rbp, 32
  and edx, RANDOMX_DATASET_BASE_MASK

  prefetchnta byte ptr [rdi+rdx]
  xor r9,  qword ptr [rdi+rcx+8]
  xor r10, qword ptr [rdi+rcx+16]
  xor r11, qword ptr [rdi+rcx+24]
  xor r12, qword ptr [rdi+rcx+32]
  xor r13, qword ptr [rdi+rcx+40]
  xor r14, qword ptr [rdi+rcx+48]
  xor r15, qword ptr [rdi+rcx+56]

.global zrx_program_read_dataset_sshash_init
.hidden zrx_program_read_dataset_sshash_init
zrx_program_read_dataset_sshash_init:
  mov qword ptr [rsp+24], r8
  mov qword ptr [rsp+32], r9
  mov qword ptr [rsp+40], r10
  mov qword ptr [rsp+48], r11
  mov qword ptr [rsp+56], r12
  mov qword ptr [rsp+64], r13
  mov qword ptr [rsp+72], r14
  mov qword ptr [rsp+80], r15
  mov qword ptr [rsp+88], rbx
  mov ebx, ebp
  shr ebx, 6
  and ebx, (RANDOMX_DATASET_BASE_MASK / 64)

  xor rbp, rax
  ror rbp, 32

.global zrx_program_read_dataset_sshash_fin
.hidden zrx_program_read_dataset_sshash_fin
zrx_program_read_dataset_sshash_fin:
  xor r8, qword ptr [rsp+24]
  xor r9, qword ptr [rsp+32]
  xor r10, qword ptr [rsp+40]
  xor r11, qword ptr [rsp+48]
  xor r12, qword ptr [rsp+56]
  xor r13, qword ptr [rsp+64]
  xor r14, qword ptr [rsp+72]
  xor r15, qword ptr [rsp+80]
  mov rbx, qword ptr [rsp+88]

.global zrx_program_loop_store
.hidden zrx_program_loop_store
zrx_program_loop_store:
  mov rcx, qword ptr [rsp+16]
  mov qword ptr [rcx+0], r8
  mov qword ptr [rcx+8], r9
  mov qword ptr [rcx+16], r10
  mov qword ptr [rcx+24], r11
  mov qword ptr [rcx+32], r12
  mov qword ptr [rcx+40], r13
  mov qword ptr [rcx+48], r14
  mov qword ptr [rcx+56], r15
  mov rcx, qword ptr [rsp+8]
  aesenc xmm0, xmm4
  aesdec xmm1, xmm4
  aesenc xmm2, xmm4
  aesdec xmm3, xmm4
  aesenc xmm0, xmm5
  aesdec xmm1, xmm5
  aesenc xmm2, xmm5
  aesdec xmm3, xmm5
  aesenc xmm0, xmm6
  aesdec xmm1, xmm6
  aesenc xmm2, xmm6
  aesdec xmm3, xmm6
  aesenc xmm0, xmm7
  aesdec xmm1, xmm7
  aesenc xmm2, xmm7
  aesdec xmm3, xmm7
  movapd xmmword ptr [rcx+0], xmm0
  movapd xmmword ptr [rcx+16], xmm1
  movapd xmmword ptr [rcx+32], xmm2
  movapd xmmword ptr [rcx+48], xmm3

.global zrx_program_loop_end
.hidden zrx_program_loop_end
zrx_program_loop_end:
  nop

.balign 64
.global zrx_dataset_init
.hidden zrx_dataset_init
zrx_dataset_init:
  push rbx
  push rbp
  push r12
  push r13
  push r14
  push r15
  mov rdi, qword ptr [rdi]
  mov rbp, rdx
  push rcx
zrx_init_block_loop:
  prefetchw byte ptr [rsi]
  mov rbx, rbp
  .byte 232
  .int SUPERSCALAR_OFFSET - (zrx_call_offset - zrx_dataset_init)
zrx_call_offset:
  mov qword ptr [rsi+0], r8
  mov qword ptr [rsi+8], r9
  mov qword ptr [rsi+16], r10
  mov qword ptr [rsi+24], r11
  mov qword ptr [rsi+32], r12
  mov qword ptr [rsi+40], r13
  mov qword ptr [rsi+48], r14
  mov qword ptr [rsi+56], r15
  add rbp, 1
  add rsi, 64
  cmp rbp, qword ptr [rsp]
  jb zrx_init_block_loop
  pop rax
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbp
  pop rbx
  ret

.balign 64
.global zrx_program_epilogue
.hidden zrx_program_epilogue
zrx_program_epilogue:
  mov rcx, qword ptr [rsp+448]
  mov qword ptr [rcx+0], r8
  mov qword ptr [rcx+8], r9
  mov qword ptr [rcx+16], r10
  mov qword ptr [rcx+24], r11
  mov qword ptr [rcx+32], r12
  mov qword ptr [rcx+40], r13
  mov qword ptr [rcx+48], r14
  mov qword ptr [rcx+56], r15
  movdqa xmmword ptr [rcx+64], xmm0
  movdqa xmmword ptr [rcx+80], xmm1
  movdqa xmmword ptr [rcx+96], xmm2
  movdqa xmmword ptr [rcx+112], xmm3
  lea rcx, [rcx+64]
  movdqa xmmword ptr [rcx+64], xmm4
  movdqa xmmword ptr [rcx+80], xmm5
  movdqa xmmword ptr [rcx+96], xmm6
  movdqa xmmword ptr [rcx+112], xmm7
  mov r15, qword ptr [rsp+280]
  mov r14, qword ptr [rsp+272]
  mov r13, qword ptr [rsp+264]
  mov r12, qword ptr [rsp+256]
  mov rbp, qword ptr [rsp+232]
  mov rbx, qword ptr [rsp+224]
  add rsp, 456
  ret

.balign 64
.global zrx_sshash_load
.hidden zrx_sshash_load
zrx_sshash_load:
  xor r8, qword ptr [rbx+0]
  xor r9, qword ptr [rbx+8]
  xor r10, qword ptr [rbx+16]
  xor r11, qword ptr [rbx+24]
  xor r12, qword ptr [rbx+32]
  xor r13, qword ptr [rbx+40]
  xor r14, qword ptr [rbx+48]
  xor r15, qword ptr [rbx+56]
.global zrx_sshash_prefetch
.hidden zrx_sshash_prefetch
zrx_sshash_prefetch:
  and rbx, RANDOMX_CACHE_MASK

  shl rbx, 6
  add rbx, rdi
  prefetchnta byte ptr [rbx]
.global zrx_sshash_end
.hidden zrx_sshash_end
zrx_sshash_end:
  nop

.balign 64
.global zrx_sshash_init
.hidden zrx_sshash_init
zrx_sshash_init:
  lea r8, [rbx+1]
  and rbx, RANDOMX_CACHE_MASK

  shl rbx, 6
  add rbx, rdi
  prefetchnta byte ptr [rbx]
  imul r8, qword ptr [rip+zrx_r0_mul]
  mov r9, qword ptr [rip+zrx_r1_add]
  xor r9, r8
  mov r10, qword ptr [rip+zrx_r2_add]
  xor r10, r8
  mov r11, qword ptr [rip+zrx_r3_add]
  xor r11, r8
  mov r12, qword ptr [rip+zrx_r4_add]
  xor r12, r8
  mov r13, qword ptr [rip+zrx_r5_add]
  xor r13, r8
  mov r14, qword ptr [rip+zrx_r6_add]
  xor r14, r8
  mov r15, qword ptr [rip+zrx_r7_add]
  xor r15, r8
  jmp zrx_program_end

.balign 64
zrx_r0_mul: .quad 6364136223846793005
zrx_r1_add: .quad 9298411001130361340
zrx_r2_add: .quad 12065312585734608966
zrx_r3_add: .quad 9306329213124626780
zrx_r4_add: .quad 5281919268842080866
zrx_r5_add: .quad 10536153434571861004
zrx_r6_add: .quad 3398623926847679864
zrx_r7_add: .quad 9549104520008361294

.balign 64
.global zrx_program_end
.hidden zrx_program_end
zrx_program_end:
  nop

/*
 * RandomX v1 variants of the dataset read and loop store fragments:
 * "mx" is mixed instead of "ma", and F is XORed with E instead of AES-mixed.
 */
.global zrx_v1_read_dataset
.hidden zrx_v1_read_dataset
zrx_v1_read_dataset:
  mov ecx, ebp
  and ecx, RANDOMX_DATASET_BASE_MASK

  xor r8, qword ptr [rdi+rcx]
  ror rbp, 32
  xor rbp, rax
  mov edx, ebp
  and edx, RANDOMX_DATASET_BASE_MASK

  prefetchnta byte ptr [rdi+rdx]
  xor r9,  qword ptr [rdi+rcx+8]
  xor r10, qword ptr [rdi+rcx+16]
  xor r11, qword ptr [rdi+rcx+24]
  xor r12, qword ptr [rdi+rcx+32]
  xor r13, qword ptr [rdi+rcx+40]
  xor r14, qword ptr [rdi+rcx+48]
  xor r15, qword ptr [rdi+rcx+56]

.global zrx_v1_read_dataset_sshash_init
.hidden zrx_v1_read_dataset_sshash_init
zrx_v1_read_dataset_sshash_init:
  mov qword ptr [rsp+24], r8
  mov qword ptr [rsp+32], r9
  mov qword ptr [rsp+40], r10
  mov qword ptr [rsp+48], r11
  mov qword ptr [rsp+56], r12
  mov qword ptr [rsp+64], r13
  mov qword ptr [rsp+72], r14
  mov qword ptr [rsp+80], r15
  mov qword ptr [rsp+88], rbx
  mov ebx, ebp
  shr ebx, 6
  and ebx, (RANDOMX_DATASET_BASE_MASK / 64)

  ror rbp, 32
  xor rbp, rax

.global zrx_v1_loop_store
.hidden zrx_v1_loop_store
zrx_v1_loop_store:
  mov rcx, qword ptr [rsp+16]
  mov qword ptr [rcx+0], r8
  mov qword ptr [rcx+8], r9
  mov qword ptr [rcx+16], r10
  mov qword ptr [rcx+24], r11
  mov qword ptr [rcx+32], r12
  mov qword ptr [rcx+40], r13
  mov qword ptr [rcx+48], r14
  mov qword ptr [rcx+56], r15
  mov rcx, qword ptr [rsp+8]
  xorpd xmm0, xmm4
  xorpd xmm1, xmm5
  xorpd xmm2, xmm6
  xorpd xmm3, xmm7
  movapd xmmword ptr [rcx+0], xmm0
  movapd xmmword ptr [rcx+16], xmm1
  movapd xmmword ptr [rcx+32], xmm2
  movapd xmmword ptr [rcx+48], xmm3

.global zrx_v1_end
.hidden zrx_v1_end
zrx_v1_end:
  nop

/* MXCSR access for the VM (leaf functions, System V red zone). */
.text
.global zrx_get_mxcsr
.hidden zrx_get_mxcsr
zrx_get_mxcsr:
  stmxcsr dword ptr [rsp-4]
  mov eax, dword ptr [rsp-4]
  ret

.global zrx_set_mxcsr
.hidden zrx_set_mxcsr
zrx_set_mxcsr:
  mov dword ptr [rsp-4], edi
  ldmxcsr dword ptr [rsp-4]
  ret

.section .note.GNU-stack,"",%progbits
