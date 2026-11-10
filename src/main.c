/*
 * Parallax scrolling demo for the Amiga 1200 (AGA)
 *
 * Historical C implementation.  The demo is now written in 68k assembly
 * (src/parallax.s); this file is kept for reference only and is no longer
 * part of the build.
 *
 *   sky        per-line COLOR00 gradient written by the copper
 *   sun        three hardware sprites, behind both playfields
 *   PF2        midground ruins, 4 bitplanes, 0.5 px/frame
 *   PF1        foreground houses/road, 4 bitplanes, 1 px/frame
 *
 * Scrolling is done by the hardware: AGA dual playfield with independent
 * bitplane pointers and BPLCON1 delays (quarter-pixel steps) per playfield.
 * Each playfield buffer is a "sliding" bitmap: rows are packed with no
 * modulo, so when the display start pointer advances by one word the word
 * that left the screen on row y+1 becomes the new right-hand column of
 * row y.  The blitter streams every new 16-pixel column from the
 * mirror-tiled layer strip into that word.  Per frame the CPU only patches
 * a few copper words, so the demo is locked to the 50 Hz vertical blank.
 */

#include <exec/types.h>
#include <exec/memory.h>
#include <dos/dos.h>
#include <dos/dosextens.h>
#include <intuition/intuition.h>
#include <intuition/screens.h>
#include <graphics/gfx.h>
#include <graphics/gfxbase.h>
#include <graphics/view.h>
#include <graphics/rastport.h>
#include <graphics/text.h>
#include <hardware/custom.h>
#include <proto/exec.h>
#include <proto/dos.h>
#include <proto/intuition.h>
#include <proto/graphics.h>

#include <string.h>

#include "assets.h"

#define CHIP ((volatile struct Custom *)0xDFF000)

struct IntuitionBase *IntuitionBase;
struct GfxBase       *GfxBase;
struct DosLibrary    *DOSBase;

#define DEPTH       4                   /* bitplanes per playfield */
#define ROWB        42                  /* 21 fetched words per line */
#define EXTRA       32768UL             /* scroll headroom per plane */
#define GUARD       64UL                /* zero bytes before each plane */
#define WMAX        ((LONG)(EXTRA / 2) - 32)
#define PERIOD_Q    ((ULONG)PERIOD_WORDS * 64UL)
#define TEXT_ROWS   (TITLE_H + 2)
#define TEXT_PLANE  ((ULONG)TEXT_ROWS * ROWB)
#define COP_WORDS   2048

#define DISP_TOP    0x3A
#define SCENE_TOP   (DISP_TOP + TITLE_H)

#define R_DIWSTRT   0x08E
#define R_DIWSTOP   0x090
#define R_DDFSTRT   0x092
#define R_DDFSTOP   0x094
#define R_BPL1PTH   0x0E0
#define R_BPLCON0   0x100
#define R_BPLCON1   0x102
#define R_BPLCON2   0x104
#define R_BPLCON3   0x106
#define R_BPL1MOD   0x108
#define R_BPL2MOD   0x10A
#define R_BPLCON4   0x10C
#define R_SPR0PTH   0x120
#define R_COLOR00   0x180
#define R_FMODE     0x1FC

#define BPLCON0_VAL 0x0611              /* 8 planes, dual playfield, ECSENA */
#define BPLCON3_VAL 0x1020              /* PF2 colours from 16, border blank */
#define BPLCON3_BK1 0x3020              /* same, colour bank 32-63 */

typedef struct {
    UBYTE *strip[DEPTH];
    UBYTE *mem[DEPTH];
    UBYTE *base[DEPTH];
    ULONG  size;
    UWORD  h;
    UWORD  speed;                       /* quarter pixels per frame */
    ULONG  pos;                         /* quarter pixels */
    LONG   filled;                      /* last column in the buffer */
} Layer;

typedef struct {
    UWORD *list;
    UWORD *pf1;                         /* PF1 pointer moves */
    UWORD *pf2;                         /* PF2 pointer moves */
    UWORD *con1;                        /* BPLCON1 value word */
} Copper;

static UBYTE *asset;
static UBYTE *textmem;
static UWORD *spritemem;
static UWORD *sprite[SUN_SPRITES];
static UWORD *nullspr;
static UWORD *copmem[2];
static Copper cop[2];
static Layer  mid, fg;
static UWORD *clp;
static int    cl_wrapped;
static struct BitMap   textbm;
static struct RastPort textrp;
static struct TextFont *topaz8;
static struct TextAttr topaz8_attr = {
    (STRPTR)"topaz.font", 8, FS_NORMAL, FPF_ROMFONT
};

/* ------------------------------------------------------------------ */
/* loading                                                            */

static UBYTE *load_asset(void)
{
    static const char *paths[] = {
        "parallax/data/parallax.dat",
        "Work:parallax/data/parallax.dat",
        "data/parallax.dat",
        NULL
    };
    BPTR fh = 0;
    LONG total = 0;
    UBYTE *mem;
    int i;

    for (i = 0; paths[i] && !fh; i++)
        fh = Open((STRPTR)paths[i], MODE_OLDFILE);
    if (!fh)
        return NULL;
    mem = (UBYTE *)AllocMem(ASSET_SIZE, MEMF_CHIP | MEMF_CLEAR);
    if (mem) {
        while (total < ASSET_SIZE) {
            LONG n = Read(fh, mem + total, ASSET_SIZE - total);
            if (n <= 0)
                break;
            total += n;
        }
    }
    Close(fh);
    if (mem && (total != ASSET_SIZE || memcmp(mem, "PLX2", 4) != 0)) {
        FreeMem(mem, ASSET_SIZE);
        mem = NULL;
    }
    return mem;
}

/* ------------------------------------------------------------------ */
/* scrolling layers                                                   */

static int layer_init(Layer *L, UBYTE *strip0, UWORD h, UWORD speed)
{
    int p;

    L->h = h;
    L->speed = speed;
    L->pos = 0;
    L->filled = -1;
    L->size = GUARD + (ULONG)(h + 1) * ROWB + EXTRA;
    for (p = 0; p < DEPTH; p++) {
        L->strip[p] = strip0 + (ULONG)p * STRIP_BYTES * h;
        L->mem[p] = (UBYTE *)AllocMem(L->size, MEMF_CHIP | MEMF_CLEAR);
        if (!L->mem[p])
            return 0;
        L->base[p] = L->mem[p] + GUARD;
    }
    return 1;
}

static void layer_free(Layer *L)
{
    int p;
    for (p = 0; p < DEPTH; p++)
        if (L->mem[p])
            FreeMem(L->mem[p], L->size);
}

/* first fetched word and BPLCON1 delay (quarter pixels) for a position */
static LONG pos_word(ULONG pos, UWORD *delay)
{
    UWORD d = (UWORD)(-(LONG)pos) & 63;
    if (delay)
        *delay = d;
    return (LONG)((pos + d) >> 6);
}

/* copy 16-pixel column c of the layer into the buffer (all rows) */
static void fill_column(Layer *L, LONG c)
{
    UWORD s = (UWORD)((c + PERIOD_WORDS - 1) % PERIOD_WORDS);
    int p;

    for (p = 0; p < DEPTH; p++) {
        WaitBlit();
        CHIP->bltcon0 = 0x09F0;         /* A -> D */
        CHIP->bltcon1 = 0;
        CHIP->bltafwm = 0xFFFF;
        CHIP->bltalwm = 0xFFFF;
        CHIP->bltamod = STRIP_BYTES - 2;
        CHIP->bltdmod = ROWB - 2;
        CHIP->bltapt  = (APTR)(L->strip[p] + s * 2);
        CHIP->bltdpt  = (APTR)(L->base[p] + c * 2);
        CHIP->bltsize = (UWORD)((L->h << 6) | 1);
    }
}

/* make sure every column fetched at L->pos is in the buffer */
static void layer_prepare(Layer *L)
{
    LONG w = pos_word(L->pos, NULL);

    if (w > WMAX) {
        /* end of the headroom: jump back by whole periods (same picture)
         * and rebuild the window in the untouched start of the buffer */
        L->pos %= PERIOD_Q;
        w = pos_word(L->pos, NULL);
        L->filled = w - 1;
    }
    if (L->filled < w - 1)
        L->filled = w - 1;
    while (L->filled < w + 20)
        fill_column(L, ++L->filled);
}

/* ------------------------------------------------------------------ */
/* copper lists                                                       */

static void cmove(UWORD reg, UWORD val)
{
    *clp++ = reg;
    *clp++ = val;
}

static void cwait(int line, int hp)
{
    if (line >= 256 && !cl_wrapped) {
        *clp++ = 0xFFDF;
        *clp++ = 0xFFFE;
        cl_wrapped = 1;
    }
    *clp++ = (UWORD)(((line & 0xFF) << 8) | (hp & 0xFE) | 1);
    *clp++ = 0xFFFE;
    if (line == 255 && hp >= 0xDE)
        cl_wrapped = 1;
}

static void cmove_ptr(UWORD reg, ULONG addr)
{
    cmove(reg, (UWORD)(addr >> 16));
    cmove(reg + 2, (UWORD)addr);
}

static void build_copper(Copper *cp, UWORD *mem)
{
    int i, k, y;

    clp = mem;
    cl_wrapped = 0;
    cp->list = mem;

    cmove(R_BPLCON0, BPLCON0_VAL);
    cmove(R_BPLCON2, 0x0000);           /* playfields in front of sprites */
    cmove(R_BPLCON3, BPLCON3_VAL);
    cmove(R_BPLCON4, 0x0022);           /* sprite colours from 32 */
    cmove(R_FMODE, 0x0000);
    cmove(R_DIWSTRT, (DISP_TOP << 8) | 0x81);
    cmove(R_DIWSTOP, (((SCENE_TOP + SCENE_H) & 0xFF) << 8) | 0xC1);
    cmove(R_DDFSTRT, 0x0030);           /* one extra word for fine scroll */
    cmove(R_DDFSTOP, 0x00D0);
    cmove(R_BPLCON1, 0);
    cmove(R_BPL1MOD, 0);
    cmove(R_BPL2MOD, (UWORD)-ROWB);

    for (i = 0; i < 8; i++)
        cmove_ptr(R_SPR0PTH + i * 4,
                  (ULONG)(i < SUN_SPRITES ? sprite[i] : nullspr));

    cmove(R_COLOR00, 0x000);
    for (i = 1; i < 16; i++)
        cmove(R_COLOR00 + i * 2, pf1_colors[i]);
    for (i = 1; i < 16; i++)
        cmove(R_COLOR00 + (16 + i) * 2, pf2_colors[i]);
    cmove(R_BPLCON3, BPLCON3_BK1);
    for (i = 1; i < 4; i++) {
        cmove(R_COLOR00 + i * 2, sun_colors[i]);         /* 33-35 */
        cmove(R_COLOR00 + (4 + i) * 2, sun_colors[i]);   /* 37-39 */
    }
    cmove(R_BPLCON3, BPLCON3_VAL);

    /* title band: PF1 shows the text bitmap, PF2 an empty row */
    for (k = 0; k < DEPTH; k++)
        cmove_ptr(R_BPL1PTH + (2 * k) * 4, (ULONG)textmem + k * TEXT_PLANE);
    cp->pf2 = clp;
    for (k = 0; k < DEPTH; k++)
        cmove_ptr(R_BPL1PTH + (2 * k + 1) * 4, 0);

    for (y = 0; y < SCENE_H; y++) {
        cwait(SCENE_TOP + y - 1, 0xDF);
        cmove(R_COLOR00, sky_colors[y]);
        if (y == 0) {
            /* PF1 repeats the (empty) row above the foreground buffer */
            cmove(R_BPL1MOD, (UWORD)-ROWB);
            cp->con1 = clp + 1;
            cmove(R_BPLCON1, 0);
            cp->pf1 = clp;
            for (k = 0; k < DEPTH; k++)
                cmove_ptr(R_BPL1PTH + (2 * k) * 4, 0);
        }
        if (y == MID_Y0 - 1)
            cmove(R_BPL2MOD, 0);        /* PF2 starts walking its buffer */
        if (y == FG_Y0 - 1)
            cmove(R_BPL1MOD, 0);        /* PF1 starts walking its buffer */
    }
    *clp++ = 0xFFFF;
    *clp++ = 0xFFFE;
}

static void set_ptrs(UWORD *moves, Layer *L, LONG w)
{
    int k;
    for (k = 0; k < DEPTH; k++) {
        ULONG a = (ULONG)L->base[k] + (ULONG)(w * 2) - ROWB;
        moves[k * 4 + 1] = (UWORD)(a >> 16);
        moves[k * 4 + 3] = (UWORD)a;
    }
}

static void update_copper(Copper *cp)
{
    UWORD dm, df;
    LONG wm = pos_word(mid.pos, &dm);
    LONG wf = pos_word(fg.pos, &df);

    set_ptrs(cp->pf2, &mid, wm);
    set_ptrs(cp->pf1, &fg, wf);
    *cp->con1 = (UWORD)(((df >> 2) & 15) | (((dm >> 2) & 15) << 4) |
                        ((df & 3) << 8) | ((dm & 3) << 12));
}

/* ------------------------------------------------------------------ */
/* sprites and text                                                   */

static int build_sprites(void)
{
    ULONG words = (ULONG)SUN_SPRITES * (SUN_H * 2 + 4) + 4;
    int s;

    spritemem = (UWORD *)AllocMem(words * 2, MEMF_CHIP | MEMF_CLEAR);
    if (!spritemem)
        return 0;
    for (s = 0; s < SUN_SPRITES; s++) {
        UWORD *sp = spritemem + s * (SUN_H * 2 + 4);
        UWORD hs = 0x80 + SUN_X + s * 16;
        UWORD vs = SCENE_TOP + SUN_Y;
        UWORD ve = vs + SUN_H;

        sprite[s] = sp;
        sp[0] = (UWORD)(((vs & 0xFF) << 8) | ((hs >> 1) & 0xFF));
        sp[1] = (UWORD)(((ve & 0xFF) << 8) | (((vs >> 8) & 1) << 2) |
                        (((ve >> 8) & 1) << 1) | (hs & 1));
        CopyMem(asset + OFF_SUN + (ULONG)s * SUN_H * 4, sp + 2, SUN_H * 4);
    }
    nullspr = spritemem + SUN_SPRITES * (SUN_H * 2 + 4);
    return 1;
}

static void text_centered(int y, const char *s)
{
    int len = (int)strlen(s);
    int w = TextLength(&textrp, (CONST_STRPTR)s, len);
    Move(&textrp, 16 + (SCENE_W - w) / 2, y);
    Text(&textrp, (CONST_STRPTR)s, len);
}

static int build_text(void)
{
    int k;

    textmem = (UBYTE *)AllocMem(DEPTH * TEXT_PLANE, MEMF_CHIP | MEMF_CLEAR);
    if (!textmem)
        return 0;
    InitBitMap(&textbm, DEPTH, ROWB * 8, TEXT_ROWS);
    for (k = 0; k < DEPTH; k++)
        textbm.Planes[k] = textmem + k * TEXT_PLANE;
    InitRastPort(&textrp);
    textrp.BitMap = &textbm;
    topaz8 = OpenFont(&topaz8_attr);
    SetFont(&textrp, topaz8 ? topaz8 : GfxBase->DefaultFont);
    SetAPen(&textrp, TEXT_PEN);
    SetDrMd(&textrp, JAM1);
    text_centered(11, "PARALLAX  //  BLITTER + COPPER SCROLL");
    text_centered(23, "A1200 AGA  DUAL PLAYFIELD  50 FPS");
    WaitBlit();
    return 1;
}

/* ------------------------------------------------------------------ */
/* stats (test mode only)                                             */

static char *put_num(char *q, ULONG v)
{
    char tmp[12];
    int n = 0;
    do {
        tmp[n++] = (char)('0' + v % 10);
        v /= 10;
    } while (v);
    while (n)
        *q++ = tmp[--n];
    return q;
}

static void write_stats(ULONG frames, ULONG ticks)
{
    char buf[64];
    char *q = buf;
    BPTR fh;

    memcpy(q, "frames=", 7);  q = put_num(q + 7, frames);
    memcpy(q, " ticks=", 7);  q = put_num(q + 7, ticks);
    *q++ = '\n';
    fh = Open((STRPTR)"Work:parallax/stats.txt", MODE_NEWFILE);
    if (fh) {
        Write(fh, buf, q - buf);
        Close(fh);
    }
}

/* ------------------------------------------------------------------ */
/* main                                                               */

int main(int argc, char **argv)
{
    struct Screen *scr = NULL;
    struct Window *win = NULL;
    struct View *oldview;
    struct DateStamp ds0, ds1;
    ULONG frames = 0;
    int running = 1, cur = 0, test_rebase = 0, stats = 0, i;

    IntuitionBase = (struct IntuitionBase *)OpenLibrary((CONST_STRPTR)"intuition.library", 39);
    GfxBase       = (struct GfxBase *)OpenLibrary((CONST_STRPTR)"graphics.library", 39);
    DOSBase       = (struct DosLibrary *)OpenLibrary((CONST_STRPTR)"dos.library", 37);
    if (!IntuitionBase || !GfxBase || !DOSBase)
        return 20;
    if ((CHIP->deniseid & 0xFF) != 0xF8)
        return 20;                      /* needs AGA (Lisa) */

    /* never pop an "insert volume" requester on a floppy/HDF boot */
    ((struct Process *)FindTask(NULL))->pr_WindowPtr = (APTR)-1;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "rebase") == 0)
            test_rebase = 1;
        if (strcmp(argv[i], "stats") == 0)
            stats = 1;
    }

    asset = load_asset();
    if (!asset)
        goto out;
    for (i = 0; i < 2; i++) {
        copmem[i] = (UWORD *)AllocMem(COP_WORDS * 2, MEMF_CHIP | MEMF_CLEAR);
        if (!copmem[i])
            goto out;
    }
    if (!layer_init(&mid, asset + OFF_MID, MID_H, MID_SPEED) ||
        !layer_init(&fg, asset + OFF_FG, FG_H, FG_SPEED) ||
        !build_sprites() || !build_text())
        goto out;
    if (test_rebase) {
        mid.pos = (ULONG)(WMAX - 12) * 64;
        fg.pos = (ULONG)(WMAX - 24) * 64;
    }
    build_copper(&cop[0], copmem[0]);
    build_copper(&cop[1], copmem[1]);

    /* a quiet screen + window only to receive keyboard and mouse input */
    scr = OpenScreenTags(NULL,
        SA_Width, 320, SA_Height, 200, SA_Depth, 1,
        SA_Type, CUSTOMSCREEN, SA_Quiet, TRUE, SA_ShowTitle, FALSE,
        TAG_DONE);
    if (!scr)
        goto out;
    win = OpenWindowTags(NULL,
        WA_CustomScreen, (ULONG)scr,
        WA_Left, 0, WA_Top, 0, WA_Width, 320, WA_Height, 200,
        WA_Borderless, TRUE, WA_Backdrop, TRUE, WA_Activate, TRUE,
        WA_RMBTrap, TRUE,
        WA_IDCMP, IDCMP_RAWKEY | IDCMP_MOUSEBUTTONS,
        TAG_DONE);
    if (!win)
        goto out;

    SetTaskPri(FindTask(NULL), 5);

    OwnBlitter();
    layer_prepare(&mid);
    layer_prepare(&fg);
    WaitBlit();
    DisownBlitter();
    update_copper(&cop[0]);

    oldview = GfxBase->ActiView;
    LoadView(NULL);
    WaitTOF();
    WaitTOF();
    CHIP->cop1lc = (ULONG)cop[0].list;
    DateStamp(&ds0);

    while (running) {
        struct IntuiMessage *msg;

        WaitTOF();                      /* cop[cur] is now on screen */

        while ((msg = (struct IntuiMessage *)GetMsg(win->UserPort)) != NULL) {
            ULONG cls = msg->Class;
            UWORD code = msg->Code;
            ReplyMsg((struct Message *)msg);
            if ((cls == IDCMP_RAWKEY && code == 0x45) ||
                (cls == IDCMP_MOUSEBUTTONS && code == SELECTDOWN))
                running = 0;
        }
        if (SetSignal(0L, 0L) & SIGBREAKF_CTRL_C)
            running = 0;

        /* next frame: stream the new columns, then patch the idle list */
        mid.pos += mid.speed;
        fg.pos += fg.speed;
        OwnBlitter();
        layer_prepare(&mid);
        layer_prepare(&fg);
        WaitBlit();
        DisownBlitter();

        cur ^= 1;
        update_copper(&cop[cur]);
        CHIP->cop1lc = (ULONG)cop[cur].list;
        frames++;
    }

    DateStamp(&ds1);
    CHIP->cop1lc = (ULONG)GfxBase->copinit;
    LoadView(oldview);
    WaitTOF();
    WaitTOF();
    RethinkDisplay();

    if (stats)
        write_stats(frames,
                    (ULONG)((ds1.ds_Days - ds0.ds_Days) * 24L * 60 * 60 * 50 +
                            (ds1.ds_Minute - ds0.ds_Minute) * 60L * 50 +
                            (ds1.ds_Tick - ds0.ds_Tick)));

out:
    if (win)
        CloseWindow(win);
    if (scr)
        CloseScreen(scr);
    layer_free(&mid);
    layer_free(&fg);
    if (topaz8)
        CloseFont(topaz8);
    if (textmem)
        FreeMem(textmem, DEPTH * TEXT_PLANE);
    if (spritemem)
        FreeMem(spritemem, ((ULONG)SUN_SPRITES * (SUN_H * 2 + 4) + 4) * 2);
    for (i = 0; i < 2; i++)
        if (copmem[i])
            FreeMem(copmem[i], COP_WORDS * 2);
    if (asset)
        FreeMem(asset, ASSET_SIZE);
    CloseLibrary((struct Library *)DOSBase);
    CloseLibrary((struct Library *)GfxBase);
    CloseLibrary((struct Library *)IntuitionBase);
    return 0;
}
