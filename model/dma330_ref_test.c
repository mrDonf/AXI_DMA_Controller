/*==============================================================================
 * dma330_ref_test.c - stand-alone known-answer tests of the C reference model
 *------------------------------------------------------------------------------
 * gcc -O2 -Wall -o dma330_ref_test dma330_ref_test.c dma330_ref.c && ./dma330_ref_test
 *
 * Every expected value below is derived by hand from docs/DESIGN_SPEC.md
 * (4.5, 4.7, 5.9, 7), not from the model, so a wrong model fails here before
 * it is ever used as the scoreboard reference.
 *============================================================================*/
#include <stdio.h>
#include <string.h>

#include "dma330_ref.h"

static int g_checks, g_fail;

#define CHECK(cond, ...)                                                       \
    do {                                                                       \
        g_checks++;                                                            \
        if (!(cond)) {                                                         \
            g_fail++;                                                          \
            printf("  FAIL %s:%d: ", __FILE__, __LINE__);                      \
            printf(__VA_ARGS__);                                               \
            printf("\n");                                                      \
        }                                                                      \
    } while (0)

/*------------------------------------------------------------------------------
 * Tiny assembler + memory
 *----------------------------------------------------------------------------*/
typedef struct { uint8_t b[256]; unsigned n; } prog_t;

static void put(prog_t* p, uint8_t v) { p->b[p->n++] = v; }
static void p_end(prog_t* p)  { put(p, 0x00); }
static void p_kill(prog_t* p) { put(p, 0x01); }
static void p_nop(prog_t* p)  { put(p, 0x18); }
static void p_wmb(prog_t* p)  { put(p, 0x13); }
static void p_ld(prog_t* p, uint8_t cond)  { put(p, 0x04 | cond); }      /* cond: 0, 1 (S), 3 (B) */
static void p_st(prog_t* p, uint8_t cond)  { put(p, 0x08 | cond); }
static void p_stz(prog_t* p)  { put(p, 0x0C); }
static void p_ldp(prog_t* p, uint8_t burst, unsigned per) { put(p, burst ? 0x27 : 0x25); put(p, (uint8_t)(per << 3)); }
static void p_stp(prog_t* p, uint8_t burst, unsigned per) { put(p, burst ? 0x2B : 0x29); put(p, (uint8_t)(per << 3)); }
static void p_mov(prog_t* p, unsigned r, uint32_t v)
{
    put(p, 0xBC); put(p, (uint8_t)r);
    put(p, v & 255); put(p, (v >> 8) & 255); put(p, (v >> 16) & 255); put(p, (v >> 24) & 255);
}
static void p_lp(prog_t* p, unsigned lc, unsigned iter) { put(p, 0x20 | (lc << 1)); put(p, (uint8_t)(iter - 1)); }
static unsigned p_pc(const prog_t* p) { return p->n; }
static void p_lpend(prog_t* p, unsigned lc, unsigned body, uint8_t cond)
{
    put(p, 0x38 | (lc << 2) | cond);
    put(p, (uint8_t)(p->n - 1 - body));       /* jump = address of LPEND - body start */
}
static void p_lpfe(prog_t* p, unsigned body)
{
    put(p, 0x2C | 0x00);                      /* nf=0, LC1 encoding, unconditional */
    put(p, (uint8_t)(p->n - 1 - body));
}
static void p_wfp(prog_t* p, unsigned per, unsigned kind) { put(p, 0x30 | kind); put(p, (uint8_t)(per << 3)); }
static void p_flushp(prog_t* p, unsigned per) { put(p, 0x35); put(p, (uint8_t)(per << 3)); }
static void p_sev(prog_t* p, unsigned ev) { put(p, 0x34); put(p, (uint8_t)(ev << 3)); }
static void p_addh(prog_t* p, unsigned dar, uint16_t v) { put(p, dar ? 0x56 : 0x54); put(p, v & 255); put(p, v >> 8); }
static void p_adnh(prog_t* p, unsigned dar, uint16_t v) { put(p, dar ? 0x5E : 0x5C); put(p, v & 255); put(p, v >> 8); }

#define CODE_BASE 0x00100000u

static uint8_t mem_byte(uint32_t a) { return (uint8_t)(a ^ (a >> 8) ^ (a >> 16) ^ 0x5A); }

static uint32_t ccr(unsigned s_inc, unsigned s_size, unsigned s_beats,
                    unsigned d_inc, unsigned d_size, unsigned d_beats, unsigned swap)
{
    return s_inc | (s_size << 1) | ((s_beats - 1) << 4) | (d_inc << 14) | (d_size << 15) |
           ((d_beats - 1) << 18) | (swap << 28);
}

/*------------------------------------------------------------------------------
 * Driver: runs a program to its end, recording every event
 *----------------------------------------------------------------------------*/
#define MAX_EV 256
typedef struct {
    dm_event_t e;
    uint8_t    data[DM_MAX_BEATS][DM_MAX_BUS_BYTES];
    uint32_t   strb[DM_MAX_BEATS];
} rec_t;

/* Requests the peripherals raise, queued by run() after DMAGO */
static struct { unsigned per, burst, last; } g_reqs[16];
static unsigned g_nreq;

static rec_t   g_ev[MAX_EV];
static unsigned g_n;
static int      g_ns;                                   /* DMAGO ns of run() */
static dm_ev_kind_t g_last;

static dma330_t* new_model(void)
{
    dma330_cfg_t c = { 8, 16, 4, 256, 0 };          /* 8-byte bus, MFIFO of 32 lines */
    dma330_t* m = dma330_new(&c);
    return m;
}

static void supply_mem(dma330_t* m, uint32_t addr, unsigned n, const prog_t* code)
{
    uint8_t buf[16];
    unsigned i, k = 0;
    for (i = 0; i < n; i++) {                                   /* 16-byte chunks, as over DPI */
        uint32_t a = addr + i;
        if (code && a >= CODE_BASE && a < CODE_BASE + code->n) buf[k] = code->b[a - CODE_BASE];
        else if (code && a >= CODE_BASE) buf[k] = 0x00;         /* past the program: DMAEND */
        else buf[k] = mem_byte(a);
        if (++k == sizeof buf || i == n - 1) { dma330_supply(m, buf, k); k = 0; }
    }
}

static dm_ev_kind_t run(dma330_t* m, const prog_t* p)
{
    dm_ev_kind_t k;
    unsigned i;
    g_n = 0;
    dma330_go(m, CODE_BASE, g_ns);
    for (i = 0; i < g_nreq; i++) dma330_periph_req(m, g_reqs[i].per, g_reqs[i].burst, g_reqs[i].last);
    for (;;) {
        k = dma330_step(m);
        if (k == DM_EV_NEED_CODE) {
            const dm_event_t* e = dma330_event(m);
            supply_mem(m, e->supply_addr, e->supply_bytes, p);
            continue;
        }
        if (g_n < MAX_EV) {
            rec_t* r = &g_ev[g_n++];
            unsigned b;
            r->e = *dma330_event(m);
            if (k == DM_EV_ST || k == DM_EV_STZ)
                for (b = 0; b < r->e.nbeats; b++) dma330_beat(m, b, r->data[b], &r->strb[b]);
        }
        if (k == DM_EV_LD) {
            const dm_event_t* e = dma330_event(m);
            supply_mem(m, e->supply_addr, e->supply_bytes, NULL);
            continue;
        }
        if (k == DM_EV_END || k == DM_EV_KILL || k == DM_EV_FAULT || k == DM_EV_UNKNOWN ||
            k == DM_EV_RUNAWAY || k == DM_EV_STARVED || k == DM_EV_UNSURE)
            break;
    }
    g_last = k;
    return k;
}

static unsigned count(dm_ev_kind_t k)
{
    unsigned i, n = 0;
    for (i = 0; i < g_n; i++) if (g_ev[i].e.kind == k) n++;
    return n;
}

static const rec_t* nth(dm_ev_kind_t k, unsigned idx)
{
    unsigned i;
    for (i = 0; i < g_n; i++)
        if (g_ev[i].e.kind == k && idx-- == 0) return &g_ev[i];
    return NULL;
}

/*------------------------------------------------------------------------------
 * Tests
 *----------------------------------------------------------------------------*/
static void test_aligned_copy(void)
{
    dma330_t* m = new_model();
    prog_t p = {{0}, 0};
    const rec_t *ld, *st;
    unsigned i;
    printf("aligned copy\n");
    p_mov(&p, 0, 0x1000); p_mov(&p, 2, 0x2000); p_mov(&p, 1, ccr(1, 3, 4, 1, 3, 4, 0));
    p_ld(&p, 0); p_st(&p, 0); p_wmb(&p); p_sev(&p, 3); p_end(&p);
    CHECK(run(m, &p) == DM_EV_END, "ends with DMAEND");
    ld = nth(DM_EV_LD, 0); st = nth(DM_EV_ST, 0);
    CHECK(ld && st, "one LD and one ST");
    CHECK(ld->e.addr == 0x1000 && ld->e.len == 3 && ld->e.size == 3 && ld->e.inc, "LD shape");
    CHECK(ld->e.bytes == 32 && ld->e.supply_bytes == 32, "LD payload 32 bytes");
    CHECK(st->e.addr == 0x2000 && st->e.nbeats == 4, "ST shape");
    for (i = 0; i < 32; i++)
        CHECK(st->data[i / 8][i % 8] == mem_byte(0x1000 + i), "ST byte %u", i);
    CHECK(st->strb[0] == 0xFF && st->strb[3] == 0xFF, "full strobes");
    CHECK(dma330_reg(m, DM_R_SAR) == 0x1020 && dma330_reg(m, DM_R_DAR) == 0x2020, "SAR/DAR advanced by 32");
    CHECK(count(DM_EV_SEV) == 1 && nth(DM_EV_SEV, 0)->e.event_no == 3, "SEV 3");
    CHECK(dma330_reg(m, DM_R_PC) == CODE_BASE + p.n - 1, "CPC at DMAEND");
    dma330_free(m);
}

static void test_unaligned(void)
{
    dma330_t* m = new_model();
    prog_t p = {{0}, 0};
    const rec_t* st;
    unsigned i;
    printf("unaligned INCR source and destination\n");
    /* 13 bytes loaded from 0x1003 (2 beats of 8, first beat short by 3) and
     * stored to 0x2003 the same way: beat0 lanes 3..7, beat1 lanes 0..7 */
    p_mov(&p, 0, 0x1003); p_mov(&p, 2, 0x2003); p_mov(&p, 1, ccr(1, 3, 2, 1, 3, 2, 0));
    p_ld(&p, 0); p_st(&p, 0); p_end(&p);
    CHECK(run(m, &p) == DM_EV_END, "ends");
    CHECK(nth(DM_EV_LD, 0)->e.bytes == 13, "LD moves 13 bytes");
    st = nth(DM_EV_ST, 0);
    CHECK(st->strb[0] == 0xF8 && st->strb[1] == 0xFF, "strobes F8, FF (got %02X, %02X)", st->strb[0], st->strb[1]);
    for (i = 0; i < 5; i++) CHECK(st->data[0][3 + i] == mem_byte(0x1003 + i), "beat0 lane %u", 3 + i);
    for (i = 0; i < 8; i++) CHECK(st->data[1][i] == mem_byte(0x1008 + i), "beat1 lane %u", i);
    CHECK(st->data[0][0] == 0 && st->data[0][2] == 0, "unstrobed lanes are zero");
    CHECK(dma330_reg(m, DM_R_SAR) == 0x1010 && dma330_reg(m, DM_R_DAR) == 0x2010, "SAR/DAR land on the next aligned address");
    dma330_free(m);
}

static void test_fixed(void)
{
    dma330_t* m = new_model();
    prog_t p = {{0}, 0};
    const rec_t *ld, *st;
    printf("FIXED burst\n");
    /* FIXED load at 0x1002, 8-byte beats, 3 beats: every beat reads the 6 bytes
     * 0x1002..0x1007 -> 18 bytes; SAR does not move */
    dma330_free(m);

    m = new_model(); p.n = 0;
    p_mov(&p, 0, 0x1002); p_mov(&p, 2, 0x2000); p_mov(&p, 1, ccr(0, 3, 3, 1, 0, 16, 0));
    p_ld(&p, 0); p_st(&p, 0); p_end(&p);
    CHECK(run(m, &p) == DM_EV_END, "ends");
    ld = nth(DM_EV_LD, 0);
    CHECK(ld->e.bytes == 18 && ld->e.supply_bytes == 6 && !ld->e.inc, "FIXED load: 18 bytes, 6 distinct");
    st = nth(DM_EV_ST, 0);
    CHECK(st->e.nbeats == 16, "16 beats");
    CHECK(dma330_reg(m, DM_R_SAR) == 0x1002, "FIXED source address does not move");
    CHECK(dma330_reg(m, DM_R_DAR) == 0x2010, "INCR destination +16");
    /* stream: [02 03 04 05 06 07] x3; 16 one-byte beats take the first 16 */
    CHECK(st->data[0][0] == mem_byte(0x1002) && st->data[1][1] == mem_byte(0x1003), "stream order");
    CHECK(st->data[6][6] == mem_byte(0x1002), "the second copy of the 6 bytes starts at stream byte 6");
    dma330_free(m);
}

static void test_loops(void)
{
    dma330_t* m = new_model();
    prog_t p = {{0}, 0};
    unsigned outer, inner;
    printf("nested loops\n");
    p_mov(&p, 0, 0x1000); p_mov(&p, 2, 0x2000); p_mov(&p, 1, ccr(1, 3, 1, 1, 3, 1, 0));
    p_lp(&p, 1, 3);
    outer = p_pc(&p);
      p_lp(&p, 0, 4);
      inner = p_pc(&p);
        p_ld(&p, 0); p_st(&p, 0);
      p_lpend(&p, 0, inner, 0);
      p_addh(&p, 0, 0x20);                 /* SAR += 0x20 after each row */
    p_lpend(&p, 1, outer, 0);
    p_end(&p);
    CHECK(run(m, &p) == DM_EV_END, "ends");
    CHECK(count(DM_EV_LD) == 12 && count(DM_EV_ST) == 12, "3 x 4 iterations");
    CHECK(dma330_reg(m, DM_R_LC0) == 0 && dma330_reg(m, DM_R_LC1) == 0, "counters end at 0");
    CHECK(dma330_reg(m, DM_R_SAR) == 0x1000 + 12 * 8 + 3 * 0x20, "SAR after loops");
    CHECK(dma330_reg(m, DM_R_DAR) == 0x2000 + 12 * 8, "DAR after loops");
    CHECK(nth(DM_EV_LD, 4)->e.addr == 0x1000 + 4 * 8 + 0x20, "second row starts after the gap");
    dma330_free(m);
}

static void test_endian(void)
{
    dma330_t* m = new_model();
    prog_t p = {{0}, 0};
    const rec_t* st;
    unsigned k;
    printf("endian swap\n");
    p_mov(&p, 0, 0x1000); p_mov(&p, 2, 0x2000); p_mov(&p, 1, ccr(1, 3, 1, 1, 3, 1, 2));   /* 32-bit */
    p_ld(&p, 0); p_st(&p, 0); p_end(&p);
    CHECK(run(m, &p) == DM_EV_END, "ends");
    st = nth(DM_EV_ST, 0);
    for (k = 0; k < 8; k++) {
        unsigned src = (k & ~3u) + (3 - (k & 3));              /* reverse inside each 4-byte group */
        CHECK(st->data[0][k] == mem_byte(0x1000 + src), "lane %u", k);
    }
    dma330_free(m);

    /* 64-bit swap with two INCR 32-bit beats (TRM 2.11.2: len x size is a
     * multiple of the swap): the 8-byte group spans both beats */
    m = new_model(); p.n = 0;
    p_mov(&p, 0, 0x1000); p_mov(&p, 2, 0x2000); p_mov(&p, 1, ccr(1, 3, 1, 1, 2, 2, 3));
    p_ld(&p, 0); p_st(&p, 0); p_end(&p);
    CHECK(run(m, &p) == DM_EV_END, "64-bit swap over two 32-bit beats is legal");
    st = nth(DM_EV_ST, 0);
    CHECK(st->strb[0] == 0x0F && st->strb[1] == 0xF0, "beat strobes 0x0F, 0xF0");
    for (k = 0; k < 8; k++) {
        unsigned b = k / 4, lane = k;                          /* DAR 0x2000: beat 0 lanes 0-3, beat 1 lanes 4-7 */
        CHECK(st->data[b][lane] == mem_byte(0x1000 + (7 - k)), "group byte %u", k);
    }
    dma330_free(m);

    /* ... but one 32-bit beat holds half a group: illegal -> ch_rdwr_err */
    m = new_model(); p.n = 0;
    p_mov(&p, 0, 0x1000); p_mov(&p, 2, 0x2000); p_mov(&p, 1, ccr(1, 3, 1, 1, 2, 1, 3));
    p_ld(&p, 0); p_st(&p, 0); p_end(&p);
    CHECK(run(m, &p) == DM_EV_FAULT && dma330_reg(m, DM_R_FTR) == (1u << 7), "half a swap group faults");
    dma330_free(m);

    /* FIXED destination: the beat must hold whole groups */
    m = new_model(); p.n = 0;
    p_mov(&p, 0, 0x1000); p_mov(&p, 2, 0x2000); p_mov(&p, 1, ccr(1, 3, 1, 0, 2, 2, 3));
    p_ld(&p, 0); p_st(&p, 0); p_end(&p);
    CHECK(run(m, &p) == DM_EV_FAULT && dma330_reg(m, DM_R_FTR) == (1u << 7), "FIXED beat narrower than the swap faults");
    dma330_free(m);

    /* Table 3-22: swap can be wider than the AXI bus. */
    m = new_model(); p.n = 0;
    p_mov(&p, 0, 0x1000); p_mov(&p, 2, 0x2000); p_mov(&p, 1, ccr(1, 3, 2, 1, 3, 2, 4));
    p_ld(&p, 0); p_st(&p, 0); p_end(&p);
    CHECK(run(m, &p) == DM_EV_END, "128-bit swap on a 64-bit bus is legal");
    st = nth(DM_EV_ST, 0);
    for (k=0;k<16;k++)
        CHECK(st && st->data[k/8][k%8] == mem_byte(0x1000+15-k), "128-bit swap byte %u",k);
    dma330_free(m);

    /* DAR not aligned to the swap group */
    m = new_model(); p.n = 0;
    p_mov(&p, 0, 0x1000); p_mov(&p, 2, 0x2002); p_mov(&p, 1, ccr(1, 3, 1, 1, 3, 1, 2));
    p_ld(&p, 0); p_st(&p, 0); p_end(&p);
    CHECK(run(m, &p) == DM_EV_FAULT && (dma330_reg(m, DM_R_FTR) & (1u << 7)), "unaligned DAR faults");
    dma330_free(m);

    /* DMASTZ ignores the swap field, even an illegal one */
    m = new_model(); p.n = 0;
    p_mov(&p, 2, 0x2002); p_mov(&p, 1, ccr(1, 3, 1, 1, 3, 1, 7));
    p_stz(&p); p_end(&p);
    CHECK(run(m, &p) == DM_EV_END, "DMASTZ ignores swap");
    st = nth(DM_EV_STZ, 0);
    CHECK(st->strb[0] == 0xFC && st->data[0][5] == 0, "STZ unaligned strobes, zero data");
    dma330_free(m);
}

static void set_reqs(unsigned n, const unsigned r[][3])
{
    unsigned i;
    g_nreq = n;
    for (i = 0; i < n; i++) { g_reqs[i].per = r[i][0]; g_reqs[i].burst = r[i][1]; g_reqs[i].last = r[i][2]; }
}

static void test_conditions(void)
{
    dma330_t* m = new_model();
    prog_t p = {{0}, 0};
    unsigned body;
    /* P1 raises: burst, single, burst(last) */
    static const unsigned reqs[3][3] = { {1, 1, 0}, {1, 0, 0}, {1, 1, 1} };
    printf("S/B conditions, DMALPFE, peripheral acknowledges\n");
    /* flush; loop { WFP P1 ; LDS ; LDB ; STPS ; STPB } until a request is flagged last */
    p_flushp(&p, 1);
    p_mov(&p, 0, 0x1000); p_mov(&p, 2, 0x4000); p_mov(&p, 1, ccr(1, 3, 2, 0, 3, 2, 0));
    body = p_pc(&p);
      p_wfp(&p, 1, 1);
      p_ld(&p, 1); p_ld(&p, 3);
      p_stp(&p, 0, 1); p_stp(&p, 1, 1);
    p_lpfe(&p, body);
    p_end(&p);
    set_reqs(3, reqs);
    CHECK(run(m, &p) == DM_EV_END, "DMALPFE ends on the request flagged last (kind %d)", (int)g_last);
    set_reqs(0, reqs);
    CHECK(count(DM_EV_LD) == 3 && count(DM_EV_ST) == 3, "one load and one store per request");
    /* acknowledges in program order: flush, then B, S, B */
    CHECK(count(DM_EV_ACK) == 4, "4 acknowledges (got %u)", count(DM_EV_ACK));
    CHECK(nth(DM_EV_ACK, 0)->e.ack == DM_ACK_FLUSH, "flush first");
    CHECK(nth(DM_EV_ACK, 1)->e.ack == DM_ACK_BURST, "request 1 (burst) -> STPB ack");
    CHECK(nth(DM_EV_ACK, 2)->e.ack == DM_ACK_SINGLE, "request 2 (single) -> STPS ack");
    CHECK(nth(DM_EV_ACK, 3)->e.ack == DM_ACK_BURST, "request 3 (burst) -> STPB ack");
    CHECK(nth(DM_EV_ACK, 1)->e.periph == 1, "ack goes to P1");
    CHECK(dma330_reg(m, DM_R_DAR) == 0x4000, "FIXED destination does not move");
    /* S forms move one beat (AxLEN = 0), B forms the CCR burst */
    CHECK(nth(DM_EV_LD, 0)->e.len == 1 && nth(DM_EV_LD, 1)->e.len == 0 && nth(DM_EV_LD, 2)->e.len == 1,
          "LDB 2 beats, LDS 1 beat (len %u %u %u)", nth(DM_EV_LD, 0)->e.len, nth(DM_EV_LD, 1)->e.len,
          nth(DM_EV_LD, 2)->e.len);
    CHECK(nth(DM_EV_ST, 1)->e.len == 0 && nth(DM_EV_ST, 1)->e.bytes == 8, "STPS 1 beat of 8 bytes");
    CHECK(dma330_reg(m, DM_R_SAR) == 0x1000 + 16 + 8 + 16, "SAR advanced by 16 + 8 + 16");
    dma330_free(m);
}

/* DMAWFP single / burst (TRM 2.6.5) */
static void test_wfp_kinds(void)
{
    dma330_t* m = new_model();
    prog_t p = {{0}, 0};
    /* P0 raises: single, burst */
    static const unsigned r_sb[2][3] = { {0, 0, 0}, {0, 1, 1} };
    /* P0 raises: burst(last) */
    static const unsigned r_b[1][3]  = { {0, 1, 1} };
    printf("DMAWFP single / burst / periph\n");

    /* WFP burst discards the single request and keeps waiting, then takes the
     * burst one (request_type burst): LDB/STB run, LDS/STS are NOPs. The
     * second WFP burst finds no request and starves */
    p.n = 0; p_mov(&p, 0, 0x1000); p_mov(&p, 2, 0x2000); p_mov(&p, 1, ccr(1, 3, 2, 1, 3, 2, 0));
    p_wfp(&p, 0, 2); p_ld(&p, 3); p_st(&p, 3); p_ld(&p, 1); p_st(&p, 1); p_wfp(&p, 0, 2); p_end(&p);
    set_reqs(2, r_sb);
    CHECK(run(m, &p) == DM_EV_STARVED, "second DMAWFP B starves (kind %d)", (int)g_last);
    CHECK(count(DM_EV_LD) == 1 && nth(DM_EV_LD, 0)->e.len == 1, "one burst load: the single request was dropped");

    /* WFP single with a burst request pending: continues as single, the
     * burst request stays for the following DMAWFP periph */
    p.n = 0; p_mov(&p, 0, 0x1000); p_mov(&p, 2, 0x2000); p_mov(&p, 1, ccr(1, 3, 2, 1, 3, 2, 0));
    p_wfp(&p, 0, 0); p_ld(&p, 1); p_st(&p, 1); p_ld(&p, 3); p_st(&p, 3);
    p_wfp(&p, 0, 1); p_ld(&p, 3); p_st(&p, 3); p_end(&p);
    set_reqs(1, r_b);
    CHECK(run(m, &p) == DM_EV_END, "ends (kind %d)", (int)g_last);
    CHECK(count(DM_EV_LD) == 2 && nth(DM_EV_LD, 0)->e.len == 0 && nth(DM_EV_LD, 1)->e.len == 1,
          "single (WFP S) then burst (WFP P) on the same request");
    set_reqs(0, r_b);
    dma330_free(m);
}

static void test_ldp_ack_order(void)
{
    dma330_t* m = new_model();
    prog_t p = {{0}, 0};
    printf("DMALDP acknowledge follows its load\n");
    p_mov(&p, 0, 0x1000); p_mov(&p, 2, 0x2000); p_mov(&p, 1, ccr(1, 3, 1, 1, 3, 1, 0));
    p_wfp(&p, 2, 2);                                    /* DMAWFP B: request_type = burst */
    p_ldp(&p, 1, 2); p_st(&p, 0); p_end(&p);
    g_reqs[0].per = 2; g_reqs[0].burst = 1; g_reqs[0].last = 0; g_nreq = 1;
    CHECK(run(m, &p) == DM_EV_END, "ends");
    g_nreq = 0;
    CHECK(g_ev[0].e.kind == DM_EV_LD && g_ev[1].e.kind == DM_EV_ACK && g_ev[2].e.kind == DM_EV_ST,
          "order LD, ACK, ST (got %d %d %d)", g_ev[0].e.kind, g_ev[1].e.kind, g_ev[2].e.kind);
    CHECK(g_ev[1].e.periph == 2 && g_ev[1].e.ack == DM_ACK_BURST, "burst ack to P2");
    dma330_free(m);
}

static void test_loop_conditions(void)
{
    dma330_t* m = new_model();
    prog_t p = {{0}, 0};
    unsigned body;
    static const unsigned reqs[1][3] = { {0, 1, 0} };
    printf("DMALPENDS / DMALPENDB\n");
    p_mov(&p, 0, 0x1000); p_mov(&p, 2, 0x2000); p_mov(&p, 1, ccr(1, 3, 1, 1, 3, 1, 0));
    p_wfp(&p, 0, 0);                                    /* DMAWFP S: request_type becomes single */
    p_lp(&p, 0, 3);
    body = p_pc(&p);
      p_ld(&p, 0); p_st(&p, 0);
    p_lpend(&p, 0, body, 1);                            /* DMALPENDS: condition true -> loops */
    p_lp(&p, 1, 3);
    body = p_pc(&p);
      p_ld(&p, 0); p_st(&p, 0);
    p_lpend(&p, 1, body, 3);                            /* DMALPENDB: condition false -> NOP */
    p_end(&p);
    set_reqs(1, reqs);                                  /* a burst request, but DMAWFP S says single */
    CHECK(run(m, &p) == DM_EV_END, "ends");
    set_reqs(0, reqs);
    CHECK(count(DM_EV_LD) == 3 + 1 && count(DM_EV_ST) == 3 + 1,
          "3 passes for the S loop, 1 for the B loop (got %u loads)", count(DM_EV_LD));
    CHECK(dma330_reg(m, DM_R_LC0) == 0, "LC0 counted down to 0");
    CHECK(dma330_reg(m, DM_R_LC1) == 2, "LC1 untouched by the false condition");
    dma330_free(m);
}

static void test_zero_and_regs(void)
{
    dma330_t* m = new_model();
    prog_t p = {{0}, 0};
    printf("DMASTZ, DMAADDH / DMAADNH, DMAKILL\n");
    p_mov(&p, 2, 0x2000); p_mov(&p, 1, ccr(1, 3, 2, 1, 3, 2, 0));
    p_stz(&p); p_stz(&p);
    p_addh(&p, 1, 0x100); p_adnh(&p, 1, 0xFFF0);        /* +0x100 then -0x10 */
    p_nop(&p); p_kill(&p);
    CHECK(run(m, &p) == DM_EV_KILL, "DMAKILL ends the program");
    CHECK(count(DM_EV_STZ) == 2 && nth(DM_EV_STZ, 1)->e.addr == 0x2010, "two zero bursts of 16 bytes");
    CHECK(dma330_reg(m, DM_R_DAR) == 0x2000 + 32 + 0x100 - 0x10, "DAR arithmetic");
    CHECK(!dma330_reg_valid(m, DM_R_SAR), "SAR never written: invalid");
    CHECK(dma330_reg_valid(m, DM_R_DAR), "DAR written: valid");
    dma330_free(m);

    m = new_model(); p.n = 0;
    p_mov(&p, 0, 0x10); p_adnh(&p, 0, 0xFFF0); p_end(&p);       /* 0x10 + 0xFFFFFFF0 wraps to 0 */
    CHECK(run(m, &p) == DM_EV_END && dma330_reg(m, DM_R_SAR) == 0, "32-bit wrap-around");
    dma330_free(m);

    m = new_model(); p.n = 0;
    p_mov(&p, 0, 0xFFFFF000u); p_mov(&p, 1, ccr(1, 3, 16, 1, 3, 16, 0));
    p_ld(&p, 0); p_end(&p);
    CHECK(run(m, &p) == DM_EV_END && dma330_reg(m, DM_R_SAR) == 0xFFFFF080u, "top-of-memory page");
    dma330_free(m);
}

static void test_faults(void)
{
    dma330_t* m = new_model();
    prog_t p = {{0}, 0};
    printf("faults\n");

    p.n = 0; put(&p, 0x18); put(&p, 0xFF);
    CHECK(run(m, &p) == DM_EV_FAULT && dma330_reg(m, DM_R_FTR) == 1 && dma330_reg(m, DM_R_PC) == CODE_BASE + 1,
          "undefined opcode: bit 0, CPC at the opcode");

    p.n = 0; put(&p, 0xA0); put(&p, 0); put(&p, 0); put(&p, 0); put(&p, 0); put(&p, 0);
    CHECK(run(m, &p) == DM_EV_FAULT && dma330_reg(m, DM_R_FTR) == 1, "DMAGO inside a channel: undef_instr");

    p.n = 0; put(&p, 0xBC); put(&p, 3); put(&p, 0); put(&p, 0); put(&p, 0); put(&p, 0);
    CHECK(run(m, &p) == DM_EV_FAULT && dma330_reg(m, DM_R_FTR) == 2, "DMAMOV register 3: operand_invalid");

    /* numbers the configuration does not have: invalid operand (FTR bit 1) */
    p.n = 0; p_sev(&p, 16);
    CHECK(run(m, &p) == DM_EV_FAULT && dma330_reg(m, DM_R_FTR) == (1u << 1), "event 16 of 16: operand_invalid");
    p.n = 0; p_sev(&p, 15); p_end(&p);
    CHECK(run(m, &p) == DM_EV_END, "event 15 is legal");

    p.n = 0; p_wfp(&p, 4, 2);
    CHECK(run(m, &p) == DM_EV_FAULT && dma330_reg(m, DM_R_FTR) == (1u << 1), "DMAWFP P4 of 4: operand_invalid");
    p.n = 0; p_flushp(&p, 5);
    CHECK(run(m, &p) == DM_EV_FAULT && dma330_reg(m, DM_R_FTR) == (1u << 1), "DMAFLUSHP P5: operand_invalid");
    p.n = 0; p_mov(&p, 0, 0x1000); p_mov(&p, 1, ccr(1, 3, 1, 1, 3, 1, 0)); p_ldp(&p, 0, 6);
    CHECK(run(m, &p) == DM_EV_FAULT && dma330_reg(m, DM_R_FTR) == (1u << 1), "DMALDP P6: operand_invalid");

    /* A burst crossing 4 KB is legal: the data path splits it in two AXI
     * bursts (the model reports the instruction's burst) */
    p.n = 0; p_mov(&p, 0, 0x1FF8); p_mov(&p, 1, ccr(1, 3, 2, 1, 3, 2, 0)); p_ld(&p, 0); p_end(&p);
    CHECK(run(m, &p) == DM_EV_END, "INCR load across 4 KB is legal");
    CHECK(count(DM_EV_LD) == 1 && nth(DM_EV_LD, 0)->e.addr == 0x1FF8 && nth(DM_EV_LD, 0)->e.len == 1,
          "one LD event of 2 beats from 0x1FF8");
    CHECK(dma330_reg(m, DM_R_SAR) == 0x2008, "SAR advanced across the boundary");
    p.n = 0; p_mov(&p, 0, 0x1FF8); p_mov(&p, 1, ccr(0, 3, 4, 1, 3, 2, 0)); p_ld(&p, 0); p_end(&p);
    CHECK(run(m, &p) == DM_EV_END, "FIXED burst never crosses");
    p.n = 0; p_mov(&p, 0, 0x1FFC); p_mov(&p, 1, ccr(1, 3, 2, 1, 3, 2, 0)); p_ld(&p, 0); p_end(&p);
    CHECK(run(m, &p) == DM_EV_END && nth(DM_EV_LD, 0)->e.bytes == 12, "unaligned crossing load: 12 bytes");
    p.n = 0; p_mov(&p, 0, 0x1000); p_mov(&p, 1, ccr(1, 4, 1, 1, 3, 1, 0)); p_ld(&p, 0);
    CHECK(run(m, &p) == DM_EV_FAULT && dma330_reg(m, DM_R_FTR) == (1u << 7), "burst wider than the 8-byte bus");

    p.n = 0; p_mov(&p, 0, 0x1000); p_mov(&p, 1, ccr(1, 3, 16, 1, 3, 16, 0)); p_ld(&p, 0); p_ld(&p, 0); p_ld(&p, 0);
    CHECK(run(m, &p) == DM_EV_FAULT && dma330_reg(m, DM_R_FTR) == (1u << 12), "3 x 128 B into a 256 B MFIFO: mfifo_err");
    CHECK(count(DM_EV_LD) == 2, "two loads issued before the fault");
    CHECK(dma330_reg(m, DM_R_PC) == CODE_BASE + 6 + 6 + 1 + 1, "CPC at the third load");

    p.n = 0; p_mov(&p, 2, 0x2000); p_mov(&p, 1, ccr(1, 3, 16, 1, 3, 16, 0)); p_st(&p, 0);
    CHECK(run(m, &p) == DM_EV_FAULT && dma330_reg(m, DM_R_FTR) == (1u << 13), "store without data: st_data_unavailable");

    p.n = 0; p_mov(&p, 0, 0x1000); p_mov(&p, 2, 0x2000); p_mov(&p, 1, ccr(1, 3, 2, 1, 3, 3, 0)); p_ld(&p, 0); p_st(&p, 0);
    CHECK(run(m, &p) == DM_EV_FAULT && dma330_reg(m, DM_R_FTR) == (1u << 13), "24-byte store, 16 loaded");

    /* both a 4 KB crossing (legal) and a lock-up: mfifo_err */
    p.n = 0; p_mov(&p, 0, 0x1000); p_mov(&p, 1, ccr(1, 3, 16, 1, 3, 16, 0)); p_ld(&p, 0); p_ld(&p, 0);
    p_mov(&p, 0, 0x1F80 + 0x40); p_ld(&p, 0);
    CHECK(run(m, &p) == DM_EV_FAULT, "faults");
    CHECK(dma330_reg(m, DM_R_FTR) == (1u << 12) && dma330_reg(m, DM_R_FTR_MAYBE) == 0,
          "mfifo_err only (FTR=%x maybe=%x)", dma330_reg(m, DM_R_FTR), dma330_reg(m, DM_R_FTR_MAYBE));

    /* store cache attributes: CCR[27:25] -> AWCACHE[3,1,0], AWCACHE[2] = 0 */
    p.n = 0; p_mov(&p, 0, 0x1000); p_mov(&p, 2, 0x2000);
    p_mov(&p, 1, ccr(1, 3, 1, 1, 3, 1, 0) | (7u << 25) | (5u << 11)); p_ld(&p, 0); p_st(&p, 0); p_end(&p);
    CHECK(run(m, &p) == DM_EV_END, "ends");
    CHECK(nth(DM_EV_LD, 0)->e.cache == 5 && nth(DM_EV_ST, 0)->e.cache == 0xB,
          "ARCACHE 0x5, AWCACHE 0xB (got 0x%x 0x%x)", nth(DM_EV_LD, 0)->e.cache, nth(DM_EV_ST, 0)->e.cache);

    /* a condition that is false never faults */
    p.n = 0; p_mov(&p, 2, 0x2000); p_mov(&p, 1, ccr(1, 3, 16, 1, 3, 16, 0)); p_st(&p, 3); p_end(&p);
    CHECK(run(m, &p) == DM_EV_END, "DMASTB with request_type single is a NOP");

    dma330_free(m);
}

/* Shared MFIFO of 32 lines x 8 bytes: lock-up counted in lines */
static void test_mfifo_lines(void)
{
    dma330_t* m = new_model();
    prog_t p = {{0}, 0};
    printf("shared MFIFO: line accounting\n");

    /* 256 B loaded, all stored, then another 256 B: an empty stream holds no line */
    p.n = 0; p_mov(&p, 0, 0x1000); p_mov(&p, 2, 0x3000); p_mov(&p, 1, ccr(1, 3, 16, 1, 3, 16, 0));
    p_ld(&p, 0); p_ld(&p, 0); p_st(&p, 0); p_st(&p, 0); p_ld(&p, 0); p_ld(&p, 0); p_st(&p, 0); p_st(&p, 0); p_end(&p);
    CHECK(run(m, &p) == DM_EV_END, "pool reused after the stream drained");

    /* exactly the pool, aligned: fits */
    p.n = 0; p_mov(&p, 0, 0x1000); p_mov(&p, 1, ccr(1, 3, 16, 1, 3, 1, 0));
    p_ld(&p, 0); p_ld(&p, 0); p_end(&p);
    CHECK(run(m, &p) == DM_EV_END, "two 128 B loads fill the 256 B pool exactly");

    /* one byte more than the pool: lock-up */
    p.n = 0; p_mov(&p, 0, 0x1000); p_mov(&p, 1, ccr(1, 3, 16, 1, 3, 1, 0));
    p_ld(&p, 0); p_ld(&p, 0); p_mov(&p, 1, ccr(1, 0, 1, 1, 3, 1, 0)); p_ld(&p, 0);
    CHECK(run(m, &p) == DM_EV_FAULT && dma330_reg(m, DM_R_FTR) == (1u << 12), "257 B: mfifo_err");

    /* 11 B loaded, 3 B stored: the oldest byte sits at line offset 3, so
     * 8 + 128 + 128 bytes need ceil((3 + 264) / 8) = 34 lines: lock-up */
    p.n = 0; p_mov(&p, 0, 0x1000); p_mov(&p, 2, 0x3000);
    p_mov(&p, 1, ccr(1, 0, 11, 1, 0, 3, 0)); p_ld(&p, 0); p_st(&p, 0);
    p_mov(&p, 0, 0x2000); p_mov(&p, 1, ccr(1, 3, 16, 1, 3, 1, 0)); p_ld(&p, 0); p_ld(&p, 0);
    CHECK(run(m, &p) == DM_EV_FAULT && dma330_reg(m, DM_R_FTR) == (1u << 12), "line offset 3, 264 B: mfifo_err");
    CHECK(count(DM_EV_LD) == 2, "the first 128 B load fits (18 lines)");

    /* 3 B loaded and stored: the stream is empty at offset 3. If the store
     * drains before the next load is accepted the stream restarts at offset 0
     * (256 B fit in 32 lines), otherwise it continues at 3 (33 lines) */
    p.n = 0; p_mov(&p, 0, 0x1000); p_mov(&p, 2, 0x3000);
    p_mov(&p, 1, ccr(1, 0, 3, 1, 0, 3, 0)); p_ld(&p, 0); p_st(&p, 0);
    p_mov(&p, 0, 0x2000); p_mov(&p, 1, ccr(1, 3, 16, 1, 3, 1, 0)); p_ld(&p, 0); p_ld(&p, 0); p_end(&p);
    CHECK(run(m, &p) == DM_EV_UNSURE, "lock-up depends on timing");
    CHECK(count(DM_EV_LD) == 2 && count(DM_EV_ST) == 1, "stops before the uncertain load");
    dma330_free(m);
}

/* CR3 / CR4: a non-secure thread may only use non-secure events / peripherals */
static void test_security(void)
{
    dma330_t* m = new_model();
    prog_t p = {{0}, 0};
    printf("security: events and peripherals of non-secure threads\n");
    dma330_security(m, 0x00FFu, 0x3u);

    g_ns = 1;
    p.n = 0; p_sev(&p, 3); p_flushp(&p, 1); p_end(&p);
    CHECK(run(m, &p) == DM_EV_END, "NS thread: NS event 3, NS peripheral 1");
    p.n = 0; p_sev(&p, 9);
    CHECK(run(m, &p) == DM_EV_FAULT && dma330_reg(m, DM_R_FTR) == (1u << 5), "NS thread, DMASEV 9 (secure): ch_evnt_err");
    p.n = 0; put(&p, 0x36); put(&p, 9 << 3);
    CHECK(run(m, &p) == DM_EV_FAULT && dma330_reg(m, DM_R_FTR) == (1u << 5), "NS thread, DMAWFE 9: ch_evnt_err");
    p.n = 0; p_wfp(&p, 2, 0);
    CHECK(run(m, &p) == DM_EV_FAULT && dma330_reg(m, DM_R_FTR) == (1u << 6), "NS thread, DMAWFP P2 (secure): ch_periph_err");
    p.n = 0; p_flushp(&p, 3);
    CHECK(run(m, &p) == DM_EV_FAULT && dma330_reg(m, DM_R_FTR) == (1u << 6), "NS thread, DMAFLUSHP P3: ch_periph_err");
    p.n = 0; p_mov(&p, 0, 0x1000); p_mov(&p, 1, ccr(1, 3, 1, 1, 3, 1, 0) | (2u << 8) | (2u << 22)); p_ldp(&p, 0, 2);
    CHECK(run(m, &p) == DM_EV_FAULT && dma330_reg(m, DM_R_FTR) == (1u << 6), "NS thread, DMALDP P2: ch_periph_err");
    /* a non-secure thread may not ask for a secure access (prot[1] = 0) */
    p.n = 0; p_mov(&p, 0, 0x1000); p_mov(&p, 1, ccr(1, 3, 1, 1, 3, 1, 0)); p_ld(&p, 0);
    CHECK(run(m, &p) == DM_EV_FAULT && dma330_reg(m, DM_R_FTR) == (1u << 7), "NS thread, secure read: ch_rdwr_err");
    CHECK(dma330_reg(m, DM_R_PC) == CODE_BASE + 6, "NS security abort is precise at DMAMOV CCR");
    p.n = 0; p_mov(&p, 2, 0x2000); p_mov(&p, 1, ccr(1, 3, 1, 1, 3, 1, 0) | (2u << 8)); p_stz(&p);
    CHECK(run(m, &p) == DM_EV_FAULT && dma330_reg(m, DM_R_FTR) == (1u << 7), "NS thread, secure write: ch_rdwr_err");
    p.n = 0; p_mov(&p, 0, 0x1000); p_mov(&p, 2, 0x2000);
    p_mov(&p, 1, ccr(1, 3, 1, 1, 3, 1, 0) | (2u << 8) | (2u << 22)); p_ld(&p, 0); p_st(&p, 0); p_end(&p);
    CHECK(run(m, &p) == DM_EV_END, "NS thread, non-secure accesses");
    CHECK(nth(DM_EV_LD, 0)->e.prot == 2 && nth(DM_EV_ST, 0)->e.prot == 2, "AxPROT = CCR prot");

    g_ns = 0;
    p.n = 0; p_sev(&p, 9); p_flushp(&p, 3); p_end(&p);
    CHECK(run(m, &p) == DM_EV_END, "secure thread: secure event and peripheral");
    dma330_free(m);
}

static void test_protocol(void)
{
    dma330_t* m = new_model();
    prog_t p = {{0}, 0};
    dm_ev_kind_t k;
    printf("protocol: unknown registers, starvation, run-away\n");

    p.n = 0; p_ld(&p, 0);
    CHECK(run(m, &p) == DM_EV_UNKNOWN, "load before DMAMOV SAR/CCR is reported");

    p.n = 0; p_wfp(&p, 0, 2); p_end(&p);
    CHECK(run(m, &p) == DM_EV_STARVED, "DMAWFP without a queued request starves");
    dma330_periph_req(m, 0, 1, 0);                          /* resume after the request arrives */
    {
        for (;;) {
            k = dma330_step(m);
            if (k == DM_EV_NEED_CODE) { const dm_event_t* e = dma330_event(m); supply_mem(m, e->supply_addr, e->supply_bytes, &p); continue; }
            break;
        }
        CHECK(k == DM_EV_END, "resumes at the DMAWFP once the request is queued (kind %d)", (int)k);
    }

    p.n = 0; put(&p, 0x28); put(&p, 0);                        /* DMALPFE with jump 0: loops forever */
    CHECK(run(m, &p) == DM_EV_RUNAWAY, "endless loop stops at the instruction budget");
    dma330_free(m);
}

int main(void)
{
    test_aligned_copy();
    test_unaligned();
    test_fixed();
    test_loops();
    test_endian();
    test_conditions();
    test_wfp_kinds();
    test_ldp_ack_order();
    test_loop_conditions();
    test_zero_and_regs();
    test_faults();
    test_mfifo_lines();
    test_security();
    test_protocol();
    printf("\n%d checks, %d failed\n", g_checks, g_fail);
    printf(g_fail ? "*** MODEL TEST FAILED ***\n" : "*** MODEL TEST PASSED ***\n");
    return g_fail ? 1 : 0;
}
