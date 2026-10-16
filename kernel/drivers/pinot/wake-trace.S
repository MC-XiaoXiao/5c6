/* Read-only Pinot power traces, hosted by ApplePinotLCD.
 * Preserve registers/flags and replay the displaced prologue/state write.
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

.globl _pinot_enter
_pinot_enter:
    SAVE
    ldrb r2, [r0, #117]
    ldr r3, [r0, #112]
    adr r0, pinot_enter_format
.globl _pinot_enter_printf
_pinot_enter_printf: bl #4
    RESTORE
    push {r4-r7,lr}
    add r7, sp, #12
.globl _pinot_enter_resume
_pinot_enter_resume: b.w #4
.p2align 2
pinot_enter_format: .asciz "[WAKE6] Pinot enter enable=%x current=%x panelclass=%x\n"

.p2align 2
.globl _pinot_done
_pinot_done:
    SAVE
    mov r1, r10
    ldrb r2, [r5, #117]
    ldr r3, [r5, #112]
    adr r0, pinot_done_format
.globl _pinot_done_printf
_pinot_done_printf: bl #4
    RESTORE
    strb.w r10, [r5, #117]
.globl _pinot_done_resume
_pinot_done_resume: b.w #4
.p2align 2
pinot_done_format: .asciz "[WAKE6] Pinot done enable=%x previous=%x panelclass=%x\n"
