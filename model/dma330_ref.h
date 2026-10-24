/*==============================================================================
 * dma330_ref.h - C reference model of one AXI DMA (DMA-330 style) channel thread
 *------------------------------------------------------------------------------
 * An instruction-set simulator: it fetches the real DMA-330 byte code, executes
 * it and reports what the hardware must do on its interfaces, in program order:
 *
 *   DM_EV_LD / DM_EV_ST / DM_EV_STZ   one AXI burst (address, shape, data, strobes)
 *   DM_EV_ACK                         peripheral acknowledge (single/burst/flush)
 *   DM_EV_SEV                         event / interrupt raised
 *   DM_EV_END / KILL / FAULT          end of the program
 *
 * The model is architectural, not cycle accurate. It has no timing and no
 * memory of its own: whatever it needs (instruction bytes, load data) it asks
 * for with an event and the caller supplies it with dma330_supply(). This is
 * what lets the SystemVerilog side wrap it through plain DPI-C imports (no
 * export tasks, no C compiler needed inside the simulator).
 *
 * Driver loop:
 *
 *     dma330_go(m, pc, ns);
 *     for (;;) {
 *         switch (dma330_step(m)) {
 *         case DM_EV_NEED_CODE: supply  ev->supply_bytes at ev->supply_addr
 *         case DM_EV_LD:        supply  ev->supply_bytes at ev->supply_addr
 *         case DM_EV_ST/STZ:    read the beats with dma330_beat()
 *         case DM_EV_ACK/SEV/WFE: record
 *         case DM_EV_END/KILL/FAULT/...: stop
 *         }
 *     }
 *
 * Behavioural contract: identical to rtl/core/dma_channel.sv + dma_datapath.sv
 * (see docs/DESIGN_SPEC.md, 4.5, 4.7 and 7). The model is written from the
 * specification, not from the testbench, so that it is an independent
 * reference for the generator-based predictor in dma_scoreboard.
 *============================================================================*/
#ifndef DMA330_REF_H
#define DMA330_REF_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DM_MAX_BUS_BYTES   16     /* widest supported AXI data bus            */
#define DM_MAX_BEATS       16     /* AxLEN is 4 bits                          */
#define DM_MAX_PERIPH      32     /* 5-bit peripheral number                  */
#define DM_REQ_DEPTH       256    /* queued peripheral requests per peripheral */
#define DM_CODE_SEGS       16
#define DM_CODE_SEG_BYTES  64
#define DM_STREAM_BYTES    16384  /* largest MFIFO: 1024 lines of 16 bytes  */

/*------------------------------------------------------------------------------
 * Configuration: must equal the DUT parameters
 *----------------------------------------------------------------------------*/
typedef struct {
    unsigned bus_bytes;       /* DATA_W / 8                                    */
    unsigned num_events;      /* NUM_EVENTS                                    */
    unsigned num_periph;      /* NUM_PERIPH                                    */
    unsigned mfifo_bytes;     /* whole shared MFIFO: MFIFO_LINES * bus_bytes   */
    unsigned max_insns;       /* run-away guard (0 = default 100000)           */
} dma330_cfg_t;

/*------------------------------------------------------------------------------
 * Events
 *----------------------------------------------------------------------------*/
typedef enum {
    DM_EV_NONE = 0,
    DM_EV_NEED_CODE,          /* instruction bytes missing: supply them        */
    DM_EV_LD,                 /* load burst: supply the source bytes           */
    DM_EV_ST,                 /* store burst (data from the load stream)       */
    DM_EV_STZ,                /* store burst of zeros                          */
    DM_EV_ACK,                /* peripheral acknowledge                        */
    DM_EV_SEV,                /* DMASEV                                        */
    DM_EV_WFE,                /* DMAWFE (assumed to be satisfied)              */
    DM_EV_END,                /* DMAEND: program finished                      */
    DM_EV_KILL,               /* DMAKILL in the program                        */
    DM_EV_FAULT,              /* channel fault, see ftr / ftr_maybe            */
    DM_EV_STARVED,            /* DMAWFP but no request queued                  */
    DM_EV_UNKNOWN,            /* program used a register it never wrote        */
    DM_EV_RUNAWAY,            /* instruction budget exhausted                  */
    DM_EV_UNSURE              /* DMALD whose MFIFO lock-up depends on timing   */
} dm_ev_kind_t;

typedef enum { DM_ACK_SINGLE = 0, DM_ACK_BURST = 1, DM_ACK_FLUSH = 2 } dm_ack_t;

typedef struct {
    dm_ev_kind_t kind;
    uint32_t pc;              /* address of the instruction that produced it   */
    /* LD / ST / STZ: the AXI burst */
    uint32_t addr;
    unsigned len;             /* beats - 1                                     */
    unsigned size;            /* log2(bytes per beat)                          */
    unsigned inc;             /* 1: INCR, 0: FIXED                             */
    unsigned cache;           /* AxCACHE[2:0]                                  */
    unsigned prot;            /* AxPROT, NS merged in                          */
    unsigned bytes;           /* payload bytes of the whole burst              */
    unsigned nbeats;
    /* NEED_CODE / LD: what the caller must supply */
    uint32_t supply_addr;
    unsigned supply_bytes;
    /* ACK */
    unsigned periph;
    dm_ack_t ack;
    /* SEV / WFE */
    unsigned event_no;
    unsigned wfe_invalidate;
    /* FAULT */
    uint32_t ftr;             /* fault bits that are certain                   */
    uint32_t ftr_maybe;       /* bits whose presence depends on timing (0 now) */
} dm_event_t;

/*------------------------------------------------------------------------------
 * Architectural registers (dma330_reg)
 *----------------------------------------------------------------------------*/
typedef enum {
    DM_R_PC = 0, DM_R_SAR, DM_R_DAR, DM_R_CCR, DM_R_LC0, DM_R_LC1,
    DM_R_FTR, DM_R_FTR_MAYBE, DM_R_EVENTS, DM_R_NUM
} dm_reg_t;

typedef struct dma330 dma330_t;

dma330_t*         dma330_new(const dma330_cfg_t* cfg);
void              dma330_free(dma330_t* m);

/* Event / peripheral security (CR3 / CR4, bit = 1: usable by a non-secure
 * thread). Default after dma330_new: everything non-secure. */
void              dma330_security(dma330_t* m, uint32_t irq_ns, uint32_t periph_ns);

/* DMAGO: start a program at pc. Register values are unknown again. */
void              dma330_go(dma330_t* m, uint32_t pc, int ns);

/* Queue a request the peripheral will raise (consumed by DMAWFP in order). */
void              dma330_periph_req(dma330_t* m, unsigned periph, int burst, int last);

/* Run until the next event; the event stays valid until the next call. */
dm_ev_kind_t      dma330_step(dma330_t* m);
const dm_event_t* dma330_event(const dma330_t* m);

/* Supply bytes asked for by NEED_CODE / LD. May be called in several chunks. */
void              dma330_supply(dma330_t* m, const uint8_t* bytes, unsigned n);

/* Beat i (0..nbeats-1) of the current ST/STZ burst: data lanes and strobes. */
void              dma330_beat(const dma330_t* m, unsigned i, uint8_t data[DM_MAX_BUS_BYTES],
                              uint32_t* strb);

/* Register value at the end of the run, and whether the program defined it. */
uint32_t          dma330_reg(const dma330_t* m, dm_reg_t r);
int               dma330_reg_valid(const dma330_t* m, dm_reg_t r);

/* Number of instructions executed since DMAGO. */
unsigned long     dma330_insn_count(const dma330_t* m);

/* Pure helpers (also used by the unit test) */
unsigned          dm_burst_bytes(uint32_t addr, unsigned size, unsigned len, unsigned inc);
int               dm_crosses_4k(uint32_t addr, unsigned size, unsigned len, unsigned inc);

#ifdef __cplusplus
}
#endif

#endif /* DMA330_REF_H */
