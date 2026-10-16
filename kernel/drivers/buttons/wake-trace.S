/* Read-only Buttons wake trace, hosted by AppleM68Buttons.
 * Preserve registers/flags and replay the displaced function prologue.
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

.globl _buttons_event
_buttons_event:
    SAVE
    ldr r3, [r0, #248]
    adr r0, buttons_format
.globl _buttons_printf
_buttons_printf: bl #4
    RESTORE
    push {r4-r7,lr}
    add r7, sp, #12
.globl _buttons_resume
_buttons_resume: b.w #4
.p2align 2
buttons_format: .asciz "[WAKE6] Buttons index=%x raw=%x previous-bits=%x\n"
