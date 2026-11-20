// Offsets are relative to the linked kext. The adapter occupies the RX
// padding at 0x400. The patch extends __text back to include these bytes.
.syntax unified
.thumb
.text
_image:
.org 0x400
_probe:
    cmp r1, #0xd7
    beq _probe_ok
    uxtb r0, r0
    cmp r0, #3
    bhs.w _probe_fail
_probe_ok:
    b.w _probe_return
_configure:
    uxtb r0, r0
    cmp r0, #0xd7
    beq _d7
    cmp r0, #0xd3 // Replay the stock comparison before the original bne.
    b.w _configure_compare
_d7:
    ldr r0, [r4]
    ldr r6, [r0, #0x6c]
    mov r0, r4
    ldr r1, _name_offset
_name_pc:
    add r1, pc
    movs r2, #0x14
    movs r3, #0
    movs r5, #0x20
    str r5, [sp]
    blx r6
    ldr r0, _rate
    str.w r0, [r4, #0xf4]
    movs r5, #0
    str.w r5, [r4, #0xf8]
    ldr r0, _interval
    str.w r0, [r4, #0xfc]
    str.w r5, [r4, #0x100]
    movs r0, #1
    b.w _configure_return
_fifo:
    cmp r0, #0xd7
    beq _fifo_ok
    cmp r0, #0xd5
    beq _fifo_ok
    b.w _fifo_legacy
_fifo_ok:
    b.w _fifo_return
.p2align 2
_name_offset: .long 0x49d9 // existing ChipID string at 0x4e01 - (0x424 + 4)
_rate: .long 100000000
_interval: .long 10000000
_adapter_end:
.org 0x2710
    b.w _probe
.org 0x2716
_probe_return:
.org 0x272e
_probe_fail:
.org 0x2bca
    b.w _configure
.org 0x2bce
_configure_compare:
.org 0x2c88
_configure_return:
.org 0x37fe
    b.w _fifo
.org 0x3802
_fifo_legacy:
.org 0x385c
_fifo_return:
