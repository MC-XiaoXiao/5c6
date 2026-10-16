/* Adapted from Aquila v2 (MIT; LICENSE.aquila), commit
 * 031ddb3aa9d50200bcd953d6c371cc5a79e5049d, common/src/sandbox.s.
 * Same path policy; PC-relative calls and branches survive kernel sliding.
 * Generation supplies vn_getpath, memcmp_fn, sb_return and original_prologue.
 */
.syntax unified
.thumb
.section .text.hook,"ax",%progbits
.balign 4
.global sandbox_hook
sandbox_hook:
    pop     {r0, r1}
    push    {r0-r4, lr}
    sub     sp, #0x44
    ldr     r4, [r3, #0x14]
    cmp     r4, #0
    beq     actually_eval
    mov     r0, r4
    adr.w   r4, sandbox_hook
    ldr     r3, vn_delta
    add     r3, r4
    mov     r1, sp
    movs    r2, #0x40
    str     r2, [sp, #0x40]
    add     r2, sp, #0x40
    blx     r3
    cmp     r0, #28
    beq     path_ready
    cmp     r0, #0
    bne     actually_eval
path_ready:
    mov     r0, sp
    adr     r1, var_mobile_path
    movs    r2, #19
    ldr     r3, memcmp_delta
    add     r3, r4
    blx     r3
    cmp     r0, #0
    bne     allow
    mov     r0, sp
    adr     r1, preferences_apple_path
    movs    r2, #49
    ldr     r3, memcmp_delta
    add     r3, r4
    blx     r3
    cmp     r0, #0
    beq     actually_eval
    mov     r0, sp
    adr     r1, preferences_path
    movs    r2, #39
    ldr     r3, memcmp_delta
    add     r3, r4
    blx     r3
    cmp     r0, #0
    bne     actually_eval
allow:
    add     sp, #0x44
    pop     {r0}
    movs    r1, #0
    str     r1, [r0]
    movs    r1, #0x18
    str     r1, [r0, #4]
    pop     {r1-r4, pc}
actually_eval:
    add     sp, #0x44
    ldr     r0, [sp, #0x14]
    mov     lr, r0
    pop     {r0-r4}
    add     sp, #4
    .incbin "original_prologue"
    b.w     sb_return
.balign 4
var_mobile_path:        .asciz "/private/var/mobile"
.balign 4
preferences_path:       .asciz "/private/var/mobile/Library/Preferences"
.balign 4
preferences_apple_path: .asciz "/private/var/mobile/Library/Preferences/com.apple"
.balign 4
vn_delta:              .word vn_getpath - sandbox_hook
memcmp_delta:          .word memcmp_fn - sandbox_hook

.section .text.trampoline,"ax",%progbits
.global sandbox_trampoline
sandbox_trampoline:
    push    {r0, r1}
    b.w     sandbox_hook
    nop
