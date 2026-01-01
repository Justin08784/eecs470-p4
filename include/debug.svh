`ifndef DEBUG_SVH
`define DEBUG_SVH

// TODO: add perf counters/types

// OPTIONAL: Print our your data here
// It will go to the $program.log file
function print_ID_RENAME_PKT(input ID_RENAME_PKT x);
    $display("ID_RENAME_PKT: id=%3d PC=%h fu_idx=%2d inst=%h opa_select=%1d opb_select=%1d alu_func=%1d cond_branch=%b halt=%b illegal=%b csr_op=%b btq_idx=%2d ",
        x.id,
        x.PC << 2,
        x.fu_idx,
        x.inst,
        x.opa_select,
        x.opb_select,
        x.alu_func,
        x.cond_branch,
        x.halt,
        x.illegal,
        x.csr_op,
        x.btq_idx
    );
endfunction

function print_commit_rs_pkt(input COMMIT_RS_PKT x);
    $display("COMMIT_RS_PKT: {bmask: %b} id=%3d PC=%h fu_idx=%2d inst=%h opa_select=%1d opb_select=%1d alu_func=%1d cond_branch=%b halt=%b illegal=%b csr_op=%b btq_idx=%2d b1hot=%b",
        x.bmask,
        x.id,
        x.PC << 2,
        x.fu_idx,
        x.inst,
        x.opa_select,
        x.opb_select,
        x.alu_func,
        x.cond_branch,
        x.halt,
        x.illegal,
        x.csr_op,
        x.btq_idx,
        x.b1hot
    );
endfunction

function get_fu_name(input FU_IDX fu_idx, output string name);
    case (fu_idx)
        FU_ALU:  name = "ALU";
        FU_MUL: name = "MUL";
        FU_LOD: name = "LOD";
        FU_STR:  name = "STR";
        FU_BRU:  name = "BRU";
        default: name = "Unknown FU";
    endcase
endfunction

function automatic string dbg_mem_cmd(input MEM_COMMAND cmd);
    string rv;
    case (cmd)
        MEM_NONE:  rv = "NONE";
        MEM_STORE: rv = "STOR";
        MEM_LOAD:  rv = "LOAD";
    endcase
    return rv;
endfunction

function automatic string dbg_mem_size(input MEM_SIZE size);
    string rv;
    rv = "unknown mem size";
    case (size)
        BYTE:   rv = "BYTE";
        HALF:   rv = "HALF";
        WORD:   rv = "WORD";
        DOUBLE: rv = "DOUBLE";
    endcase
    return rv;
endfunction;

`endif // DEBUG_SVH
