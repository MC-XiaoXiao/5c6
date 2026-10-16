/* Read-only CLCD power traces, hosted by AppleH5PCLCD.
 * Preserve registers/flags and replay each displaced prologue/epilogue.
 */
.syntax unified
.section __TEXT,__text,regular,pure_instructions
.thumb
.p2align 2
.macro SAVE
    push.w {r0-r4,r12,lr}
    mrs r4, apsr
    push {r4}
    mov r4, sp
    bic r12, r4, #7
    mov sp, r12
.endm
.macro RESTORE
    mov sp, r4
    pop {r4}
    msr APSR_nzcvqg, r4
    pop.w {r0-r4,r12,lr}
.endm

.globl _clcd_enter
_clcd_enter:
    SAVE
    ldr r1, [r0, #632]
    ldr r2, [r0, #636]
    ldr r3, [r0, #640]
    adr r0, clcd_enter_format
.globl _clcd_enter_printf
_clcd_enter_printf: bl #4
    RESTORE
    push {r4-r7,lr}
    add r7, sp, #12
.globl _clcd_enter_resume
_clcd_enter_resume: b.w #4
.p2align 2
clcd_enter_format: .asciz "[WAKE6] CLCD enter req=%x panelreq=%x current=%x\n"

.p2align 2
.globl _clcd_exit
_clcd_exit:
    SAVE
    ldr r0, [r4, #20]
    ldr r1, [r0, #632]
    ldr r2, [r0, #640]
    ldr r3, [r0, #644]
    adr r0, clcd_exit_format
.globl _clcd_exit_printf
_clcd_exit_printf: bl #4
    RESTORE
    add sp, sp, #20
    pop.w {r8,r10,r11}
.globl _clcd_exit_resume
_clcd_exit_resume: b.w #4
.p2align 2
clcd_exit_format: .asciz "[WAKE6] CLCD exit req=%x current=%x panel=%x\n"
