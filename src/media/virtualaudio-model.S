/* Local wrapper for VirtualAudio's single hw.model query. The OS identity
 * remains unchanged. Preserve the real syscall result, length and ABI.
 */
.syntax unified
.thumb
.text
.p2align 2
.global virtualaudio_model
.thumb_func
virtualaudio_model:
    push {r4-r7,lr}
    sub sp, #4
    mov r4, r1
    mov r5, r2
    ldr r6, [r5]
    ldr r7, [sp,#24]
    str r7, [sp]
    blx sysctl_stub
    cmp r0, #0
    bne done
    cmp r6, #6
    blo done
    ldr r6, [r5]
    cmp r6, #6
    bne done
    ldrb r6, [r4]
    cmp r6, #'N'
    bne done
    ldrb r6, [r4,#1]
    cmp r6, #'4'
    bne done
    ldrb r6, [r4,#2]
    cmp r6, #'8'
    beq suffix
    cmp r6, #'9'
    bne done
suffix:
    ldrb r6, [r4,#3]
    cmp r6, #'A'
    bne done
    ldrb r6, [r4,#4]
    cmp r6, #'P'
    bne done
    ldrb r6, [r4,#5]
    cmp r6, #0
    bne done
    movs r6, #'2'
    strb r6, [r4,#2]
done:
    add sp, #4
    pop {r4-r7,pc}
