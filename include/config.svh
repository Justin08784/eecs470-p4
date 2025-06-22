`ifndef CONFIG_SVH
`define CONFIG_SVH

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

///////////////////////////////////
// ---- Starting Parameters ---- //
///////////////////////////////////

// some starting parameters that you should set
// this is *your* processor, you decide these values (try analyzing which is best!)

// superscalar width
parameter N = 2;
// parameter CDB_SZ= N // This MUST match your superscalar width

// sizes
parameter ROB_SZ= 64;
parameter BTQ_SZ= 16;
    /* BTQ_SZ doubled (form 8). This improved CPI on tight loop
    programs like branchy.s and branchy_nested.s */
parameter RAS_SZ= 16;
parameter FTQ_SZ= 32;
parameter PHYS_REG_SZ_P6    = 32;
parameter PHYS_REG_SZ_R10K  = (32 + ROB_SZ);

parameter IQQ_SZ= 4;
parameter IRQ_SZ= 8;

// worry about these later
parameter BRANCH_PRED_SZ= 'x;
parameter LSQ_SZ        = 12;
parameter SQ_RET_BUF_SZ = 4;
parameter GHR_BUF_SZ    = 32;
parameter GHR_LEN       = 8;
parameter BMASK_LEN     = 8; // i.e. number of branch checkpoints

// functional units (you should decide if you want more or fewer types of FUs)
parameter NUM_FU_ALU    = 2;
parameter NUM_FU_MUL    = 1;
parameter NUM_FU_LOD    = 1;
parameter NUM_FU_STR    = 1;
parameter NUM_FU_BRU    = 1;
parameter NUM_FU_TOTAL  = NUM_FU_ALU + NUM_FU_MUL + NUM_FU_LOD + NUM_FU_STR + NUM_FU_BRU;

parameter LD_BAY_SZ     = 2; //num load bays in the FU

// number of mult stages (2, 4) (you likely don't need 8)
parameter MUL_STAGES    = 16;
// Justin: funny enough we need at least 8 or else multiply is on critical path

`endif // CONFIG_SVH
