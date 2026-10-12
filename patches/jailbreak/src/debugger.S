/* Offline equivalent of Aquila's debugger flag writes. Read the original
 * debug flags and replace their low byte for PE_i_can_has_debugger callers.
 * Do not write zero-fill BSS into a Mach-O file or alter the port bootargs.
 */
.syntax unified
.thumb
.section .text.debugger,"ax",%progbits
.balign 4
.global debugger_hook
debugger_hook:
    cbz     r0, debugger_return
    adr     r1, debugger_hook
    ldr     r2, debugger_delta
    add     r1, r2
    ldr     r1, [r1]
    bic     r1, r1, #255
    orr     r1, r1, #1
    str     r1, [r0]
debugger_return:
    movs    r0, #1
    bx      lr
.balign 4
debugger_delta: .word debugger_flags - debugger_hook
