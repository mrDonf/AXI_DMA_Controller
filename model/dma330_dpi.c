/*==============================================================================
 * dma330_dpi.c - SystemVerilog DPI-C layer of the DMA-330 channel model
 *------------------------------------------------------------------------------
 * Thin wrappers around dma330_ref.c using only DPI scalar types and
 * bit [127:0] (svBitVecVal[4], little-endian words), so the library needs
 * neither the svdpi runtime nor DPI exports. Import side: tb/dpi/dma330_dpi_pkg.sv
 *============================================================================*/
#include <string.h>

#include "dma330_ref.h"

typedef unsigned int svBitVecVal;

/* Field selectors for dma330_dpi_ev(); keep in sync with dma330_dpi_pkg.sv */
enum {
    F_KIND = 0, F_PC, F_ADDR, F_LEN, F_SIZE, F_INC, F_CACHE, F_PROT, F_BYTES, F_NBEATS,
    F_SUPPLY_ADDR, F_SUPPLY_BYTES, F_PERIPH, F_ACK, F_EVENT_NO, F_WFE_INV, F_FTR, F_FTR_MAYBE
};

void* dma330_dpi_new(unsigned int bus_bytes, unsigned int num_events, unsigned int num_periph,
                     unsigned int mfifo_bytes)
{
    dma330_cfg_t c;
    c.bus_bytes   = bus_bytes;
    c.num_events  = num_events;
    c.num_periph  = num_periph;
    c.mfifo_bytes = mfifo_bytes;
    c.max_insns   = 0;
    return dma330_new(&c);
}

void dma330_dpi_free(void* h) { dma330_free((dma330_t*)h); }

void dma330_dpi_go(void* h, unsigned int pc, int ns) { dma330_go((dma330_t*)h, pc, ns); }

void dma330_dpi_periph_req(void* h, int periph, int burst, int last)
{
    dma330_periph_req((dma330_t*)h, (unsigned)periph, burst, last);
}

int dma330_dpi_step(void* h) { return (int)dma330_step((dma330_t*)h); }

unsigned int dma330_dpi_ev(void* h, int field)
{
    const dm_event_t* e = dma330_event((const dma330_t*)h);
    switch (field) {
    case F_KIND:         return (unsigned)e->kind;
    case F_PC:           return e->pc;
    case F_ADDR:         return e->addr;
    case F_LEN:          return e->len;
    case F_SIZE:         return e->size;
    case F_INC:          return e->inc;
    case F_CACHE:        return e->cache;
    case F_PROT:         return e->prot;
    case F_BYTES:        return e->bytes;
    case F_NBEATS:       return e->nbeats;
    case F_SUPPLY_ADDR:  return e->supply_addr;
    case F_SUPPLY_BYTES: return e->supply_bytes;
    case F_PERIPH:       return e->periph;
    case F_ACK:          return (unsigned)e->ack;
    case F_EVENT_NO:     return e->event_no;
    case F_WFE_INV:      return e->wfe_invalidate;
    case F_FTR:          return e->ftr;
    case F_FTR_MAYBE:    return e->ftr_maybe;
    default:             return 0;
    }
}

/* nbytes (<= 16) bytes of a 128-bit chunk, byte 0 = bits [7:0] */
void dma330_dpi_supply(void* h, const svBitVecVal* chunk, int nbytes)
{
    unsigned char b[16];
    memcpy(b, chunk, 16);
    if (nbytes > 16) nbytes = 16;
    if (nbytes > 0) dma330_supply((dma330_t*)h, b, (unsigned)nbytes);
}

/* Lanes of beat 'idx' of the current store burst: data bit [8*k+7:8*k] = lane k */
void dma330_dpi_beat(void* h, int idx, svBitVecVal* data, unsigned int* strb)
{
    unsigned char d[DM_MAX_BUS_BYTES];
    uint32_t s = 0;
    dma330_beat((const dma330_t*)h, (unsigned)idx, d, &s);
    memcpy(data, d, DM_MAX_BUS_BYTES);
    *strb = s;
}

unsigned int dma330_dpi_reg(void* h, int r) { return dma330_reg((const dma330_t*)h, (dm_reg_t)r); }
int dma330_dpi_reg_valid(void* h, int r) { return dma330_reg_valid((const dma330_t*)h, (dm_reg_t)r); }
unsigned int dma330_dpi_insns(void* h) { return (unsigned)dma330_insn_count((const dma330_t*)h); }
