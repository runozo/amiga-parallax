/*
 * Parallax scrolling demo for the Amiga 1200 (AGA)
 *
 * Three parallax layers built from craftpix "War1" background art:
 *   - static sky + sun
 *   - midground ruins/buildings  (opaque, scrolled with the blitter)
 *   - foreground houses/road     (masked, scrolled with the blitter)
 *
 * The blitter performs every pixel copy.  Horizontal scrolling is done
 * with the blitter's barrel shifter (BLTCON0/ASH): a one-word run-up is
 * written into the 16-pixel screen border so every visible word is exact.
 * Double buffering uses graphics.library ChangeVPBitMap() (V39+).
 */

#include <exec/types.h>
#include <exec/memory.h>
#include <dos/dos.h>
#include <dos/dosextens.h>
#include <dos/dostags.h>
#include <intuition/intuition.h>
#include <intuition/screens.h>
#include <graphics/gfx.h>
#include <graphics/gfxbase.h>
#include <graphics/view.h>
#include <graphics/rastport.h>
#include <proto/exec.h>
#include <proto/dos.h>
#include <proto/intuition.h>
#include <proto/graphics.h>
#include <hardware/custom.h>
#include <hardware/blit.h>

#include <stdio.h>
#include <string.h>

#include "assets.h"

#define CHIP ((volatile struct Custom *)0xDFF000)

struct IntuitionBase *IntuitionBase;
struct GfxBase       *GfxBase;
struct DosLibrary    *DOSBase;

/* ------------------------------------------------------------------ */
/* asset pieces                                                       */

typedef struct {
    UWORD  y;            /* screen row of the first strip row */
    UWORD  h;            /* number of rows */
    UBYTE *planes[DEPTH];
    UBYTE *mask;         /* NULL for opaque parts */
} Part;

static UBYTE *asset = NULL;       /* whole data file, chip RAM */
static struct ColorSpec colors[NCOL + 1];
static Part midPart, nearMaskPart, nearOpaquePart;

/* ------------------------------------------------------------------ */
/* little helpers                                                     */

/* the blitter register write must not be interrupted by another task's
 * blit; we own the blitter for the whole run, so a plain WaitBlit is
 * enough between operations. */

#define BLIT_BYTES  ((WIN_W + 32) / 8)   /* 22 words = 352 px */

static void blit_opaque(struct BitMap *bm, Part *pt, int plane, UWORD px)
{
    UWORD shift     = px & 15;
    int   src_word  = (px >> 4) - (shift == 0 ? 1 : 0);
    UWORD dst_mod   = bm->BytesPerRow - BLIT_BYTES;
    ULONG dst       = (ULONG)bm->Planes[plane] +
                      (ULONG)pt->y * bm->BytesPerRow;
    UBYTE *src      = pt->planes[plane] + src_word * 2;

    CHIP->bltcon0 = (shift << 12) | 0x09F0;  /* A -> D */
    CHIP->bltcon1 = 0;
    CHIP->bltafwm = 0xFFFF;
    CHIP->bltalwm = 0xFFFF;
    CHIP->bltamod = STRIP_BYTES - BLIT_BYTES;
    CHIP->bltdmod = dst_mod;
    CHIP->bltapt  = (APTR)src;
    CHIP->bltdpt  = (APTR)dst;
    CHIP->bltsize = (pt->h << 6) | (BLIT_BYTES / 2);
    WaitBlit();
}

static void blit_masked(struct BitMap *bm, Part *pt, int plane, UWORD px)
{
    UWORD shift     = px & 15;
    int   src_word  = (px >> 4) - (shift == 0 ? 1 : 0);
    UWORD dst_mod   = bm->BytesPerRow - BLIT_BYTES;
    ULONG dst       = (ULONG)bm->Planes[plane] +
                      (ULONG)pt->y * bm->BytesPerRow;
    UBYTE *src      = pt->planes[plane] + src_word * 2;
    UBYTE *mask     = pt->mask + src_word * 2;

    CHIP->bltcon0 = (shift << 12) | 0x0FE2;  /* (A & B) | (C & ~B) */
    CHIP->bltcon1 = 0;
    CHIP->bltafwm = 0xFFFF;
    CHIP->bltalwm = 0xFFFF;
    CHIP->bltamod = STRIP_BYTES - BLIT_BYTES;
    CHIP->bltbmod = STRIP_BYTES - BLIT_BYTES;
    CHIP->bltcmod = dst_mod;
    CHIP->bltdmod = dst_mod;
    CHIP->bltapt  = (APTR)src;
    CHIP->bltbpt  = (APTR)mask;
    CHIP->bltcpt  = (APTR)dst;
    CHIP->bltdpt  = (APTR)dst;
    CHIP->bltsize = (pt->h << 6) | (BLIT_BYTES / 2);
    WaitBlit();
}

static void draw_part(struct BitMap *bm, Part *pt, UWORD px)
{
    int p;
    for (p = 0; p < DEPTH; p++) {
        if (pt->mask)
            blit_masked(bm, pt, p, px);
        else
            blit_opaque(bm, pt, p, px);
    }
}

/* fill the 16-pixel side borders with colour 0 */
static void clear_borders(struct BitMap *bm)
{
    int p, side;
    UWORD right_word = (WIN_X + WIN_W) / 16;   /* word 21 = x 336 */

    for (p = 0; p < DEPTH; p++) {
        for (side = 0; side < 2; side++) {
            ULONG dst = (ULONG)bm->Planes[p] +
                        (ULONG)(side ? right_word : 0) * 2;
            CHIP->bltcon0 = 0x0100;          /* D only, minterm 0 */
            CHIP->bltcon1 = 0;
            CHIP->bltdmod = bm->BytesPerRow - 2;
            CHIP->bltdpt  = (APTR)dst;
            CHIP->bltsize = (SCREEN_H << 6) | 1;
            WaitBlit();
        }
    }
}

/* ------------------------------------------------------------------ */
/* text                                                               */

static void draw_text(struct Screen *scr, struct BitMap *bm,
                      int x, int y, const char *s, int pen)
{
    struct RastPort rp;
    InitRastPort(&rp);
    rp.BitMap = bm;
    SetFont(&rp, scr->RastPort.Font ? scr->RastPort.Font : GfxBase->DefaultFont);
    SetAPen(&rp, pen);
    SetBPen(&rp, 0);
    SetDrMd(&rp, JAM1);
    Move(&rp, x, y);
    Text(&rp, (CONST_STRPTR)s, (LONG)strlen(s));
}

/* ------------------------------------------------------------------ */
/* background copy                                                    */

static void copy_background(struct BitMap *bm)
{
    int p, row;
    int src_stride = SCREEN_W / 8;
    int pl_size = BG_SIZE / DEPTH;

    for (p = 0; p < DEPTH; p++) {
        UBYTE *src = asset + BG_OFFSET + p * pl_size;
        UBYTE *dst = (UBYTE *)bm->Planes[p];
        if (bm->BytesPerRow == src_stride) {
            CopyMem(src, dst, (ULONG)src_stride * SCREEN_H);
        } else {
            for (row = 0; row < SCREEN_H; row++)
                CopyMem(src + row * src_stride,
                        dst + row * bm->BytesPerRow, src_stride);
        }
    }
}

/* ------------------------------------------------------------------ */
/* loading                                                            */

static UBYTE *load_asset(ULONG *size_out)
{
    static const char *paths[] = {
        "parallax/data/parallax.dat",       /* boot disk root / cwd */
        "Work:parallax/data/parallax.dat",  /* DevBench Work: share */
        "data/parallax.dat",                /* cwd = program drawer */
        NULL
    };
    BPTR fh = 0;
    LONG total;
    UBYTE *mem;
    int i;

    for (i = 0; paths[i]; i++) {
        fh = Open((STRPTR)paths[i], MODE_OLDFILE);
        if (fh)
            break;
    }
    if (!fh)
        return NULL;
    mem = (UBYTE *)AllocMem(ASSET_SIZE, MEMF_CHIP | MEMF_CLEAR);
    if (!mem) {
        Close(fh);
        return NULL;
    }
    total = 0;
    while (total < ASSET_SIZE) {
        LONG n = Read(fh, mem + total, ASSET_SIZE - total);
        if (n <= 0)
            break;
        total += n;
    }
    Close(fh);
    if (total != ASSET_SIZE) {
        FreeMem(mem, ASSET_SIZE);
        return NULL;
    }
    if (memcmp(mem, "PLX1", 4) != 0) {
        FreeMem(mem, ASSET_SIZE);
        return NULL;
    }
    *size_out = ASSET_SIZE;
    return mem;
}

/* ------------------------------------------------------------------ */
/* main                                                               */

static int demo_run(void)
{
    struct Screen   *scr;
    struct Window   *win;
    struct BitMap   *buf[2];
    struct DBufInfo *dbi;
    struct MsgPort  *safePort, *dispPort;
    ULONG asset_size = 0;
    ULONG mid_acc = 0, near_acc = 0;
    UWORD mid_px = 0, near_px = 0;
    int running = 1;
    int back = 1;
    struct DateStamp ds;
    ULONG last_tick;
    int i, p;
    UWORD mid_drawn[2];

    IntuitionBase = (struct IntuitionBase *)OpenLibrary((CONST_STRPTR)"intuition.library", 39);
    GfxBase       = (struct GfxBase *)OpenLibrary((CONST_STRPTR)"graphics.library", 39);
    DOSBase       = (struct DosLibrary *)OpenLibrary((CONST_STRPTR)"dos.library", 37);
    if (!IntuitionBase || !GfxBase || !DOSBase)
        return 1;

    /* never pop an "insert volume Work" requester on a floppy/HDF boot */
    ((struct Process *)FindTask(NULL))->pr_WindowPtr = (APTR)-1;

    /* stay below the bridge/serial task so the dev channel keeps running */
    SetTaskPri(FindTask(NULL), -10);

    asset = load_asset(&asset_size);
    if (!asset) {
        /* best effort: say something on the default screen */
        struct RastPort *rp;
        struct Screen *ws = LockPubScreen(NULL);
        if (ws) {
            rp = &ws->RastPort;
            SetAPen(rp, 1);
            Move(rp, 20, 20);
            Text(rp, (CONST_STRPTR)"parallax.dat not found", 22);
            UnlockPubScreen(NULL, ws);
        }
        Delay(500);
        return 1;
    }


    /* palette */
    for (i = 0; i < NCOL; i++) {
        colors[i].ColorIndex = i;
        colors[i].Red   = (palette[i] >> 8) & 15;
        colors[i].Green = (palette[i] >> 4) & 15;
        colors[i].Blue  = palette[i] & 15;
    }
    colors[NCOL].ColorIndex = -1;

    scr = OpenScreenTags(NULL,
        SA_Width,   SCREEN_W,
        SA_Height,  SCREEN_H,
        SA_Depth,   DEPTH,
        SA_Type,    CUSTOMSCREEN,
        SA_Title,   (ULONG)"Parallax",
        SA_ShowTitle, FALSE,
        SA_Quiet,   TRUE,
        SA_Colors,  (ULONG)colors,
        TAG_DONE);
    if (!scr) {
        FreeMem(asset, asset_size);
        return 1;
    }


    buf[0] = scr->RastPort.BitMap;
    buf[1] = AllocBitMap(SCREEN_W, SCREEN_H, DEPTH,
                         BMF_DISPLAYABLE | BMF_MINPLANES | BMF_CLEAR,
                         buf[0]);
    if (!buf[1] || buf[0]->BytesPerRow != SCREEN_W / 8 ||
        buf[1]->BytesPerRow != buf[0]->BytesPerRow) {
        if (buf[1]) FreeBitMap(buf[1]);
        CloseScreen(scr);
        FreeMem(asset, asset_size);
        return 1;
    }


    dbi = AllocDBufInfo(&scr->ViewPort);
    safePort = CreateMsgPort();
    dispPort = CreateMsgPort();
    if (!dbi || !safePort || !dispPort) {
        if (dbi) FreeDBufInfo(dbi);
        if (safePort) DeleteMsgPort(safePort);
        if (dispPort) DeleteMsgPort(dispPort);
        FreeBitMap(buf[1]);
        CloseScreen(scr);
        FreeMem(asset, asset_size);
        return 1;
    }
    dbi->dbi_SafeMessage.mn_ReplyPort = safePort;
    dbi->dbi_DispMessage.mn_ReplyPort = dispPort;


    /* layer descriptors (offsets relative to the asset file) */
    midPart.y      = P_MID_OPAQUE_Y;
    midPart.h      = P_MID_OPAQUE_H;
    midPart.mask   = NULL;
    for (p = 0; p < DEPTH; p++)
        midPart.planes[p] = asset + P_MID_OPAQUE_OFF + p * P_MID_OPAQUE_PLANESZ;

    nearMaskPart.y    = P_NEAR_MASK_Y;
    nearMaskPart.h    = P_NEAR_MASK_H;
    nearMaskPart.mask = asset + P_NEAR_MASK_MASK;
    for (p = 0; p < DEPTH; p++)
        nearMaskPart.planes[p] = asset + P_NEAR_MASK_OFF + p * P_NEAR_MASK_PLANESZ;

    nearOpaquePart.y    = P_NEAR_OPAQUE_Y;
    nearOpaquePart.h    = P_NEAR_OPAQUE_H;
    nearOpaquePart.mask = NULL;
    for (p = 0; p < DEPTH; p++)
        nearOpaquePart.planes[p] = asset + P_NEAR_OPAQUE_OFF + p * P_NEAR_OPAQUE_PLANESZ;

    /* input window */
    win = OpenWindowTags(NULL,
        WA_CustomScreen, (ULONG)scr,
        WA_Left, 0, WA_Top, 0,
        WA_Width, SCREEN_W, WA_Height, SCREEN_H,
        WA_Borderless, TRUE,
        WA_Backdrop, TRUE,
        WA_Activate, TRUE,
        WA_RMBTrap, TRUE,
        WA_IDCMP, IDCMP_RAWKEY | IDCMP_MOUSEBUTTONS,
        TAG_DONE);
    if (!win) {
        FreeDBufInfo(dbi);
        DeleteMsgPort(safePort);
        DeleteMsgPort(dispPort);
        FreeBitMap(buf[1]);
        CloseScreen(scr);
        FreeMem(asset, asset_size);
        return 1;
    }
    ClearPointer(win);

    /* both buffers start with the static background + titles */
    copy_background(buf[0]);
    copy_background(buf[1]);
    draw_text(scr, buf[0], 20, 16, "PARALLAX  //  BLITTER SCROLLING", 17);
    draw_text(scr, buf[1], 20, 16, "PARALLAX  //  BLITTER SCROLLING", 17);
    draw_text(scr, buf[0], 20, 250, "AMIGA 1200   AGA   32 COLOURS", 2);
    draw_text(scr, buf[1], 20, 250, "AMIGA 1200   AGA   32 COLOURS", 2);


    mid_drawn[0] = mid_drawn[1] = 0xFFFF;

    DateStamp(&ds);
    last_tick = ds.ds_Tick;

    /* let the blitter win chip-bus arbitration */
    CHIP->dmacon = 0x8400;      /* set BLTPRI */

    /* main loop */
    while (running) {
        struct IntuiMessage *msg;
        ULONG sigs;

        while ((msg = (struct IntuiMessage *)GetMsg(win->UserPort)) != NULL) {
            ULONG cls = msg->Class;
            UWORD code = msg->Code;
            ReplyMsg((struct Message *)msg);
            if (cls == IDCMP_RAWKEY && code == 0x45)   /* ESC */
                running = 0;
        }
        sigs = SetSignal(0L, 0L);
        if (sigs & SIGBREAKF_CTRL_C)
            running = 0;
        if (!running)
            break;

        /* advance scroll by elapsed 50 Hz ticks: constant pixels/second
         * regardless of the actual frame rate */
        {
            ULONG now;
            LONG dt;
            DateStamp(&ds);
            now = ds.ds_Tick;
            dt = now - (LONG)last_tick;
            if (dt < 0)
                dt += 3000;
            if (dt > 10)
                dt = 10;
            last_tick = now;
            if (dt) {
                mid_acc += (ULONG)dt * MID_SPEED;
                mid_px += (UWORD)(mid_acc >> 16);
                mid_acc &= 0xFFFF;
                while (mid_px >= PERIOD) mid_px -= PERIOD;

                near_acc += (ULONG)dt * NEAR_SPEED;
                near_px += (UWORD)(near_acc >> 16);
                near_acc &= 0xFFFF;
                while (near_px >= PERIOD) near_px -= PERIOD;
            }
        }

        /* compose into the back buffer; the mid layer only needs a
         * redraw when its integer offset changed for this buffer */
        if (mid_drawn[back] != mid_px) {
            draw_part(buf[back], &midPart, mid_px);
            mid_drawn[back] = mid_px;
        }
        draw_part(buf[back], &nearMaskPart, near_px);
        draw_part(buf[back], &nearOpaquePart, near_px);
        clear_borders(buf[back]);
        WaitBlit();

        /* flip on the next vertical blank. With two buffers the back
         * buffer is the previous front and is already safe to write. */
        while (GetMsg(safePort)) ;
        while (GetMsg(dispPort)) ;
        WaitTOF();
        ChangeVPBitMap(&scr->ViewPort, buf[back], dbi);
        back ^= 1;

    }

    /* shutdown: drain pending buffer messages, then release them */
    while (GetMsg(safePort)) ;
    while (GetMsg(dispPort)) ;
    CHIP->dmacon = 0x0400;      /* clear BLTPRI */
    WaitBlit();

    FreeDBufInfo(dbi);
    DeleteMsgPort(safePort);
    DeleteMsgPort(dispPort);
    CloseWindow(win);
    CloseScreen(scr);
    FreeBitMap(buf[1]);

    FreeMem(asset, asset_size);

    CloseLibrary((struct Library *)DOSBase);
    CloseLibrary((struct Library *)GfxBase);
    CloseLibrary((struct Library *)IntuitionBase);
    return 0;
}

int main(void)
{
    return demo_run();
}
