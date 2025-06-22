`ifndef CONFIG_SVH
`define CONFIG_SVH

///////////////////////////////////
// ---- Starting Parameters ---- //
///////////////////////////////////

// some starting parameters that you should set
// this is *your* processor, you decide these values (try analyzing which is best!)

// superscalar width
`define N 2
`define CDB_SZ `N // This MUST match your superscalar width

// sizes
`define ROB_SZ 64
`define BTQ_SZ 16
`define RAS_SZ 16
    /* BTQ_SZ doubled (form 8). This improved CPI on tight loop
    programs like branchy.s and branchy_nested.s */
`define PHYS_REG_SZ_P6 32
`define PHYS_REG_SZ_R10K (32 + `ROB_SZ)

// worry about these later
`define BRANCH_PRED_SZ xx
`define LSQ_SZ 12
`define SQ_RET_BUF_SZ 4
parameter GHR_BUF_SZ= 32;
parameter GHR_LEN   = 8;
parameter BMASK_LEN = 8; // i.e. number of branch checkpoints

// functional units (you should decide if you want more or fewer types of FUs)
`define NUM_FU_ALU 2
`define NUM_FU_MUL 1
`define NUM_FU_LOD 1
`define LD_BAY_SZ 2 //num load bays in the FU
`define NUM_FU_STR 1
`define NUM_FU_BRU 1
`define NUM_FU_TOTAL `NUM_FU_ALU + `NUM_FU_MUL + `NUM_FU_LOD + `NUM_FU_STR + `NUM_FU_BRU

// number of mult stages (2, 4) (you likely don't need 8)
`define MUL_STAGES 16
// Justin: funny enough we need at least 8 or else multiply is on critical path

///////////////////////////////
// --- Compil. Controls ---- //
///////////////////////////////
/* How can we implement this in the Makefile? */
// comment out to enable synth only constructions
// `define SYNTH

`ifndef SYNTH
// comment out to disable DEBUG:
// `define DEBUG
// comment to disable clock cycle print
// `define CYCLE_PRINT
// comment out to...
// `define PC_GEN_TEST_MODE
`endif

`endif // CONFIG_SVH
