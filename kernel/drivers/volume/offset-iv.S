/* LwVM offset-IV backport. Placed in this driver's executable header padding
 * at 0x807eb400, with calls bound to the verified iOS 6 crypto/accessor ABI.
 * All branches are PC relative; no new slide relocations or instance fields.
 */
.syntax unified
.thumb
.text
.p2align 2
.globl _lwvm6_install_key_iv
.thumb_func
_lwvm6_install_key_iv:
    /* r4 = partition; caller stack+12 = manager. The original key loader
     * has a four-byte-aligned frame, so align the crypto scratch explicitly.
     * Preserve r1-r3/r5/r6/r12, restore the original active marker, return r0=0.
     */
    push.w {r0-r3,r5,r6,r12,lr}
    mov r6, sp
    sub sp, #128
    mov r5, sp
    bic r5, r5, #7
    mov sp, r5
    str.w r0, [r4,#336]
    movs r0, #0
    str r0, [r4,#32]
    ldr r0, [r6,#44]
    ldr r0, [r0,#88]
    ldrb r0, [r0,#48]
    tst r0, #1
    beq Lkey_done
    mov r0, sp
.globl _iv_sha1_init
_iv_sha1_init:
    .short 0xf000,0xf800
    mov r0, sp
    add.w r1, r4,#340
    movs r2, #32
.globl _iv_sha1_update
_iv_sha1_update:
    .short 0xf000,0xf800
    add r0, sp,#96
    mov r1, sp
.globl _iv_sha1_final
_iv_sha1_final:
    .short 0xf000,0xf800
    add r0, sp,#96
    add.w r1, r4,#48
.globl _iv_aes_setup
_iv_aes_setup:
    .short 0xf000,0xf800
    movs r0, #8
    str r0, [r4,#32]
Lkey_done:
    movs r0, #0
    str r0, [r6]
    ldr r1, [r6,#4]
    strb.w r1, [r4,#384]
    mov sp, r6
    pop.w {r0-r3,r5,r6,r12,lr}
    bx lr

.p2align 2
.globl _lwvm6_setcpaddr_offset
.thumb_func
_lwvm6_setcpaddr_offset:
    /* Keep bufattr_setcpaddr, then apply the mapped offset only to the
     * LwVM metadata CP entry with OFF_IV. Per-file CP behavior is unchanged.
     */
    push.w {r0-r3,r12,lr}
.globl _offset_original_cpaddr
_offset_original_cpaddr:
    .short 0xf000,0xf800
    ldr r1, [sp,#4]
    ldr r1, [r1]
    tst r1, #8
    beq Loffset_done
    ldr r0, [sp]
    ldr r1, [sp,#104]
    ldr r2, [sp,#108]
.globl _offset_setcpoff
_offset_setcpoff:
    .short 0xf000,0xf800
Loffset_done:
    pop.w {r0-r3,r12,lr}
    bx lr

.p2align 2
.globl _lwvm6_split_offset
.thumb_func
_lwvm6_split_offset:
    /* Metadata uses the second mapped chunk's byte start; file CP entries
     * retain the offset supplied by the original split strategy.
     */
    push.w {r0-r3,r12,lr}
    ldr r3, [r0]
    ldr r12, [sp,#88]
    cmp r3, r12
    bne Lsplit_original
    ldr r3, [r3]
    tst r3, #8
    beq Lsplit_original
    ldr r1, [sp,#112]
    ldr r2, [sp,#116]
Lsplit_original:
.globl _split_setcpoff
_split_setcpoff:
    .short 0xf000,0xf800
    pop.w {r0-r3,r12,lr}
    bx lr
