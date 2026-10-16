/* Master-clock adapter for the linked native6 CS81 driver.
 * AppleEmbeddedAudio::getIISMaster and the register RMW method use the
 * verified 10B329/10B350 vtable. No new fields or absolute addresses.
 * Like native N49, a slave IIS requires the codec to supply the clock.
 */
.syntax unified
.thumb
.text
.balign 4
.global cs81_master_clock
.type cs81_master_clock, %function
.thumb_func
cs81_master_clock:
    push {r4, r5, r6, lr}
    mov r4, r0
    ldr r1, [r0]
    ldr.w r1, [r1, #0x42c]     /* getIISMaster() */
    blx r1
    cmp r0, #0
    mov.w r3, #0x0c
    it eq
    moveq r3, #0x80
    ldr r0, [r4]
    ldr.w r5, [r0, #0x498]     /* native register read/modify/write */
    mov r0, r4
    movs r1, #0x0f
    movs r2, #0xcf
    blx r5
    pop {r4, r5, r6, pc}
.size cs81_master_clock, .-cs81_master_clock
