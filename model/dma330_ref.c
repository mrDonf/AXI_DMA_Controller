/*==============================================================================
 * dma330_ref.c - C reference model of one AXI DMA channel thread
 * See dma330_ref.h for the interface and the contract.
 *============================================================================*/
#include "dma330_ref.h"

#include <stdlib.h>
#include <string.h>

#define SUPPLY_MAX   512
#define CODE_LINE    32            /* bytes asked for on an instruction miss */
#define DEF_MAX_INSN 100000UL

/* Fault bits of FTRn (dma330_pkg.sv, FTC_*) */
#define FT_UNDEF_INSTR      (1u << 0)
#define FT_OPERAND_INVALID  (1u << 1)
#define FT_CH_EVNT_ERR      (1u << 5)
#define FT_CH_PERIPH_ERR    (1u << 6)
#define FT_CH_RDWR_ERR      (1u << 7)
#define FT_MFIFO_ERR        (1u << 12)
#define FT_ST_DATA_UNAVAIL  (1u << 13)

typedef enum {
    I_UNDEF, I_END, I_KILL, I_NOP, I_RMB, I_WMB, I_LD, I_ST, I_STZ, I_LDP, I_STP,
    I_LP, I_LPEND, I_WFP, I_SEV, I_FLUSHP, I_WFE, I_ADDH, I_ADNH, I_MOV, I_GO
} insn_t;

typedef enum { PEND_NONE = 0, PEND_CODE, PEND_LD } pend_t;

struct dma330 {
    dma330_cfg_t cfg;
    unsigned     max_size;               /* log2(bus_bytes)                    */
    unsigned long max_insns;

    /* architectural state */
    uint32_t pc, sar, dar, ccr;
    uint8_t  lc0, lc1;
    uint32_t valid;                      /* bit r: register r holds a known value */
    int      ns, req_burst, req_last;
    uint32_t ftr, ftr_maybe, events;
    int      running;
    unsigned long insns;

    /* peripheral requests raised by the testbench, consumed by DMAWFP */
    struct { uint8_t burst, last; } req[DM_MAX_PERIPH][DM_REQ_DEPTH];
    unsigned req_n[DM_MAX_PERIPH], req_rd[DM_MAX_PERIPH];

    /* bytes loaded and not yet stored (= "unclaimed" in the data path) */
    uint8_t  stream[DM_STREAM_BYTES + 256];
    unsigned stream_len;

    /* instruction bytes supplied so far */
    struct { uint32_t base; unsigned len; uint8_t d[DM_CODE_SEG_BYTES]; } seg[DM_CODE_SEGS];
    unsigned nseg;

    /* supply buffer + pending request */
    uint8_t  sup[SUPPLY_MAX];
    unsigned sup_n;
    pend_t   pend;
    unsigned pend_need;

    /* acknowledge that follows the LD/ST event just returned */
    int      ack_pending;
    unsigned ack_periph;
    dm_ack_t ack_type;

    dm_event_t ev;
    uint8_t    beat_data[DM_MAX_BEATS][DM_MAX_BUS_BYTES];
    uint32_t   beat_strb[DM_MAX_BEATS];
};

/*------------------------------------------------------------------------------
 * Burst arithmetic (dma330_pkg.sv)
 *----------------------------------------------------------------------------*/
unsigned dm_burst_bytes(uint32_t addr, unsigned size, unsigned len, unsigned inc)
{
    unsigned beats = len + 1;
    unsigned sz    = 1u << size;
    unsigned off   = addr & (sz - 1);
    return inc ? beats * sz - off : beats * (sz - off);
}

int dm_crosses_4k(uint32_t addr, unsigned size, unsigned len, unsigned inc)
{
    unsigned start = (addr & 0xFFFu) & ~((1u << size) - 1u);
    unsigned span  = (len + 1u) << size;
    return inc && (start + span) > 4096u;
}

/*------------------------------------------------------------------------------
 * Decode (dma330_pkg.sv, decode_op / insn_len)
 *----------------------------------------------------------------------------*/
static insn_t decode_op(uint8_t op)
{
    switch (op) {
    case 0x00: return I_END;
    case 0x01: return I_KILL;
    case 0x04: case 0x05: case 0x07: return I_LD;
    case 0x08: case 0x09: case 0x0B: return I_ST;
    case 0x0C: return I_STZ;
    case 0x12: return I_RMB;
    case 0x13: return I_WMB;
    case 0x18: return I_NOP;
    case 0x20: case 0x22: return I_LP;
    case 0x25: case 0x27: return I_LDP;
    case 0x29: case 0x2B: return I_STP;
    case 0x28: case 0x2A: return I_LPEND;
    case 0x30: case 0x31: case 0x32: return I_WFP;
    case 0x34: return I_SEV;
    case 0x35: return I_FLUSHP;
    case 0x36: return I_WFE;
    case 0x54: case 0x56: return I_ADDH;
    case 0x5C: case 0x5E: return I_ADNH;
    case 0xBC: return I_MOV;
    case 0xA0: case 0xA2: return I_GO;
    default: break;
    }
    if ((op & 0xFC) == 0x2C) return I_LPEND;     /* 0010_11?? */
    if ((op & 0xF8) == 0x38) return I_LPEND;     /* 0011_1??? */
    return I_UNDEF;
}

static unsigned insn_len(uint8_t op)
{
    switch (decode_op(op)) {
    case I_LP: case I_LDP: case I_STP: case I_LPEND: case I_WFP:
    case I_SEV: case I_FLUSHP: case I_WFE:   return 2;
    case I_ADDH: case I_ADNH:                return 3;
    case I_MOV: case I_GO:                   return 6;
    default:                                 return 1;
    }
}

/*------------------------------------------------------------------------------
 * CCR fields
 *----------------------------------------------------------------------------*/
#define CCR_SRC_INC(c)   ((c) & 1u)
#define CCR_SRC_SIZE(c)  (((c) >> 1) & 7u)
#define CCR_SRC_LEN(c)   (((c) >> 4) & 15u)
#define CCR_SRC_PROT(c)  (((c) >> 8) & 7u)
#define CCR_SRC_CACHE(c) (((c) >> 11) & 7u)
#define CCR_DST_INC(c)   (((c) >> 14) & 1u)
#define CCR_DST_SIZE(c)  (((c) >> 15) & 7u)
#define CCR_DST_LEN(c)   (((c) >> 18) & 15u)
#define CCR_DST_PROT(c)  (((c) >> 22) & 7u)
#define CCR_DST_CACHE(c) (((c) >> 25) & 7u)
#define CCR_SWAP(c)      (((c) >> 28) & 7u)

#define VALID(m, r)      (((m)->valid >> (r)) & 1u)
#define SET_VALID(m, r)  ((m)->valid |= 1u << (r))

/*------------------------------------------------------------------------------
 * Construction
 *----------------------------------------------------------------------------*/
dma330_t* dma330_new(const dma330_cfg_t* cfg)
{
    dma330_t* m;
    if (!cfg || cfg->bus_bytes == 0 || cfg->bus_bytes > DM_MAX_BUS_BYTES ||
        (cfg->bus_bytes & (cfg->bus_bytes - 1)) != 0 ||
        cfg->num_periph > DM_MAX_PERIPH || cfg->mfifo_bytes > DM_STREAM_BYTES)
        return NULL;
    m = (dma330_t*)calloc(1, sizeof *m);
    if (!m) return NULL;
    m->cfg = *cfg;
    while ((1u << m->max_size) < cfg->bus_bytes) m->max_size++;
    m->max_insns = cfg->max_insns ? cfg->max_insns : DEF_MAX_INSN;
    return m;
}

void dma330_free(dma330_t* m) { free(m); }

void dma330_go(dma330_t* m, uint32_t pc, int ns)
{
    unsigned p;
    m->pc = pc;
    m->ns = ns != 0;
    m->sar = m->dar = m->ccr = 0;
    m->lc0 = m->lc1 = 0;
    m->valid = 0;
    m->req_burst = m->req_last = 0;
    m->ftr = m->ftr_maybe = m->events = 0;
    m->running = 1;
    m->insns = 0;
    m->stream_len = 0;
    m->nseg = 0;
    m->sup_n = 0;
    m->pend = PEND_NONE;
    m->ack_pending = 0;
    for (p = 0; p < DM_MAX_PERIPH; p++) m->req_n[p] = m->req_rd[p] = 0;
    memset(&m->ev, 0, sizeof m->ev);
}

void dma330_periph_req(dma330_t* m, unsigned periph, int burst, int last)
{
    unsigned n;
    if (periph >= DM_MAX_PERIPH) return;
    n = m->req_n[periph];
    if (n >= DM_REQ_DEPTH) return;
    m->req[periph][n].burst = burst != 0;
    m->req[periph][n].last  = last != 0;
    m->req_n[periph] = n + 1;
}

void dma330_supply(dma330_t* m, const uint8_t* bytes, unsigned n)
{
    if (n > SUPPLY_MAX - m->sup_n) n = SUPPLY_MAX - m->sup_n;
    memcpy(m->sup + m->sup_n, bytes, n);
    m->sup_n += n;
}

/*------------------------------------------------------------------------------
 * Instruction bytes
 *----------------------------------------------------------------------------*/
static int code_byte(const dma330_t* m, uint32_t a, uint8_t* out)
{
    unsigned i;
    for (i = 0; i < m->nseg; i++) {
        uint32_t d = a - m->seg[i].base;
        if (d < m->seg[i].len) { *out = m->seg[i].d[d]; return 1; }
    }
    return 0;
}

static void install_code(dma330_t* m, uint32_t base, const uint8_t* b, unsigned n)
{
    unsigned i = (m->nseg < DM_CODE_SEGS) ? m->nseg++ : (unsigned)(m->insns % DM_CODE_SEGS);
    if (n > DM_CODE_SEG_BYTES) n = DM_CODE_SEG_BYTES;
    m->seg[i].base = base;
    m->seg[i].len  = n;
    memcpy(m->seg[i].d, b, n);
}

static dm_ev_kind_t finish(dma330_t* m, dm_ev_kind_t k)
{
    m->ev.kind = k;
    m->ev.pc   = m->pc;
    if (k == DM_EV_END || k == DM_EV_KILL || k == DM_EV_FAULT ||
        k == DM_EV_UNKNOWN || k == DM_EV_RUNAWAY)
        m->running = 0;
    return k;
}

static dm_ev_kind_t need_code(dma330_t* m, uint32_t addr)
{
    memset(&m->ev, 0, sizeof m->ev);
    m->ev.supply_addr  = addr;
    m->ev.supply_bytes = CODE_LINE;
    m->pend      = PEND_CODE;
    m->pend_need = CODE_LINE;
    m->sup_n     = 0;
    return finish(m, DM_EV_NEED_CODE);
}

/*------------------------------------------------------------------------------
 * Data movement helpers
 *----------------------------------------------------------------------------*/
static void swap_beat(uint8_t* d, unsigned bus, unsigned swap)
{
    uint8_t  t[DM_MAX_BUS_BYTES];
    unsigned g = 1u << swap, k;
    if (swap < 1 || swap > 4 || g > bus) return;
    memcpy(t, d, bus);
    for (k = 0; k < bus; k++) d[k] = t[k ^ (g - 1)];
}

/* Bytes of a store burst are taken from the stream and placed on the lanes of
 * each beat; lanes without a strobe carry zero (spec 4.7.4). */
static void build_beats(dma330_t* m, uint32_t addr, unsigned size, unsigned len,
                        unsigned inc, unsigned swap, int zero)
{
    unsigned szb = 1u << size, bus = m->cfg.bus_bytes, nb = len + 1, b, lane, taken = 0;
    uint32_t aligned = addr & ~(szb - 1u);
    for (b = 0; b < nb; b++) {
        uint32_t a  = (!inc || b == 0) ? addr : aligned + b * szb;
        unsigned lo = a % bus;
        unsigned hi = ((a / szb) * szb) % bus + szb - 1;
        memset(m->beat_data[b], 0, DM_MAX_BUS_BYTES);
        m->beat_strb[b] = 0;
        for (lane = lo; lane <= hi; lane++) {
            m->beat_data[b][lane] = zero ? 0 : m->stream[taken++];
            m->beat_strb[b] |= 1u << lane;
        }
        if (!zero) swap_beat(m->beat_data[b], bus, swap);
    }
    if (!zero) {
        m->stream_len -= taken;
        memmove(m->stream, m->stream + taken, m->stream_len);
    }
}

/* LD: the supplied bytes join the stream. INCR bursts read consecutive bytes;
 * a FIXED burst reads the same bytes on every beat. */
static void complete_ld(dma330_t* m)
{
    const dm_event_t* e = &m->ev;
    if (e->inc) {
        memcpy(m->stream + m->stream_len, m->sup, e->bytes);
        m->stream_len += e->bytes;
    } else {
        unsigned b;
        for (b = 0; b <= e->len; b++) {
            memcpy(m->stream + m->stream_len, m->sup, e->supply_bytes);
            m->stream_len += e->supply_bytes;
        }
    }
    m->sup_n = 0;
}

/*------------------------------------------------------------------------------
 * Execute
 *----------------------------------------------------------------------------*/
dm_ev_kind_t dma330_step(dma330_t* m)
{
    if (!m->running) return m->ev.kind;

    /* Resume what the previous event asked for */
    if (m->pend == PEND_CODE) {
        if (m->sup_n < m->pend_need) return m->ev.kind;
        install_code(m, m->ev.supply_addr, m->sup, m->sup_n);
        m->sup_n = 0;
        m->pend  = PEND_NONE;
    } else if (m->pend == PEND_LD) {
        if (m->sup_n < m->ev.supply_bytes) return m->ev.kind;
        complete_ld(m);
        m->pend = PEND_NONE;
    }

    if (m->ack_pending) {
        uint32_t pc = m->ev.pc;
        memset(&m->ev, 0, sizeof m->ev);
        m->ev.periph = m->ack_periph;
        m->ev.ack    = m->ack_type;
        m->ack_pending = 0;
        m->ev.kind = DM_EV_ACK;
        m->ev.pc   = pc;
        return DM_EV_ACK;
    }

    for (;;) {
        uint8_t  ib[6] = {0, 0, 0, 0, 0, 0};
        uint8_t  op, b1;
        unsigned len, i, num5, bytes;
        insn_t   cls;
        int      cond_ok, is_load, is_store, do_xfer;
        uint32_t fault, lock;
        uint16_t imm16;
        uint32_t imm32;

        if (m->insns >= m->max_insns) return finish(m, DM_EV_RUNAWAY);

        /* Fetch */
        if (!code_byte(m, m->pc, &ib[0])) return need_code(m, m->pc);
        op  = ib[0];
        len = insn_len(op);
        for (i = 1; i < len; i++)
            if (!code_byte(m, m->pc + i, &ib[i])) return need_code(m, m->pc + i);

        b1    = ib[1];
        imm16 = (uint16_t)(ib[1] | (ib[2] << 8));
        imm32 = (uint32_t)ib[2] | ((uint32_t)ib[3] << 8) | ((uint32_t)ib[4] << 16) |
                ((uint32_t)ib[5] << 24);
        num5  = b1 >> 3;
        cls   = decode_op(op);
        cond_ok = !(op & 1u) || (((op >> 1) & 1u) == (unsigned)m->req_burst);

        is_load  = (cls == I_LD) || (cls == I_LDP);
        is_store = (cls == I_ST) || (cls == I_STP) || (cls == I_STZ);
        do_xfer  = (is_load || is_store) && cond_ok;

        /* Execute-time faults (dma_channel.sv, exec_fault) */
        fault = 0;
        lock  = 0;
        bytes = 0;
        switch (cls) {
        case I_UNDEF: case I_GO:  fault |= FT_UNDEF_INSTR; break;
        case I_MOV:               if (b1 > 2) fault |= FT_OPERAND_INVALID; break;
        case I_SEV: case I_WFE:   if (num5 >= m->cfg.num_events) fault |= FT_CH_EVNT_ERR; break;
        case I_WFP: case I_FLUSHP: if (num5 >= m->cfg.num_periph) fault |= FT_CH_PERIPH_ERR; break;
        default: break;
        }
        if (do_xfer) {
            if ((cls == I_LDP || cls == I_STP) && num5 >= m->cfg.num_periph)
                fault |= FT_CH_PERIPH_ERR;
            if (!VALID(m, DM_R_CCR) || !VALID(m, is_load ? DM_R_SAR : DM_R_DAR))
                return finish(m, DM_EV_UNKNOWN);
            if (is_load) {
                unsigned sz = CCR_SRC_SIZE(m->ccr), ln = CCR_SRC_LEN(m->ccr), inc = CCR_SRC_INC(m->ccr);
                bytes = dm_burst_bytes(m->sar, sz, ln, inc);
                if (sz > m->max_size || dm_crosses_4k(m->sar, sz, ln, inc)) fault |= FT_CH_RDWR_ERR;
                /* Never fits, however many stores drain: the data path reports
                 * the lock-up once the pending stores are gone. */
                if (m->stream_len + bytes > m->cfg.mfifo_bytes) lock = FT_MFIFO_ERR;
            } else {
                unsigned sz = CCR_DST_SIZE(m->ccr), ln = CCR_DST_LEN(m->ccr), inc = CCR_DST_INC(m->ccr);
                unsigned sw = CCR_SWAP(m->ccr);
                int swap_bad = (cls != I_STZ) && sw != 0 &&
                               (sw > 4 || sw > sz || ((m->dar & ((1u << sw) - 1u) & 0xFu) != 0));
                bytes = dm_burst_bytes(m->dar, sz, ln, inc);
                if (sz > m->max_size || swap_bad || dm_crosses_4k(m->dar, sz, ln, inc))
                    fault |= FT_CH_RDWR_ERR;
                if (cls != I_STZ && bytes > m->stream_len) fault |= FT_ST_DATA_UNAVAIL;
            }
        }
        if (fault || lock) {
            /* A lock-up seen together with another fault depends on whether a
             * store was still draining when the instruction was first executed */
            m->ftr       = fault | (fault ? 0 : lock);
            m->ftr_maybe = fault ? lock : 0;
            memset(&m->ev, 0, sizeof m->ev);
            m->ev.ftr       = m->ftr;
            m->ev.ftr_maybe = m->ftr_maybe;
            return finish(m, DM_EV_FAULT);
        }

        m->insns++;

        switch (cls) {
        case I_END:  memset(&m->ev, 0, sizeof m->ev); return finish(m, DM_EV_END);
        case I_KILL: memset(&m->ev, 0, sizeof m->ev); return finish(m, DM_EV_KILL);

        case I_NOP: case I_RMB: case I_WMB:
            m->pc += len;
            break;

        case I_SEV:
            memset(&m->ev, 0, sizeof m->ev);
            m->ev.event_no = num5;
            m->events |= 1u << num5;
            m->ev.pc = m->pc;
            m->pc += len;
            m->ev.kind = DM_EV_SEV;
            return DM_EV_SEV;

        case I_WFE:
            memset(&m->ev, 0, sizeof m->ev);
            m->ev.event_no       = num5;
            m->ev.wfe_invalidate = (b1 >> 1) & 1u;
            m->ev.pc = m->pc;
            m->pc += len;
            m->ev.kind = DM_EV_WFE;
            return DM_EV_WFE;

        case I_LD: case I_LDP: case I_ST: case I_STP: case I_STZ: {
            unsigned sz, ln, inc, szb, off;
            uint32_t addr;
            if (!cond_ok) { m->pc += len; break; }
            memset(&m->ev, 0, sizeof m->ev);
            m->ev.pc = m->pc;
            if (is_load) {
                addr = m->sar; sz = CCR_SRC_SIZE(m->ccr); ln = CCR_SRC_LEN(m->ccr);
                inc = CCR_SRC_INC(m->ccr);
                m->ev.cache = CCR_SRC_CACHE(m->ccr);
                m->ev.prot  = CCR_SRC_PROT(m->ccr) | (m->ns ? 2u : 0u);
            } else {
                addr = m->dar; sz = CCR_DST_SIZE(m->ccr); ln = CCR_DST_LEN(m->ccr);
                inc = CCR_DST_INC(m->ccr);
                m->ev.cache = CCR_DST_CACHE(m->ccr);
                m->ev.prot  = CCR_DST_PROT(m->ccr) | (m->ns ? 2u : 0u);
            }
            szb = 1u << sz;
            off = addr & (szb - 1u);
            m->ev.addr = addr; m->ev.size = sz; m->ev.len = ln; m->ev.inc = inc;
            m->ev.bytes = bytes; m->ev.nbeats = ln + 1;

            if (is_load) {
                m->ev.supply_addr  = addr;
                m->ev.supply_bytes = inc ? bytes : szb - off;
                if (inc) m->sar += bytes;
                m->pend = PEND_LD;
                m->sup_n = 0;
                if (cls == I_LDP) {
                    m->ack_pending = 1;
                    m->ack_periph  = num5;
                    m->ack_type    = (op >> 1) & 1u ? DM_ACK_BURST : DM_ACK_SINGLE;
                }
                m->pc += len;
                m->ev.kind = DM_EV_LD;
                return DM_EV_LD;
            }
            build_beats(m, addr, sz, ln, inc,
                        cls == I_STZ ? 0 : CCR_SWAP(m->ccr), cls == I_STZ);
            if (inc) m->dar += bytes;
            if (cls == I_STP) {
                m->ack_pending = 1;
                m->ack_periph  = num5;
                m->ack_type    = (op >> 1) & 1u ? DM_ACK_BURST : DM_ACK_SINGLE;
            }
            m->pc += len;
            m->ev.kind = (cls == I_STZ) ? DM_EV_STZ : DM_EV_ST;
            return m->ev.kind;
        }

        case I_LP:
            if (op & 2u) m->lc1 = b1; else m->lc0 = b1;
            SET_VALID(m, (op & 2u) ? DM_R_LC1 : DM_R_LC0);
            m->pc += len;
            break;

        case I_LPEND:
            if (!cond_ok) {
                m->pc += len;
            } else if (op & 0x10u) {                           /* DMALPEND */
                uint8_t* lc = (op & 4u) ? &m->lc1 : &m->lc0;
                dm_reg_t r  = (op & 4u) ? DM_R_LC1 : DM_R_LC0;
                if (!VALID(m, r)) return finish(m, DM_EV_UNKNOWN);
                if (*lc != 0) { (*lc)--; m->pc -= b1; }
                else          m->pc += len;
            } else {                                           /* DMALPFE  */
                m->pc = m->req_last ? m->pc + len : m->pc - b1;
            }
            break;

        case I_WFP: {
            unsigned kind = op & 3u;                           /* 0 S, 1 P, 2 B */
            if (m->req_rd[num5] >= m->req_n[num5]) {
                m->insns--;
                m->ev.pc = m->pc;
                m->ev.periph = num5;
                return finish(m, DM_EV_STARVED);
            }
            {
                unsigned burst = m->req[num5][m->req_rd[num5]].burst;
                m->req_last = m->req[num5][m->req_rd[num5]].last;
                m->req_rd[num5]++;
                m->req_burst = (kind == 1) ? burst : (kind == 2);
            }
            m->pc += len;
            break;
        }

        case I_FLUSHP:
            memset(&m->ev, 0, sizeof m->ev);
            m->ev.pc     = m->pc;
            m->ev.periph = num5;
            m->ev.ack    = DM_ACK_FLUSH;
            m->req_burst = 0;
            m->req_last  = 0;
            m->pc += len;
            m->ev.kind = DM_EV_ACK;
            return DM_EV_ACK;

        case I_ADDH: case I_ADNH: {
            uint32_t add = ((cls == I_ADNH) ? 0xFFFF0000u : 0u) | imm16;
            if (op & 2u) {
                if (!VALID(m, DM_R_DAR)) return finish(m, DM_EV_UNKNOWN);
                m->dar += add;
            } else {
                if (!VALID(m, DM_R_SAR)) return finish(m, DM_EV_UNKNOWN);
                m->sar += add;
            }
            m->pc += len;
            break;
        }

        case I_MOV:
            switch (b1 & 3u) {
            case 0:  m->sar = imm32; SET_VALID(m, DM_R_SAR); break;
            case 1:  m->ccr = imm32; SET_VALID(m, DM_R_CCR); break;
            default: m->dar = imm32; SET_VALID(m, DM_R_DAR); break;
            }
            m->pc += len;
            break;

        default:                       /* I_UNDEF / I_GO fault above */
            return finish(m, DM_EV_UNKNOWN);
        }
    }
}

/*------------------------------------------------------------------------------
 * Accessors
 *----------------------------------------------------------------------------*/
const dm_event_t* dma330_event(const dma330_t* m) { return &m->ev; }

void dma330_beat(const dma330_t* m, unsigned i, uint8_t data[DM_MAX_BUS_BYTES], uint32_t* strb)
{
    if (i >= DM_MAX_BEATS) i = DM_MAX_BEATS - 1;
    memcpy(data, m->beat_data[i], DM_MAX_BUS_BYTES);
    *strb = m->beat_strb[i];
}

uint32_t dma330_reg(const dma330_t* m, dm_reg_t r)
{
    switch (r) {
    case DM_R_PC:        return m->pc;
    case DM_R_SAR:       return m->sar;
    case DM_R_DAR:       return m->dar;
    case DM_R_CCR:       return m->ccr;
    case DM_R_LC0:       return m->lc0;
    case DM_R_LC1:       return m->lc1;
    case DM_R_FTR:       return m->ftr;
    case DM_R_FTR_MAYBE: return m->ftr_maybe;
    case DM_R_EVENTS:    return m->events;
    default:             return 0;
    }
}

int dma330_reg_valid(const dma330_t* m, dm_reg_t r)
{
    switch (r) {
    case DM_R_SAR: case DM_R_DAR: case DM_R_CCR: case DM_R_LC0: case DM_R_LC1:
        return (int)VALID(m, r);
    case DM_R_NUM:
        return 0;
    default:
        return 1;
    }
}

unsigned long dma330_insn_count(const dma330_t* m) { return m->insns; }
