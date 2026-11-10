; ---------------------------------------------------------------------------
; Parallax scrolling demo for the Amiga 1200 (AGA)
;
; Pure 68k assembly rewrite of the C demo.  The hardware does the scrolling:
;
;   * AGA dual playfield: PF1 (foreground) and PF2 (midground), 4 bitplanes
;     each, independent bitplane pointers and BPLCON1 quarter-pixel delays.
;   * Each playfield is a "sliding" bitmap: rows are packed with no modulo,
;     so advancing the display pointer by one word needs exactly one new
;     word per row.  The blitter streams the next 16-pixel column from the
;     mirror-tiled layer strip during vertical blank.
;   * Copper: per-line COLOR00 sky gradient, palettes, sprite pointers and
;     the per-frame playfield patches.  Two copper lists are double buffered.
;   * Sun: three hardware sprites behind both playfields.
;
; Per frame the CPU only advances two quarter-pixel positions, patches 17
; copper words and (every 16/32 frames) starts four tiny blits.  Everything
; else runs on the custom chips.
;
; What was removed with respect to the C version:
;   * no Intuition screen/window, no DOS, no font/Text(), no runtime file
;     loading: only graphics.library is opened (WaitTOF / LoadView / blitter
;     ownership), all assets are incbin'd in the executable.
;   * no stats/rebase test hooks, no dynamic allocations beyond one chip block.
;
; Quit: left/right mouse button or CTRL-C (the shell's break signal).
; ---------------------------------------------------------------------------

        include "assets.i"              ; generated layer/sprites/text constants

; ---------------------------------------------------------------- custom
CUSTOM          equ     $DFF000         ; base of the custom chip registers
DMACONR         equ     $002            ; DMA control (read): bit 14 = blitter busy
BLTCON0         equ     $040            ; blitter control 0: minterm + shifts
BLTCON1         equ     $042            ; blitter control 1: mode / direction
BLTAFWM         equ     $044            ; blitter first-word mask
BLTALWM         equ     $046            ; blitter last-word mask
BLTAPT          equ     $050            ; blitter source A pointer
BLTDPT          equ     $054            ; blitter destination pointer
BLTSIZE         equ     $058            ; blitter size: height<<6 | width
BLTAMOD         equ     $064            ; blitter A modulo
BLTDMOD         equ     $066            ; blitter D modulo
DENISEID        equ     $07C            ; Denise revision: $F8 = AGA (Lisa)
COP1LC          equ     $080            ; copper list 1 location
COPJMP1         equ     $088            ; strobe: restart copper at COP1LC
DIWSTRT         equ     $08E            ; display window start (V,H)
DIWSTOP         equ     $090            ; display window stop (V,H)
DDFSTRT         equ     $092            ; data fetch start (horizontal)
DDFSTOP         equ     $094            ; data fetch stop (horizontal)
DMACON          equ     $096            ; DMA control (write: set/clear)
BPL1PTH         equ     $0E0            ; bitplane 1 pointer, high word
BPLCON0         equ     $100            ; bitplane control 0: depth/dual PF
BPLCON1         equ     $102            ; bitplane control 1: scroll delays
BPLCON2         equ     $104            ; bitplane control 2: priority
BPLCON3         equ     $106            ; bitplane control 3: AGA bank/border
BPL1MOD         equ     $108            ; bitplane modulo, odd planes
BPL2MOD         equ     $10A            ; bitplane modulo, even planes
BPLCON4         equ     $10C            ; bitplane control 4: palette bank/XOR
SPR0PTH         equ     $120            ; sprite 0 pointer, high word
COLOR00         equ     $180            ; colour 0 register (32 entries follow)
FMODE           equ     $1FC            ; AGA fetch mode
POTINP          equ     $016            ; pot/port input: right button bit 10
CIAA_PRA        equ     $BFE001         ; CIA-A port A: left button bit 6

; ---------------------------------------------------------------- exec/gfx
_LVOAllocMem       equ  -198            ; exec.library AllocMem
_LVOFreeMem        equ  -210            ; exec.library FreeMem
_LVOOpenLibrary    equ  -552            ; exec.library OpenLibrary
_LVOCloseLibrary   equ  -414            ; exec.library CloseLibrary
_LVOSetSignal      equ  -306            ; exec.library SetSignal
_LVOFindTask       equ  -294            ; exec.library FindTask
_LVOSetTaskPri     equ  -300            ; exec.library SetTaskPri
_LVOWaitTOF        equ  -270            ; graphics.library WaitTOF
_LVOLoadView       equ  -222            ; graphics.library LoadView
_LVOOwnBlitter     equ  -456            ; graphics.library OwnBlitter
_LVODisownBlitter  equ  -462            ; graphics.library DisownBlitter

GFXB_ACTIVIEW      equ  34              ; GfxBase->ActiView (current view)
GFXB_COPINIT       equ  38              ; GfxBase->copinit (OS copper list)

SIGBREAKF_CTRL_C   equ  $1000           ; exec signal bit for CTRL-C
MEMF_CHIP          equ  2               ; allocate in chip RAM
MEMF_CLEAR         equ  $10000          ; zero the allocation
DMA_FULL           equ  $83E0           ; SET + DMAEN/BPLEN/COPEN/BLTEN/SPREN
DMA_MASK           equ  $03E0           ; DMA bits we may have to restore

; ---------------------------------------------------------------- layout
DEPTH           equ     4               ; bitplanes per playfield
ROWB            equ     42              ; 21 fetched words per display row
GUARD           equ     64              ; blank headroom before every plane
EXTRA           equ     4096            ; scroll headroom per plane (bytes)
WMAX            equ     (EXTRA/2)-32    ; word offset where we rebase
PERIOD_Q        equ     PERIOD_WORDS*64 ; layer period in quarter pixels
TEXT_ROWS       equ     TITLE_H+2       ; text rows plus two blank rows
TEXT_PLANE      equ     TEXT_ROWS*ROWB  ; bytes per text bitplane
TEXT_SIZE       equ     DEPTH*TEXT_PLANE ; four text bitplanes

STRIP_MID_SIZE  equ     DEPTH*MID_H*STRIP_BYTES ; mid strip image size
STRIP_FG_SIZE   equ     DEPTH*FG_H*STRIP_BYTES  ; foreground strip image size
MID_MEM         equ     GUARD+(MID_H+1)*ROWB+EXTRA ; mid buffer incl. extra row
MID_SIZE        equ     (MID_MEM+7)&~7  ; mid plane stride, longword aligned
FG_MEM          equ     GUARD+(FG_H+1)*ROWB+EXTRA  ; fg buffer incl. extra row
FG_SIZE         equ     (FG_MEM+7)&~7   ; fg plane stride, longword aligned
SPR_SIZE        equ     584             ; 8 sprite structs of 73 bytes
COP_LIST        equ     2048            ; bytes per copper list (1024 words)

CHIP_SMID       equ     0               ; mid strip image in chip RAM
CHIP_SFG        equ     CHIP_SMID+STRIP_MID_SIZE ; fg strip image
CHIP_MID        equ     CHIP_SFG+STRIP_FG_SIZE   ; four mid plane buffers
CHIP_FG         equ     CHIP_MID+4*MID_SIZE      ; four fg plane buffers
CHIP_TEXT       equ     CHIP_FG+4*FG_SIZE        ; four text bitplanes
CHIP_SPR        equ     CHIP_TEXT+TEXT_SIZE      ; sprite images
CHIP_COP        equ     CHIP_SPR+SPR_SIZE        ; two copper lists
CHIP_SIZE       equ     CHIP_COP+2*COP_LIST      ; total chip allocation

DISP_VTOP       equ     $3A             ; display window begins at line 58
SCENE_TOP       equ     DISP_VTOP+TITLE_H ; first scrolled scene line
BPLCON0_VAL     equ     $0611           ; 8 planes, dual playfield, ECSENA
BPLCON3_VAL     equ     $1020           ; PF2 colours at 16, border blank
BPLCON3_BK1     equ     $3020           ; bank 1 (sprite colours 32-39)

; ---------------------------------------------------------------- Layer
L_STRIP         equ     0               ; planar strip in chip RAM
L_BASE          equ     4               ; plane 0 buffer base (mem+GUARD)
L_POS           equ     8               ; quarter pixels
L_FILLED        equ     12              ; last streamed column
L_H             equ     16              ; layer height in rows
L_SPEED         equ     18              ; quarter pixels per frame
L_PSTRIDE       equ     20              ; plane stride in the buffer
L_SSTRIDE       equ     24              ; plane stride in the strip

; ---------------------------------------------------------------- macros
        macro   COPMOVE                 ; emit "move.w #value,reg" copper pair
        move.w  #\1,(a3)+               ; register number
        move.w  #\2,(a3)+               ; value
        endm                            ; end of macro

; reg in d5, address in a0 -> one "move.w reg/reg+2" pointer pair.
; Advances d5 by 8 and a0 by the given stride.
        macro   COPPTR                  ; emit a two-word pointer pair
        move.w  d5,(a3)+                ; high-word register number
        addq.w  #2,d5                   ; -> low-word register number
        move.l  \1,d1                   ; address to split
        swap    d1                      ; high word in low half
        move.w  d1,(a3)+                ; pointer high word
        move.w  d5,(a3)+                ; low-word register number
        addq.w  #6,d5                   ; skip to the next pair's high reg
        swap    d1                      ; low word back in low half
        move.w  d1,(a3)+                ; pointer low word
        add.l   #\2,\1                  ; advance to the next plane
        endm                            ; end of macro

; Same, but with zero value words (patched later).  Advances d5 by 8.
        macro   COPSLOT                  ; emit a placeholder pointer pair
        move.w  d5,(a3)+                ; high-word register number
        addq.w  #2,d5                   ; -> low-word register number
        move.w  #0,(a3)+                ; placeholder high word
        move.w  d5,(a3)+                ; low-word register number
        addq.w  #6,d5                   ; skip to the next pair's high reg
        move.w  #0,(a3)+                ; placeholder low word
        endm                            ; end of macro

; ===========================================================================
        section code,code              ; executable code section
; ---------------------------------------------------------------------------

start:                                  ; program entry point
        move.l  4.w,a6                  ; a6 = ExecBase
        move.l  a6,sysbase              ; keep it for later library calls

        lea     gfxname,a1              ; "graphics.library"
        moveq   #39,d0                  ; need version 39 (V39+)
        jsr     _LVOOpenLibrary(a6)     ; open graphics.library
        tst.l   d0                      ; did it open?
        beq     fail_exit               ; no -> exit with code 20
        move.l  d0,gfxbase              ; save GfxBase
        move.l  d0,a6                   ; a6 = GfxBase for graphics LVOs

        move.w  CUSTOM+DENISEID,d0      ; read Denise revision
        and.w   #$FF,d0                 ; keep the low byte only
        cmp.w   #$F8,d0                 ; $F8 = Lisa, i.e. AGA chipset
        bne     fail_close              ; not AGA -> close and exit

        move.l  sysbase,a6              ; a6 = ExecBase again
        move.l  #CHIP_SIZE,d0           ; size of the single chip block
        move.l  #MEMF_CHIP+MEMF_CLEAR,d1 ; chip RAM, cleared
        jsr     _LVOAllocMem(a6)        ; allocate it
        tst.l   d0                      ; allocation successful?
        beq     fail_close              ; no -> close and exit
        move.l  d0,chipblock            ; save the block base

        move.l  sysbase,a6              ; run above background tasks so the
        sub.l   a1,a1                   ; per-frame work is never preempted
        jsr     _LVOFindTask(a6)        ; a1/a0 = our own Task
        move.l  d0,a1                   ; argument for SetTaskPri
        moveq   #5,d0                   ; priority 5
        jsr     _LVOSetTaskPri(a6)      ; raise our priority

        move.w  CUSTOM+DMACONR,d0      ; remember what the OS had enabled
        not.w   d0                      ; store the inverse: bits to clear
        and.w   #DMA_MASK,d0            ; only the DMA bits we care about
        move.w  d0,dma_clear            ; keep the restore value
        move.w  #DMA_FULL,CUSTOM+DMACON ; enable DMA and all channels

; ---- copy the incbin'd assets into chip RAM ------------------------------
        move.l  chipblock,d7            ; d7 = chip block base (kept below)

        lea     asset_layers,a0         ; source: midground strip image
        move.l  d7,a1                   ; destination: chip RAM
        add.l   #CHIP_SMID,a1           ; at the mid strip offset
        move.l  #STRIP_MID_SIZE/4-1,d0  ; longword count minus one
        bsr     copy_longs              ; copy it

        lea     asset_layers+STRIP_MID_SIZE,a0 ; source: foreground strip
        move.l  d7,a1                   ; destination: chip RAM
        add.l   #CHIP_SFG,a1            ; at the fg strip offset
        move.l  #STRIP_FG_SIZE/4-1,d0   ; longword count minus one
        bsr     copy_longs              ; copy it

        lea     asset_sprites,a0        ; source: sprite images
        move.l  d7,a1                   ; destination: chip RAM
        add.l   #CHIP_SPR,a1            ; at the sprite offset
        move.l  #SPR_SIZE/4-1,d0        ; longword count minus one
        bsr     copy_longs              ; copy it

        lea     asset_text,a0           ; source: title text bitplanes
        move.l  d7,a1                   ; destination: chip RAM
        add.l   #CHIP_TEXT,a1           ; at the text offset
        move.l  #TEXT_SIZE/4-1,d0       ; longword count minus one
        bsr     copy_longs              ; copy it

; ---- point the layer descriptors at the chip block -----------------------
        lea     mid_layer,a1            ; a1 = midground Layer struct
        move.l  d7,d0                   ; chip block base
        add.l   #CHIP_SMID,d0           ; -> mid strip image
        move.l  d0,L_STRIP(a1)          ; L_STRIP = strip address
        move.l  d7,d0                   ; chip block base
        add.l   #CHIP_MID+GUARD,d0      ; -> mid plane 0 after the guard
        move.l  d0,L_BASE(a1)           ; L_BASE = plane 0 base
        move.l  d0,mid_base             ; keep the base for copper patching
        move.l  d7,d0                   ; chip block base
        add.l   #CHIP_FG+GUARD,d0       ; -> fg plane 0 after the guard
        move.l  d0,fg_base              ; keep the base for copper patching
        move.l  d7,d0                   ; chip block base
        add.l   #CHIP_TEXT,d0           ; -> title text bitplanes
        move.l  d0,text_base            ; keep the text base
        move.l  d7,d0                   ; chip block base
        add.l   #CHIP_SPR,d0            ; -> sprite images
        move.l  d0,spr_base             ; keep the sprite base

        lea     fg_layer,a1             ; a1 = foreground Layer struct
        move.l  d7,d0                   ; chip block base
        add.l   #CHIP_SFG,d0            ; -> fg strip image
        move.l  d0,L_STRIP(a1)          ; L_STRIP = strip address
        move.l  fg_base,d0              ; plane 0 base computed above
        move.l  d0,L_BASE(a1)           ; L_BASE = plane 0 base

; ---- build the two copper lists -----------------------------------------
        move.l  chipblock,d0            ; chip block base
        add.l   #CHIP_COP,d0            ; -> first copper list
        move.l  d0,list0                ; list0 = first list
        add.l   #COP_LIST,d0            ; second list follows immediately
        move.l  d0,list1                ; list1 = second list
        lea     list_ptrs,a0            ; double-buffer pointer table
        move.l  list0,(a0)              ; table[0] = list0
        move.l  list1,4(a0)             ; table[1] = list1

        move.l  list0,a3                ; a3 = list0 write pointer
        moveq   #0,d0                   ; patch-table index 0
        movea.l d0,a4                   ; a4 = byte offset 0
        bsr     build_list              ; build list0
        move.l  list1,a3                ; a3 = list1 write pointer
        moveq   #4,d0                   ; patch-table index 1
        movea.l d0,a4                   ; a4 = byte offset 4
        bsr     build_list              ; build list1

; ---- first frame: stream the initial columns, patch both lists ----------
        lea     mid_layer,a2            ; a2 = midground layer
        bsr     layer_frame             ; stream its first columns
        move.l  d0,wm                   ; wm = first fetched word
        move.w  d1,dm                   ; dm = mid scroll delay
        lea     fg_layer,a2             ; a2 = foreground layer
        bsr     layer_frame             ; stream its first columns
        move.l  d0,wf                   ; wf = first fetched word
        move.w  d1,df                   ; df = fg scroll delay
        bsr     make_con1               ; combine delays into BPLCON1

        moveq   #0,d0                   ; patch-table index 0
        movea.l d0,a4                   ; a4 = byte offset 0
        bsr     patch_list              ; patch list0
        moveq   #4,d0                   ; patch-table index 1
        movea.l d0,a4                   ; a4 = byte offset 4
        bsr     patch_list              ; patch list1

; ---- take the display over ----------------------------------------------
        move.l  gfxbase,a6              ; a6 = GfxBase
        move.l  GFXB_ACTIVIEW(a6),d0    ; current OS view
        move.l  d0,oldview              ; remember it for exit
        moveq   #0,d0                   ; LoadView(NULL)
        movea.l d0,a1                   ; a1 = NULL view
        jsr     _LVOLoadView(a6)        ; detach the OS display
        jsr     _LVOWaitTOF(a6)         ; wait for the display to settle
        jsr     _LVOWaitTOF(a6)         ; (two full frames)

        move.w  #DMA_FULL,CUSTOM+DMACON ; make sure our DMA is enabled
        move.l  list0,CUSTOM+COP1LC     ; point the copper at list0
        move.w  #0,CUSTOM+COPJMP1       ; restart the copper immediately
        move.w  #0,cur                  ; cur = list0 is displayed

; ===========================================================================
; main loop: one iteration per PAL frame (50 Hz)
; ===========================================================================
main_loop:                              ; one iteration per frame
        move.l  gfxbase,a6              ; a6 = GfxBase
        jsr     _LVOWaitTOF(a6)         ; sync with the vertical blank

        btst    #6,CIAA_PRA             ; left mouse button (active low)
        beq     exit                    ; pressed -> quit
        btst    #10,CUSTOM+POTINP       ; right mouse button
        beq     exit                    ; pressed -> quit

        move.l  a6,-(sp)                ; CTRL-C from shell / bridge
        move.l  sysbase,a6              ; a6 = ExecBase for SetSignal
        moveq   #0,d0                   ; SetSignal(0,0)...
        moveq   #0,d1                   ; ...reads and clears pending signals
        jsr     _LVOSetSignal(a6)       ; d0 = signals that were pending
        move.l  (sp)+,a6                ; restore GfxBase
        and.l   #SIGBREAKF_CTRL_C,d0    ; CTRL-C bit set?
        bne     exit                    ; yes -> quit

        lea     mid_layer,a2            ; a2 = midground layer
        bsr     layer_frame             ; advance and refill midground
        move.l  d0,wm                   ; wm = first fetched word
        move.w  d1,dm                   ; dm = mid scroll delay
        lea     fg_layer,a2             ; a2 = foreground layer
        bsr     layer_frame             ; advance and refill foreground
        move.l  d0,wf                   ; wf = first fetched word
        move.w  d1,df                   ; df = fg scroll delay
        bsr     make_con1               ; update the BPLCON1 word

        moveq   #0,d0                   ; patch the idle list
        move.w  cur,d0                  ; d0 = list currently displayed
        eor.w   #1,d0                   ; -> the other (idle) list
        move.w  d0,next                 ; remember which one we patch
        lsl.w   #2,d0                   ; index * 4 = table byte offset
        movea.l d0,a4                   ; a4 = patch-table byte offset
        bsr     patch_list              ; patch the idle list

        lea     list_ptrs,a0            ; double-buffer pointer table
        move.l  (a0,a4.w),a3            ; a3 = address of the idle list
        move.l  a3,CUSTOM+COP1LC       ; the copper restarts here at vblank
        move.w  next,cur                ; remember the displayed list
        bra     main_loop               ; next frame

; ===========================================================================
; exit: put the OS display back and release everything
; ===========================================================================
exit:                                   ; normal teardown path
        bsr     waitblit                ; let any running blit finish
        move.l  gfxbase,a6              ; a6 = GfxBase
        move.l  GFXB_COPINIT(a6),CUSTOM+COP1LC ; OS copper list back
        move.w  #0,CUSTOM+COPJMP1       ; restart the copper on it
        move.l  oldview,a1              ; saved OS view
        jsr     _LVOLoadView(a6)        ; restore it
        jsr     _LVOWaitTOF(a6)         ; let the display settle
        jsr     _LVOWaitTOF(a6)         ; (two full frames)

        move.w  dma_clear,d0            ; clear only the bits we enabled
        move.w  d0,CUSTOM+DMACON        ; restore the OS DMA state

        move.l  sysbase,a6              ; a6 = ExecBase
        move.l  chipblock,a1            ; chip block base
        move.l  #CHIP_SIZE,d0           ; its size
        jsr     _LVOFreeMem(a6)         ; free it
        move.l  gfxbase,a1              ; graphics.library base
        jsr     _LVOCloseLibrary(a6)    ; close it
        moveq   #0,d0                   ; return code 0
        rts                             ; back to the shell

fail_close:                             ; failure after OpenLibrary
        move.l  sysbase,a6              ; a6 = ExecBase
        move.l  gfxbase,a1              ; graphics.library base
        jsr     _LVOCloseLibrary(a6)    ; close what we opened
fail_exit:                              ; failure before anything opened
        moveq   #20,d0                  ; return code 20 (failure)
        rts                             ; back to the shell

; ===========================================================================
; copy_longs: a0=src, a1=dst, d0=longwords-1
; ===========================================================================
copy_longs:                             ; fast longword copy
        move.l  (a0)+,(a1)+             ; copy one longword, advance both
        dbra    d0,copy_longs           ; repeat for the whole block
        rts                             ; done

; ===========================================================================
; waitblit: wait until the blitter is idle
; ===========================================================================
waitblit:                               ; poll until the blitter is idle
        btst    #14,CUSTOM+DMACONR      ; blitter busy flag
        bne     waitblit                ; still busy -> keep polling
        rts                             ; blitter is free

; ===========================================================================
; layer_frame: a2 = Layer, returns d0 = first fetched word, d1 = delay
; advances the position, rebases when the headroom is exhausted and blits
; the missing columns.
; ===========================================================================
layer_frame:                            ; advance one layer by one frame
        move.l  L_POS(a2),d0            ; d0 = position in quarter pixels
        moveq   #0,d2                   ; clear...
        move.w  L_SPEED(a2),d2          ; ...d2 = speed in quarter pixels
        add.l   d2,d0                   ; advance the position
        move.l  d0,L_POS(a2)            ; store the new position

        move.l  d0,d3                   ; d3 = position
        add.l   #63,d3                  ; round up to the next word
        lsr.l   #6,d3                   ; w = ceil(pos / 64)
        cmp.l   #WMAX,d3                ; beyond the comfortable headroom?
        ble.s   .no_rebase              ; no -> keep this buffer
        move.l  d0,d4                   ; d4 = position
        divu.w  #PERIOD_Q,d4            ; quotient | remainder
        clr.w   d4                      ; drop the quotient
        swap    d4                      ; remainder = pos % PERIOD_Q
        move.l  d4,L_POS(a2)            ; wrap keeping the same phase
        move.l  d4,d0                   ; d0 = wrapped position
        move.l  d0,d3                   ; recompute the word index
        add.l   #63,d3                  ; round up to the next word
        lsr.l   #6,d3                   ; w = ceil(pos / 64)
        move.l  d3,d4                   ; mark everything below w...
        subq.l  #1,d4                   ; ...as already filled
        move.l  d4,L_FILLED(a2)         ; rebuild the window from w
.no_rebase:                             ; no buffer rebase needed
        move.l  d3,d4                   ; d4 = w
        subq.l  #1,d4                   ; w - 1
        cmp.l   L_FILLED(a2),d4         ; do we already have w-1?
        ble.s   .check                  ; yes -> nothing to correct
        move.l  d4,L_FILLED(a2)         ; keep the last streamed column >= w-1
.check:                                 ; check whether columns are missing
        move.l  d3,d4                   ; d4 = w
        add.l   #20,d4                  ; need columns w .. w+20
        cmp.l   L_FILLED(a2),d4         ; are they all present?
        ble.s   .done                   ; yes -> no blits needed
        move.l  gfxbase,a6              ; a6 = GfxBase
        jsr     _LVOOwnBlitter(a6)      ; take the blitter for ourselves
.fill:                                  ; stream every missing column
        addq.l  #1,L_FILLED(a2)         ; next column to stream
        move.l  L_FILLED(a2),d6         ; d6 = column index
        bsr     fill_column             ; stream that column
        cmp.l   L_FILLED(a2),d4         ; still behind the target?
        bgt.s   .fill                   ; yes -> keep filling
        bsr     waitblit                ; blits are asynchronous, drain them
        move.l  gfxbase,a6              ; a6 = GfxBase
        jsr     _LVODisownBlitter(a6)   ; give the blitter back
.done:                                  ; return word index and delay
        move.l  L_POS(a2),d1            ; d1 = position
        neg.l   d1                      ; delay = -position...
        and.l   #63,d1                  ; ...mod 64 quarter pixels
        move.l  d3,d0                   ; d0 = first fetched word
        rts                             ; return w and the delay

; ===========================================================================
; fill_column: a2 = Layer, d6 = column index
; streams one 16-pixel column into every row of all four bitplanes.
; ===========================================================================
fill_column:                            ; stream one 16-pixel column
        move.l  d6,d0                   ; d0 = destination column
        add.l   #39,d0                  ; source is one column behind
        divu.w  #40,d0                  ; quotient | remainder
        clr.w   d0                      ; drop the quotient
        swap    d0                      ; source column (c+39)%40
        add.w   d0,d0                   ; word -> byte offset in the row
        move.w  d0,d1                   ; d1 = strip row byte offset
        move.l  d6,d2                   ; d2 = destination column
        add.l   d2,d2                   ; word -> byte offset in the buffer

        move.w  L_H(a2),d7              ; d7 = layer height
        lsl.w   #6,d7                   ; height into the BLTSIZE high bits
        ori.w   #1,d7                   ; BLTSIZE = h<<6 | 1 (one word wide)

        move.l  L_STRIP(a2),a0          ; a0 = strip plane 0
        move.l  L_BASE(a2),a1           ; a1 = buffer plane 0
        moveq   #3,d5                   ; loop count: 4 planes
.plane:                                 ; one blit for this bitplane
        bsr     waitblit                ; previous blit must have finished
        move.w  #$09F0,CUSTOM+BLTCON0   ; minterm $F0: D = A
        clr.w   CUSTOM+BLTCON1          ; ascending, no fill/line mode
        move.w  #$FFFF,CUSTOM+BLTAFWM   ; no first-word mask
        move.w  #$FFFF,CUSTOM+BLTALWM   ; no last-word mask
        move.w  #STRIP_BYTES-2,CUSTOM+BLTAMOD ; A steps to the next strip row
        move.w  #ROWB-2,CUSTOM+BLTDMOD  ; D steps to the next buffer row

        move.l  a0,a3                   ; a3 = strip plane base
        adda.w  d1,a3                   ; + column byte offset
        move.l  a3,CUSTOM+BLTAPT        ; A source = strip column
        move.l  a1,a3                   ; a3 = buffer plane base
        add.l   d2,a3                   ; + column byte offset
        move.l  a3,CUSTOM+BLTDPT        ; D destination = buffer column
        move.w  d7,CUSTOM+BLTSIZE       ; start the blit

        add.l   L_SSTRIDE(a2),a0        ; advance to the next strip plane
        add.l   L_PSTRIDE(a2),a1        ; advance to the next buffer plane
        dbra    d5,.plane               ; repeat for all four planes
        rts                             ; column complete

; ===========================================================================
; make_con1: dm/df variables -> con1 word (also in d0)
;   bits 0-3 PF1 coarse, 4-7 PF2 coarse, 8-9 PF1 fine, 12-13 PF2 fine
; ===========================================================================
make_con1:                              ; build the BPLCON1 word
        move.w  dm,d6                   ; d6 = midground delay
        move.w  df,d5                   ; d5 = foreground delay
        move.w  d6,d0                   ; d0 = midground delay
        lsr.w   #2,d0                   ; coarse = delay / 4
        move.w  d5,d1                   ; d1 = foreground delay
        lsr.w   #2,d1                   ; coarse = delay / 4
        lsl.w   #4,d0                   ; PF2 coarse -> bits 4-7
        or.w    d1,d0                   ; PF1 coarse -> bits 0-3
        move.w  d6,d1                   ; d1 = midground delay
        and.w   #3,d1                   ; fine = delay & 3
        lsl.w   #4,d1                   ; fine into bits 4-5...
        lsl.w   #8,d1                   ; ...then bits 12-13
        or.w    d1,d0                   ; PF2 fine -> bits 12-13
        move.w  d5,d1                   ; d1 = foreground delay
        and.w   #3,d1                   ; fine = delay & 3
        lsl.w   #8,d1                   ; fine into bits 8-9
        or.w    d1,d0                   ; PF1 fine -> bits 8-9
        move.w  d0,con1                 ; keep the value for patching
        rts                             ; return it in d0 as well

; ===========================================================================
; build_list: a3 = destination, a4 = patch-table byte index (0 or 4)
; ===========================================================================
build_list:                             ; emit a complete copper list
        COPMOVE BPLCON0,BPLCON0_VAL     ; 8 planes, dual playfield, ECSENA
        COPMOVE BPLCON2,$0000           ; no playfield priority overrides
        COPMOVE BPLCON3,BPLCON3_VAL     ; PF2 colours at 16, border blank
        COPMOVE BPLCON4,$0022           ; no palette bank or bitplane XOR
        COPMOVE FMODE,$0000             ; slowest/safest AGA fetch mode
        COPMOVE DIWSTRT,(DISP_VTOP<<8)|$81 ; display window start
        COPMOVE DIWSTOP,(((SCENE_TOP+SCENE_H)&$FF)<<8)|$C1 ; display window stop
        COPMOVE DDFSTRT,$0030           ; data fetch starts at $30
        COPMOVE DDFSTOP,$00D0           ; data fetch stops at $D0
        COPMOVE BPLCON1,$0000          ; title band is not scrolled
        COPMOVE BPL1MOD,$0000          ; text rows are contiguous
        COPMOVE BPL2MOD,-ROWB          ; PF2 repeats a single empty row

; ---- sprite pointers ----------------------------------------------------
        lea     spr_offsets,a5          ; sprite image offsets
        move.w  #SPR0PTH,d5             ; first sprite pointer register
        moveq   #7,d7                   ; eight hardware sprites
.spr:                                   ; emit one sprite pointer pair
        move.w  d5,(a3)+                ; pointer high-word register
        addq.w  #2,d5                   ; -> low-word register
        move.l  (a5)+,d1                ; offset of this sprite image
        add.l   spr_base,d1             ; -> chip RAM address
        move.l  d1,d0                   ; copy for the high word
        swap    d0                      ; high word in low half
        move.w  d0,(a3)+                ; pointer high word
        move.w  d5,(a3)+                ; pointer low-word register
        addq.w  #2,d5                   ; -> next sprite's high register
        move.w  d1,(a3)+                ; pointer low word
        dbra    d7,.spr                 ; repeat for all eight sprites

; ---- palettes -----------------------------------------------------------
        COPMOVE COLOR00,$0000           ; background starts black
        lea     palette+2,a0            ; skip palette entry 0
        move.w  #COLOR00+2,d5           ; first PF1 colour register
        moveq   #14,d7                  ; colours 1..15
.pf1col:                                ; copy one PF1 colour
        move.w  d5,(a3)+                ; colour register
        move.w  (a0)+,(a3)+             ; colour value
        addq.w  #2,d5                   ; next register
        dbra    d7,.pf1col              ; loop over PF1 colours

        lea     palette+34,a0           ; PF2 colours start at entry 17
        move.w  #COLOR00+34,d5          ; PF2 colours 17..31
        moveq   #14,d7                  ; 15 colours
.pf2col:                                ; copy one PF2 colour
        move.w  d5,(a3)+                ; colour register
        move.w  (a0)+,(a3)+             ; colour value
        addq.w  #2,d5                   ; next register
        dbra    d7,.pf2col              ; loop over PF2 colours

        COPMOVE BPLCON3,BPLCON3_BK1     ; switch to palette bank 1
        move.w  #COLOR00+2,(a3)+        ; sprite colour 1
        move.w  palette+66,(a3)+        ; from palette entry 33
        move.w  #COLOR00+10,(a3)+       ; sprite colour 5
        move.w  palette+66,(a3)+        ; same colour
        move.w  #COLOR00+4,(a3)+        ; sprite colour 2
        move.w  palette+68,(a3)+        ; from palette entry 34
        move.w  #COLOR00+12,(a3)+       ; sprite colour 6
        move.w  palette+68,(a3)+        ; same colour
        move.w  #COLOR00+6,(a3)+        ; sprite colour 3
        move.w  palette+70,(a3)+        ; from palette entry 35
        move.w  #COLOR00+14,(a3)+       ; sprite colour 7
        move.w  palette+70,(a3)+        ; same colour
        COPMOVE BPLCON3,BPLCON3_VAL     ; back to palette bank 0

; ---- title band: PF1 = text bitmap, PF2 = one empty row -----------------
        move.l  text_base,a0            ; a0 = text plane 0
        move.w  #BPL1PTH,d5             ; PF1 pointer registers
        moveq   #3,d7                   ; four planes
.text:                                  ; one text-plane pointer pair
        COPPTR  a0,TEXT_PLANE           ; one pointer pair per plane
        dbra    d7,.text                ; loop over the four planes

        move.l  mid_base,a0             ; a0 = mid plane 0
        sub.l   #ROWB,a0                ; one row above = empty guard row
        move.w  #BPL1PTH+4,d5           ; PF2 pointer registers
        moveq   #3,d7                   ; four planes
.midempty:                              ; one empty PF2 pointer pair
        COPPTR  a0,MID_SIZE             ; point PF2 at the empty row
        dbra    d7,.midempty            ; loop over the four planes

; ---- scene scanlines ----------------------------------------------------
        lea     sky,a2                  ; sky gradient table
        move.w  #SCENE_TOP-1,d6         ; copper vpos of the first scene line
        moveq   #0,d7                   ; scene row counter
.scene:                                 ; one scene scanline
        move.w  d6,d0                   ; d0 = video line
        and.w   #$FF,d0                 ; keep the vertical position
        lsl.w   #8,d0                   ; into the WAIT high byte
        or.w    #$DF,d0                 ; horizontal position $DF
        move.w  d0,(a3)+                ; copper WAIT (v,h)
        move.w  #$FFFE,(a3)+            ; ...with mask $FFFE
        move.w  #COLOR00,(a3)+          ; write COLOR00
        move.w  (a2)+,(a3)+             ; next sky colour

        tst.w   d7                      ; first scene line?
        bne.s   .not_y0                 ; no -> skip the one-time setup
; PF1 stops showing the text; show a guaranteed empty row until FG_Y0
        COPMOVE BPL1MOD,-ROWB           ; PF1 steps back one row per line
        move.w  #BPLCON1,(a3)+          ; BPLCON1 register
        lea     patch_con1,a5           ; remember where to patch it
        move.l  a3,(a5,a4.w)            ; store the address for this list
        move.w  #0,(a3)+                ; placeholder value

        move.l  fg_base,a0              ; a0 = fg plane 0
        sub.l   #ROWB,a0                ; one row above = empty guard row
        move.w  #BPL1PTH,d5             ; PF1 pointer registers
        moveq   #3,d2                   ; four planes
.fgabove:                               ; empty PF1 row above the scene
        COPPTR  a0,FG_SIZE              ; point PF1 at the empty row
        dbra    d2,.fgabove             ; loop over the four planes
.not_y0:                                ; past the first scene line
        cmp.w   #MID_Y0,d7              ; midground starts here?
        bne.s   .not_mid                ; no -> skip
        COPMOVE BPL2MOD,0               ; PF2 rows are now contiguous
        lea     patch_pf2,a5            ; remember the PF2 pointer block
        move.l  a3,(a5,a4.w)            ; store the address for this list
        move.l  mid_base,a0             ; a0 = mid plane 0
        move.w  #BPL1PTH+4,d5           ; PF2 pointer registers
        moveq   #3,d2                   ; four planes
.midptr:                                ; midground pointer placeholder
        COPSLOT                         ; zero placeholder, patched per frame
        dbra    d2,.midptr              ; loop over the four planes
.not_mid:                               ; not the midground start line
        cmp.w   #FG_Y0,d7               ; foreground starts here?
        bne.s   .not_fg                 ; no -> skip
        COPMOVE BPL1MOD,0               ; PF1 rows are now contiguous
        lea     patch_pf1,a5            ; remember the PF1 pointer block
        move.l  a3,(a5,a4.w)            ; store the address for this list
        move.l  fg_base,a0              ; a0 = fg plane 0
        move.w  #BPL1PTH,d5             ; PF1 pointer registers
        moveq   #3,d2                   ; four planes
.fgptr:                                 ; foreground pointer placeholder
        COPSLOT                         ; zero placeholder, patched per frame
        dbra    d2,.fgptr               ; loop over the four planes
.not_fg:                                ; not the foreground start line
        addq.w  #1,d6                   ; next video line
        addq.w  #1,d7                   ; next scene row
        cmp.w   #SCENE_H,d7             ; whole scene done?
        blt     .scene                  ; no -> next line

        move.w  #$FFFF,(a3)+            ; copper: wait for the end of frame
        move.w  #$FFFE,(a3)+            ; ...with mask $FFFE
        rts                             ; list complete

; ===========================================================================
; patch_list: a4 = patch-table byte index; uses wm/wf/con1
; ===========================================================================
patch_list:                             ; patch the per-frame copper values
        lea     patch_pf2,a0            ; PF2 pointer-table entry
        move.l  (a0,a4.w),a1            ; -> PF2 pointer block in this list
        move.l  mid_base,a0             ; mid plane 0 base
        move.l  wm,d0                   ; first fetched mid word
        move.l  #MID_SIZE,d1            ; mid plane stride
        bsr     patch_ptr               ; patch the four PF2 pointers

        lea     patch_pf1,a0            ; PF1 pointer-table entry
        move.l  (a0,a4.w),a1            ; -> PF1 pointer block in this list
        move.l  fg_base,a0              ; fg plane 0 base
        move.l  wf,d0                   ; first fetched fg word
        move.l  #FG_SIZE,d1             ; fg plane stride
        bsr     patch_ptr               ; patch the four PF1 pointers

        lea     patch_con1,a0           ; BPLCON1 patch-table entry
        move.l  (a0,a4.w),a1            ; -> BPLCON1 value word in this list
        move.w  con1,(a1)               ; store the combined scroll delays
        rts                             ; list patched

; ===========================================================================
; patch_ptr: a1 = first "move.w reg" of a 4-plane pointer block,
;            a0 = plane 0 address, d0 = word offset, d1 = plane stride
; ===========================================================================
patch_ptr:                              ; patch one four-plane pointer block
        add.l   d0,d0                   ; word offset -> byte offset
        add.l   d0,a0                   ; plane 0 address + offset
        moveq   #3,d2                   ; four planes
.loop:                                  ; one plane pointer
        move.l  a0,d3                   ; d3 = plane address
        move.w  d3,6(a1)                ; store the low word
        swap    d3                      ; high word in low half
        move.w  d3,2(a1)                ; store the high word
        addq.l  #8,a1                   ; next pointer pair
        add.l   d1,a0                   ; next plane
        dbra    d2,.loop                ; repeat for all four planes
        rts                             ; patch complete

; ===========================================================================
; data
; ===========================================================================
        section data,data              ; read/write data section

gfxname:        dc.b    "graphics.library",0 ; library to open
        even                            ; keep following data longword aligned

spr_offsets:    dc.l    0,192,384,576,576,576,576,576 ; sun images 0-2, then reuse

sysbase:        dc.l    0               ; ExecBase
gfxbase:        dc.l    0               ; GfxBase
chipblock:      dc.l    0               ; chip RAM allocation
oldview:        dc.l    0               ; saved OS view
dma_clear:      dc.w    0               ; DMACON bits to clear on exit
        cnop    0,4                     ; align the next block

mid_base:       dc.l    0               ; mid plane 0 base
fg_base:        dc.l    0               ; fg plane 0 base
text_base:      dc.l    0               ; text plane 0 base
spr_base:       dc.l    0               ; sprite image base
list0:          dc.l    0               ; first copper list
list1:          dc.l    0               ; second copper list
list_ptrs:      dc.l    0,0             ; double-buffer table
patch_pf1:      dc.l    0,0             ; PF1 patch address per list
patch_pf2:      dc.l    0,0             ; PF2 patch address per list
patch_con1:     dc.l    0,0             ; BPLCON1 patch address per list

cur:            dc.w    0               ; copper list currently displayed
next:           dc.w    0               ; copper list being patched
dm:             dc.w    0               ; midground scroll delay
df:             dc.w    0               ; foreground scroll delay
wm:             dc.l    0               ; midground first fetched word
wf:             dc.l    0               ; foreground first fetched word
con1:           dc.w    0               ; combined BPLCON1 value
        cnop    0,4                     ; align the layer descriptors

mid_layer:                              ; midground layer descriptor
        dc.l    0                      ; strip (set at run time)
        dc.l    0                      ; base
        dc.l    0                      ; pos
        dc.l    -1                     ; filled
        dc.w    MID_H                  ; height
        dc.w    MID_SPEED              ; speed
        dc.l    MID_SIZE               ; plane stride in the buffer
        dc.l    MID_H*STRIP_BYTES      ; plane stride in the strip

fg_layer:                               ; foreground layer descriptor
        dc.l    0                      ; strip (set at run time)
        dc.l    0                      ; base
        dc.l    0                      ; pos
        dc.l    -1                     ; filled
        dc.w    FG_H                   ; height
        dc.w    FG_SPEED               ; speed
        dc.l    FG_SIZE                ; plane stride in the buffer
        dc.l    FG_H*STRIP_BYTES       ; plane stride in the strip

; ---- generated assets ---------------------------------------------------
palette:        incbin  "palette.bin"   ; 32 AGA colour words
sky:            incbin  "sky.bin"       ; one background colour per scene line
asset_layers:   incbin  "layers.bin"    ; mirrored mid/fg planar strips
asset_sprites:  incbin  "sprites.bin"   ; hardware sprite images
asset_text:     incbin  "text.bin"      ; title text bitplanes

        end                             ; end of source
