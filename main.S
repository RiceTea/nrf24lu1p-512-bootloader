; USB bootloader for nrf24lu1+.  Attempts to match the protocol given in the
; NRF24LU1+ datasheet. Code is less than 512 bytes, so it fits in 1 page.
;
; NOTE: Currently always erases the given page on a flash write cmd, but
; the Nordic version only erases the page when necessary.
;
; NOTE:
;   Set PAN_011 to cover hardware issuse with older chips (before ~2009).
; See PAN-011 for more info:
; https://www.nordicsemi.com/eng/nordic/download_resource/9405/1/65061627
;
.module main

.include "nrf24lu1_sfr.S"
.include "usb_regs.S"
.include "config.S"

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                               options                               ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

; Where to store the bootloader.
; 1 -> last page of 16kb flash
; 0 -> last page of 32kb flash
; BOOTLOADER_BLOCK_CUSTOM can alternatively be used to store it in a custom page.
FLASH_SIZE_16 = 1
; BOOTLOADER_BLOCK_CUSTOM   = 0x6600 ; should be divisible by page size (0x200)

; If set, this will prevent read back of the flash when the RDIS bit is configured
; by the info page. Disabling this feature will allow read back of the flash always.
RDIS_ENABLE = 0

; Enables watchdog timer.
KICK_WATCHDOG = 1

; work around for hardware bug discussed in PAN-011
PAN_011 = 0

; store bootloader at start of flash, mainly for debugging purposes
BOOTLOADER_AT_START = 0


; bit register definitions
BIT_REG_0_7 = 0x20
BIT_SEND_USB_DATA = 0x00
BIT_FLASH_HALF_SELECT = 0x01
BIT_SEND_ZERO = 0x02
BIT_WRITE_BLOCK = 0x03


; address space definitions
_BLOCK_SIZE             = 0x0200
_BOOTLOADER_BLOCK_F16   = 0x3e00
_BOOTLOADER_BLOCK_F32   = 0x7e00
_XRAM                   = 0x8000

.if FLASH_SIZE_16
_BOOTLOADER_BLOCK       = _BOOTLOADER_BLOCK_F16
.else
_BOOTLOADER_BLOCK       = _BOOTLOADER_BLOCK_F32
.endif

; _BOOTLOADER_BLOCK_DEBUG = 0x6a00

; Reset vector that jumps to bootloader
.area HOME         (ABS, CODE)

.if BOOTLOADER_AT_START
_BOOTLOADER_BLOCK       = 0x0000
.else
.org 0x0000
reset_vec:
    ljmp _BOOTLOADER_BLOCK
.endif

.org _BOOTLOADER_BLOCK

_BLOCK_OFFSET = _BOOTLOADER_BLOCK % 0x800

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                 code that loads bootloader to xram                  ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
_main:
.if BOOTLOADER_AT_START
    ljmp _at_start_logitech_boot
_at_start_logitech_boot:
.endif

    clr     _EA ; disable interrupts, incase we are not executing from reset

    ; 8051 stack grows down (i.e. is incremented, not decremented). Only thing
    ; careful about is that we don't overlap the bit registers in byte 0x20
    ; and don't overlap r0-r7 in 0x00-0x07.
    mov     _SP, #0x50

; copies the bootloader page into ram, and then begins execution
; at where _program_start is in xram
_load_bootloader_into_xram:

.if KICK_WATCHDOG
    acall   _kick_dog
.endif

    mov     dptr, #_BOOTLOADER_BLOCK ; dptr0 -> program code to be loaded
    inc     _DPS ; #0x01
    mov     dptr, #(_XRAM + _BLOCK_OFFSET) ; dptr1 -> xram where to store code

    ; copy total 512 bytes
    mov     r7, #0x00
    acall   _copy_between_dptr   ; r7 == 0 => 256 bytes
    acall   _copy_between_dptr   ; r7 == 0 => 256 bytes

    ; jump to ram and begin execution of code
    ljmp    #(_XRAM + (_program_start - _BOOTLOADER_BLOCK) + _BLOCK_OFFSET)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;           start of program code that is loaded into xram            ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
_program_start:

.if PAN_011
    ; Note: Need on older chips with buggy USB hardware
    mov     _CKCON, #0x02
.endif

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                          usb initialization                         ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

; setup code for usb
_usbInit:
    ; disconnect the usb device (i.e. disconnect 1.5kΩ USB D+ pull-up)
    mov     dptr, #_usbcs
    mov     a, #0x08
    movx    @dptr, a ; usbcs = 0x08, disable pull-up

    clr a
    mov BIT_REG_0_7, a     ; clr bit registers 0x00..0x07
    mov r0, a

    ; delay for ~12ms @ 16MHz
    ; ((((256 * 3) + 1) * 256)+1) / 16000000 = .01230406
    mov     r6, a      ; 1 bytes, 1 cycles
00002$:
    mov     r7, a      ; 1 bytes, 1 cycles
00001$:
    djnz    r7, 00001$ ; 3 bytes, 3 cycles
    djnz    r6, 00002$ ; 3 bytes, 3 cycles

    ; reconnect the usb device
    ; clr     a ;
    ; NOTE: EXPECT a == 0 from above
    movx    @dptr, a ; usbcs = 0x00, enable pull-up

    ;   setup in/out bulk ints
    mov     a, #0x03
    mov     dptr, #_inbulkval            ; dptr = _inbulkval
    movx    @dptr, a                     ; inbulkval = 0xff
    inc     dptr                         ; dptr = _outbulkval
    movx    @dptr, a                     ; outbulkval = 0xff

    mov     dptr, #_in_irq               ; dptr = _in_irq
    mov     a, #0xff
    movx    @dptr, a ; (0xC7A9) in_irq;
    inc     dptr
    movx    @dptr, a ; (0xC7AA) out_irq;
    inc     dptr
    movx    @dptr, a ; (0xC7AB) usbirq;
    inc     dptr
    mov     a, #0x03
    movx    @dptr, a ; (0xC7AC) in_ien;
    inc     dptr
    movx    @dptr, a ; (0xC7AD) out_ien;
    inc     dptr
    mov     a, #0x01 ; (0xC7AE) usbien;
    movx    @dptr, a

    ;   setup the USB RAM
    mov     a, #0x20                     ; a = 0x40/2
    mov     dptr, #_bout1addr            ; dptr = _bout1addr
    movx    @dptr, a
    mov     dptr, #_binstaddr            ; dptr = _binstaddr
    movx    @dptr, a
    inc     dptr         ; #_bin1addr    ; dptr = _bin1addr
    movx    @dptr, a

    ; clear usb interrupts
    clr     _USBIRQ

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                           start main loop                           ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
_start_loop:

    ; wait for USB interrupt

.if KICK_WATCHDOG
    acall   _kick_dog
.endif
    jnb     _USBIRQ, _start_loop

    clr     _USBIRQ

; check which interrupt was triggered
_handle_ivec:
    mov     dptr, #_ivec
    movx    a, @dptr

; handle int_sudav interrupt
; sends device/conf descriptor based on request
int_sudav:
    cjne    a, #_INT_SUDAV, int_ep1_out
    mov     dptr, #(_usbReqGetDesc + 0x0006)
    movx    a, @dptr
    mov     r0, a
    mov     dptr, #(_usbReqGetDesc + 0x0003)
    movx    a, @dptr ; a = usbReqGetDesc.descType

    ;   if descType == 0x01
    ;     dptr = _usb_dev_desc
    ;   else // i.e. if descType == 0x02
    ;     dptr = _usb_conf_desc
    mov     dptr, #(_usb_dev_desc + _XRAM - _BOOTLOADER_BLOCK + _BLOCK_OFFSET)
    cjne    a, #0x02, 00001$
    mov     dptr, #(_usb_conf_desc + _XRAM - _BOOTLOADER_BLOCK + _BLOCK_OFFSET)
00001$:
    acall   _finish_usb_ep0_transaction

; handle int for int ep1 out
int_ep1_out:
    cjne    a, #_INT_EP1_OUT, skip_ep1_out
    ; following branches assume _DPS == 0x00, so set it here
    mov     _DPS, #0x00

; if BIT_WRITE_BLOCK is set, then the following blocks from the host
; are treated as data packets that follow CMD_WRITE_INIT
write_block: ;
    ; r1: low byte of address to write
    ; r2: high order byte of address to write
    ; r3: number of packets to write
    jnb     BIT_WRITE_BLOCK, receive_command

    acall   _flash_wen

    mov     dptr, #_out1buf
    inc     _DPS
    mov     _DPH1, r2
    mov     _DPL1, r1

    mov     r7, #0x40
    acall   _copy_between_dptr

    clr     _WEN

    mov r2, _DPH1
    mov r1, _DPL1

    setb    BIT_SEND_ZERO

    ; do while r3 > 0
    djnz    r3, skip_ep1_out

    clr     BIT_WRITE_BLOCK
skip_ep1_out:
    ajmp   usb_handling_final

; receive a command form the host
receive_command:
; not a data block, so host has sent a cmd
    mov     dptr, #_out1buf
    movx    a, @dptr
    mov     r6, a             ; r6 == cmd code
    inc     dptr
    movx    a, @dptr
    mov     r7, a             ; r7 == cmd argument

; NOTE: following branches relay on r6 remaining set to cmd code. Each branch
; chains to the next.

; cmd1: version command
; send the bootloader version to the host
cmd1:
    cjne    r6, #CMD_VERSION, cmd2
    mov     dptr, #_in1buf
    mov     a, #BOOTLOADER_VERSION_HI
    movx    @dptr, a
    inc     dptr
    mov     a, #BOOTLOADER_VERSION_LO
    movx    @dptr, a
    ; number of bytes to write to ep1in
    mov     dptr, #_in1bc
    mov     a, #0x02
    movx    @dptr, a

; cmd2: write a page of flash.
; The next few usb packets are written to the flash
cmd2:
    cjne    r6, #CMD_WRITE_INIT, cmd3
    acall   _flash_erase_page
    mov     a, r7
    clr     c
    rlc     a ; a = r7 * 2

    mov     r3, #0x08   ; number of packets to write
    mov     r2, a       ; high order byte of address to write
    mov     r1, #0x00   ; low byte of address to write

    setb    BIT_WRITE_BLOCK
    setb    BIT_SEND_ZERO

; cmd3: read a flash page
; output depends on whether rd
cmd3:
    cjne    r6, #CMD_READ_FLASH, cmd4

.if RDIS_ENABLE
    jb      _RDIS, readback_disabled
.endif

readback_enabled: ; flash read back enabled, send the request block
    ; get flash block address
    mov     a, r7
    mov     b, #0x40
    mul     ab
    mov     _DPL, a ; a = dpl
    clr     a
    jb      BIT_FLASH_HALF_SELECT, 00001$
    mov     a, #0x40
00001$:
    add     a, _B
    mov     _DPH, a ; a = dph

    inc     _DPS
    mov     dptr, #_in1buf

    mov     r7, #0x40
    acall   _copy_between_dptr

    mov     dptr, #_in1bc
    mov     a, #0x40
    movx    @dptr, a

.if RDIS_ENABLE
    sjmp    cmd4

readback_disabled: ; flash read back disabled, send block full of 0xff or 0x00
                   ; depending on whether the block is unused (0xff) or
                   ; used (0x00).
    ; r7 == block number, so need to find its page number
    mov     a, r7
    clr     c
    rrc     a ; block_num / 2
    clr     c
    rrc     a ; block_num / 4
    clr     c
    rrc     a ; block_num / 8
    clr     c
    rlc     a ; (block_num / 8) * 2

    mov     r7, #0x00 ; offset == 0x00
    jb      BIT_FLASH_HALF_SELECT, 00001$
    mov     r7, #0x40 ; offset == 0x40
00001$:
    add     a, r7 ; a <- pn*2 = (block_num / 8) * 2 + offset

    mov     _DPH, a ; dptr = 0x0200 * pn
    mov     _DPL, #0x00

    mov     r3, #0xff ; r3 stores whether the block is used, and is the
                      ;   value used to fill the response packet
                      ; unused page => 0xff
                      ; used page => 0x00
    mov     r4, #0x02 ; check_half_page loop 2 times
check_half_page:
    mov     r5, #0x00 ; do check_used_byte 256 times
check_used_byte:
    movx    a, @dptr
    inc     dptr
    cpl     a
    jz      byte_not_used
    mov     r3, #0x00
byte_not_used:
    djnz    r5, check_used_byte
    djnz    r4, check_half_page
    ; r3 now stores 0xff if the page is unused

    mov     dptr, #_in1buf
    mov     r7, #0x40
    mov     a, r3
fill_in1buf_byte: ; fill in endpoint bufer with the value in r3
    movx    @dptr, a
    inc     dptr
    djnz    r7, fill_in1buf_byte

    mov     dptr, #_in1bc ; send the in1buf
    mov     a, #0x40
    movx    @dptr, a
.endif

; cmd4: erase cmd
; erases the given flash page
; sends a zero response packet to the host
cmd4:
    cjne    r6, #CMD_ERASE_PAGE, cmd5
    acall   _flash_erase_page
    setb    BIT_SEND_ZERO

; cmd5: disable flash read back
; sends a zero response packet to the host
cmd5:
.if RDIS_ENABLE
    cjne    r6, #CMD_READ_DISABLE, cmd6
    setb    _INFEN
    mov     dptr, #_rdismb
    movx    a, @dptr
    cpl     a   ; a = !_rdismb
    jz      00001$
    ; code here executes if _rdismb != 0xff
    mov     dptr, #_in1buf
    mov     a, #0x01
    movx    @dptr, a
    ; number of bytes to write to ep1in
    mov     dptr, #_in1bc
    mov     a, #0x01
    movx    @dptr, a
    sjmp    00002$
00001$:
    ; code here executes if _rdismb == 0xff
    acall   _flash_wen
    clr     a
    movx    @dptr, a
    jb      _RDYN, .; wait operation to finish while running from xram
    clr     _WEN
    setb    BIT_SEND_ZERO
00002$:
    clr     _INFEN
.endif

; cmd6: select whether to program upper or lower region on 32kb flash chips
; send zero response
cmd6:
    cjne    r6, #CMD_SELECT_FLASH, no_command_match
    clr     BIT_FLASH_HALF_SELECT
    mov     a, r7
    jnz     00001$
    setb    BIT_FLASH_HALF_SELECT
00001$:
    setb    BIT_SEND_ZERO
; didn't match any of the commands above, or fell through to this branch
no_command_match:
usb_handling_final:

; some commands above send a packet with one 0 in them to the host after completing
_send_usb_zero:
    jnb     BIT_SEND_ZERO, 00002$
    mov     dptr, #_in1buf
    clr     a
    movx    @dptr, a
    ; number of bytes to write to ep1in
    mov     dptr, #_in1bc
    mov     a, #0x01
    movx    @dptr, a
    clr     BIT_SEND_ZERO
00002$:

; clear interrupt flags
_clear_flags:
    mov     a, #0xff
    ; mov     a, #0x3f  ; ; datasheet says to use this value
    mov     dptr, #_in_irq  ; _in_irq
    movx    @dptr, a
    inc     dptr            ; _out_irq
    movx    @dptr, a
    inc     dptr            ; _usbirq
    ; mov     a, #0x1f  ; ; datasheet says to use this value
    movx    @dptr, a
    ; mov     a, #0xff
    mov     dptr, #_out1bc
    movx    @dptr, a

    acall   _finish_usb_ep0_transaction

; goto start of loop
    ajmp    _start_loop


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                              functions                              ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


; nrf24lu1 has extended 8051 instruction set with two dptr registers, this
; function copies memory between `dptr0` to `dptr1`.
;
; Register input contents:
; dptr0: source
; dptr1: dest
; r7: number of bytes to copy. If r7==0, then copies 256 bytes
; _DPS: _DPS == 1
;
; Register output contents:
; dptr0: dptr0 = dptr0 + numBytes
; dptr1: dptr1 = dptr1 + numBytes
; r7: r7 == 0
_copy_between_dptr:
00001$:
    dec     _DPS
    movx    a, @dptr
    inc     dptr

    inc     _DPS
    movx    @dptr, a
    inc     dptr

    jb      _RDYN, . ; wait operation to finish while running from xram
    djnz    r7, 00001$
    ret

; Finishes a usb transaction. If r0==0, then USB ack stall. If r0 != 0,
; then return
; Register input contents:
; r0: num of bytes to transfer on usb endpoint in
; dptr1: data to send on USB
_finish_usb_ep0_transaction:
    inc     r0
    djnz    r0, 00001$          ; if r0 == 0, then USB HAND Shake acknowledge
        mov     dptr, #_ep0cs
        mov     a, #0x02
        movx    @dptr, a
        ret
00001$:                         ; else r0 == number of bytes to send on ep0
    inc     _DPS
    mov     dptr, #_in0buf
    mov     ar7, r0
    acall   _copy_between_dptr
    mov     dptr, #_in0bc
    mov     a, r0
    movx    @dptr, a
    mov     r0, #0x00
    ret

; Enable erase and write operations on flash
; Use clr _WEN to disable them again.
; Register args: none
_flash_wen:
    mov _FCR, #0xAA
    mov _FCR, #0x55
    setb _WEN
    ret

; erase the flash in the given page.
; Register args: r7
; r7: the page to erase.  r7 < 64
_flash_erase_page:
    acall   _flash_wen
    mov       _FCR, r7  ; erase this page
    jb _RDYN, . ; wait operation to finish while running from xram

    clr _WEN
    ret

.if KICK_WATCHDOG
_kick_dog:
    mov     _REGXH, #0x0f
    mov     _REGXL, #0xff
    mov     _REGXC, #_WWD
    ret
.endif


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                data                                 ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

; The descriptors for the USB device
; device descriptor
_usb_dev_desc:
    .db     #0x12             ; 18      ; bLength
    .db     #0x01             ; 1       ; bDescriptorType
    .byte   #0x10,#0x01       ; 0x0110  ; bcdUSB
    .db     #0x00             ; 0       ; bDeviceClass
    .db     #0x00             ; 0       ; bDeviceSubClass
    .db     #0x00             ; 0       ; bDeviceProtocol
    .db     #0x40             ; 64      ; bMaxPacketSize
    .byte   #USB_VID_LO,#USB_VID_HI     ; idVendor
    .byte   #USB_PID_LO,#USB_PID_HI     ; idProduct
    .byte   #0x01,#0x00       ; 1       ; bcdDevice
    .db     #0x00             ; 0       ; iManufacturer
    .db     #0x00             ; 0       ; iProduct
    .db     #0x00             ; 0       ; iSerialNumber
    .db     #0x01             ; 1       ; bNumConfigurations
_usb_conf_desc:
    ; configuration descriptor
    .db     #0x09             ; 9       ; bLength
    .db     #0x02             ; 2       ; bDescriptorType
    .byte   #0x20,#0x00       ; 32      ; wTotalLength
    .db     #0x01             ; 1       ; bNumInterfaces
    .db     #0x01             ; 1       ; bConfigurationValue
    .db     #0x00             ; 0       ; iConfiguration
    .db     #0x80             ; 128     ; bmAttributes
    .db     #0x19             ; 25      ; bMaxPower
    ; interface descriptor
    .db     #0x09             ; 9       ; bLength
    .db     #0x04             ; 4       ; bDescriptorType
    .db     #0x00             ; 0       ; bInterfaceNumber
    .db     #0x00             ; 0       ; bAlternateSetting
    .db     #0x02             ; 2       ; bNumEndpoints
    .db     #0x00             ; 0       ; bInterfaceClass
    .db     #0x00             ; 0       ; bInterfaceSubClass
    .db     #0x00             ; 0       ; bInterfaceProtocol
    .db     #0x00             ; 0       ; iInterface
    ; ep1in descriptor
    .db     #0x07             ; 7       ; bLength
    .db     #0x05             ; 5       ; bDescriptorType
    .db     #0x81             ; 129     ; bEndpointAddress
    .db     #0x03             ; 3       ; bmAttributes
    .byte   #0x40,#0x00       ; 64      ; wMaxPacketSize
    .db     #_EP1_INTERVAL    ;         ; bInterval
    ; ep0in descriptor
    .db     #0x07             ; 7       ; bLength
    .db     #0x05             ; 5       ; bDescriptorType
    .db     #0x01             ; 1       ; bEndpointAddress
    .db     #0x03             ; 3       ; bmAttributes
    .byte   #0x40,#0x00       ; 64      ; wMaxPacketSize
    .db     #_EP1_INTERVAL    ;         ; bInterval
_program_end:

; .org 0x7800
; ; .db "hello world"
; .ascii "hello world"
