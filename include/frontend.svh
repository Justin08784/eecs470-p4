`ifndef FRONTEND_SVH
`define FRONTEND_SVH

`include "types.svh"

typedef struct packed {
    logic [N-1:0][`IDX_SIZE(RAS_SZ)-1:0] top;
    logic [N-1:0][`CNT_SIZE(RAS_SZ)-1:0] used;
} RAS_SNAP;

// BPU stuff
typedef enum logic [1:0] {
    SN = 2'b00,
    WN = 2'b01,
    WT = 2'b10,
    ST = 2'b11
} SC_STATE;

function automatic logic [1:0] update_sc(
    input logic unsigned [1:0] sc,
    input logic take
);
    if (take)
        return sc == 2'b11 ? 2'b11 : sc + `UCAST_FIT(1);
    else
        return sc == 0 ? 0 : sc - `UCAST_FIT(1);
endfunction

function automatic logic query_sc(input logic [1:0] sc);
    return sc[1];
endfunction


typedef struct packed {
    logic [1:0] sc;
    logic       vld;
    WADDR       tgt;
    logic [3:0] off;
        /* TODO (critical path opt.): Use either...
            A. cry, lo4 scheme:
                cry = idx-4 carry bit,
                lo4 = lowest 4 bits of branch pc
                pc  = {base + cry, lo4}
                ++ cheap to reconstruct pc (simply concat lowest bits)
                -- costlier update_fb offset comparisons

            B. cry, off scheme:
                cry = same as above
                off = pc - base
                pc  = {base + cry, (base + off)[3:0]}
                -- costlier to reconstruct pc (add offset)
                ++ cheaper update_fb offset comparisons

            Maybe lo4 for fallthrough (end_off), off for branch pc_off?
        */
    logic       always_take; // i.e. a cond branch that is always taken?
} FTB_BR_SLOT;

typedef struct packed {
    logic cond;         // = "sharing" bit
    logic call;
    logic ret;
    logic jalr;
} FTB_MD1;

typedef struct packed {
    // fallthrough npc (i.e. npc if no branch taken)
    logic [3:0] end_off;    // offset of last insn in the FB. ft_npc = base + end_off + 1
        // TODO: see FTB_BR_SLOT (above) for alternative schemes

    // two branch slots: [0, 1]
    FTB_BR_SLOT [1:0] br_slot;

    // metadata re: br1/tail slot
    FTB_MD1 md1;
} FTB_ENTRY;

typedef struct packed {
    WADDR       base;
    logic [3:0] pc_off; // pc = base + pc_off
    logic       take;
    WADDR       tgt;

    FTB_MD1 md;
} FTB_UPD_PKT;

typedef struct packed {
`ifdef PC_GEN_TEST_MODE
    int id;
`endif
    WADDR       base_n;     // base address of *next* FB

    logic       ft;         // fallthrough? else took a branch
    logic       pred_idx;   // ft ? <IGNORE>: slot of pred-taken branch
    logic [3:0] off;        // ft ? end_off : slot[pred_idx].off
    logic       hit;

    // pared down FTB entry
    struct packed {
        logic       vld;
        logic [3:0] off;
    } [1:0] slot;

    logic       always_take;// ft ? <IGNORE>: " of pred-taken branch
    FTB_MD1     md;         // ft ? <IGNORE>: " of pred-tkaen branch
} FTQ_ENTRY;


typedef struct packed {
    // struct guard
    logic brch; // 1 iff is any form of control insn

    // fields valid iff branch high
    logic cond;
    logic call;
    logic ret;
    logic jalr;
} BRANCH_MD;

typedef struct packed {
    DWADDR          dw;
    logic[1:0][3:0] off;
    logic   [1:0]   fmsk;   // which words to fetch.
        /* Invariants:
        1. At least bit 0 (word 0) set
        2. Bits set contiguously from 0

        FUTURE: Invariant 2 may no longer hold if we detect when a branch in an
        early word targets into a later word *in the same cache line*,
        AND we allow storing them together in a single cache line. Then and all insns
        between the branch and target would have fmsk set to 0.
            Idea: if the branch target is in the same cache line as the
            branch (much more likely with larger cache lines), we may reuse
            the 14-bit tgt field in the FTB branch slot as a [$clog2(cache_line_sz)-1:0]
            in-line offset (possible with a carry bit for faster computation).
        */
    logic   [1:0]   is_end;
        /* Does word i *terminate* an FB?
        Both bits can be 1 when word0 ends FB-A and word1 ends FB-B (a 1-insn block). */
    
    MEM_BLOCK       blk;
    BRANCH_MD[1:0]  md;

} ICACHE_RESPONSE;



// BTQ stuff
typedef struct packed {
    // FTB_UPD_PKT fields
    WADDR       base;
    logic [3:0] pc_off; // pc = base + pc_off
    logic       take;
    WADDR       tgt;

    logic       always_take; // i.e. a cond branch that is always taken?
    FTB_MD1     md;

    // predictor-specific fields
    logic en_dir_update;    // update direction predictors?
    logic [GHR_LEN-1:0] hash; // gshare hash

} BPU_UPD_PKT;

typedef struct packed {
    logic en;
    WADDR pc;
    WADDR tgt;
} puq2btb;

typedef struct packed {
    DWADDR              dw;
    logic   [1:0][3:0]  off;
        // FB_OFF[1:0][1:0]ixq_out_off,
    logic   [1:0]       fmsk;
    logic   [1:0]       is_end;
} pc_gen2ixq;



/* i/o structs */
/**
 * IF_ID Packet:
 * Data exchanged from the IF to the ID stage
 */
typedef struct packed {
    INST  inst;
    WADDR PC;

    RAS_SNAP ras_snap;
    BTQ_IDX btq_idx;
} IF_ID_PACKET;


typedef struct packed {
    logic       en;
    BPU_UPD_PKT dat;
} puq2fetch;

typedef struct packed {
    `CNT_TYPE(N) btq_rdy_scnt;
    BTQ_IDX [N-1:0]        btq_idxs_n;

    puq2fetch   bp_upd;
} btq2fetch;


typedef struct packed {
    `CNT_TYPE(N)           en_cnt;
        // How many branch instructions dispatching?
        // Sender must ensure branch insns packed to lowest indices.
    logic   [N-1:0]        is_tail;
    WADDR   [N-1:0]        PC;
    logic   [N-1:0][3:0]   off;
    logic   [N-1:0]        pred;
    WADDR   [N-1:0]        pred_tgt;
    logic   [N-1:0]        always_take;
    FTB_MD1 [N-1:0]        md;

    logic   [N-1:0]        hit;
    logic   [N-1:0]        hit_slot;
    logic   [N-1:0][GHR_LEN-1:0] hash; // gshare hash index
    logic   [N-1:0][`IDX_SIZE(GHR_BUF_SZ)-1:0] ghr_base;
} fetch2btq;



`endif // FRONTEND_SVH