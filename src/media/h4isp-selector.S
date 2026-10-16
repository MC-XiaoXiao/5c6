/* OV9762 revision 0x20 uses H4ISP's existing setfile-file loader.
 * Other sensors/revisions continue through the original C1 constructor.
 * All addresses are relative; the loader owns the setfile allocation/lifetime.
 */
.syntax unified
.thumb
.text
.p2align 2
.global h4isp_selector
.thumb_func
h4isp_selector:
    movw r12, #0x9762
    cmp r1, r12
    bne original
    cmp r2, #0x20
    bne original
    movs r3, #0
    str r3, [r0]
    str r3, [r0,#4]
    adr r3, setfile_path
    str r3, [r0,#8]
    bx lr
original:
    push {r4,r7,lr}
    add r7, sp, #4
    b.w selector_resume
.p2align 2
setfile_path:
    .asciz "/usr/local/share/firmware/isp/7652_01XX.dat"
