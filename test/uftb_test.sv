`include "sys_defs.svh"

// enable to synthesize uFTB (via `make uftb.syn.out`)
// `define SYNTH_UFTB

/*
TODO: Test sc updates by update_fb. sc_new should be different from
sc_upd0 and sc_upd1.
*/

module uftb_test;
    logic       _d; // dummy holder for hit_slot outparam
    logic       spill;
    FTB_UPD_PKT udat;
    FTB_ENTRY   fb, save;

    FTB_MD1     md_cond, md_call;
    WADDR [2:0] tgt;

    function automatic FTB_UPD_PKT init_udat(
        input FTB_UPD_PKT udat,
        input logic [3:0] off,
        input WADDR       tgt,
        input FTB_MD1     md
    );
        udat = '0;

        udat.pc_off = off;
        udat.tgt    = tgt;

        udat.md     = md;

        return udat;
    endfunction

    function automatic FTB_ENTRY init_fb(
        input FTB_ENTRY fb,

        input struct packed {
            logic       en;
            logic [3:0] off;
            WADDR       tgt;
        } br0,

        input struct packed {
            logic       en;
            logic [3:0] off;
            WADDR       tgt;
            FTB_MD1     md;
        } br1
    );
        fb = '0;

        if (br0.en) begin
            fb.br_slot[0] = '{
                sc  : '0,
                vld : 1,
                off : br0.off,
                tgt : br0.tgt,
                always_take : 0
            };

        end

        if (br1.en) begin
            fb.br_slot[1] = '{
                sc  : '0,
                vld : 1,
                off : br1.off,
                tgt : br1.tgt,
                always_take : 0
            };

            fb.md1 = br1.md;
        end

        fb.end_off = fb.br_slot[1].vld
            ? fb.br_slot[1].off
            : 15;
        
        return fb;
    endfunction

    task automatic print_ftb_entry(input FTB_ENTRY fb);
        $display("[ {vld: %b, tgt: %d, off = %2d, always_take: %b},",
            fb.br_slot[0].vld,
            fb.br_slot[0].tgt,
            fb.br_slot[0].off,
            fb.br_slot[0].always_take
        );

        $display("  {vld: %b, tgt: %d, off = %2d, always_take: %b, ccrj: %b%b%b%b},",
            fb.br_slot[1].vld,
            fb.br_slot[1].tgt,
            fb.br_slot[1].off,
            fb.br_slot[1].always_take,
            fb.md1.cond,
            fb.md1.call,
            fb.md1.ret,
            fb.md1.jalr
        );

        $display("  end_off = %2d]", fb.end_off);

    endtask

    task cmp_br_slot(
        input   FTB_BR_SLOT a,b,
        output  logic match
    );
        // ignore sc, always_take
        FTB_BR_SLOT msk;
        msk     = '1;
        msk.sc  = '0;
        msk.always_take = '0;

        match = (a & msk) == (b & msk);
    endtask

    task chk(
        logic     exp_spill,
        FTB_ENTRY exp_fb
    );
        logic correct;
        logic match_br0;
        logic match_br1;
        logic match_md1;
        logic match_slot0, match_slot1;

        cmp_br_slot(fb.br_slot[0], exp_fb.br_slot[0], match_slot0);
        cmp_br_slot(fb.br_slot[1], exp_fb.br_slot[1], match_slot1);

        match_br0 = (fb.br_slot[0].vld == exp_fb.br_slot[0].vld)
        &&  (!fb.br_slot[0].vld // dont care about mismatch if invalid
            ||  match_slot0
        );

        // the non-"cond" fields are meaningful/valid only if !cond
        match_md1 = fb.md1.cond
            ? exp_fb.md1.cond
            : (fb.md1 == exp_fb.md1);

        match_br1 = (fb.br_slot[1].vld == exp_fb.br_slot[1].vld)
        &&  (!fb.br_slot[1].vld // dont care about mismatch if invalid
            ||  (match_slot1 && match_md1)
        );
        
        correct = (spill == exp_spill)
        &&  (spill || (match_br0 && match_br1));

        if (!correct) begin
            $display("\n\033[31m@@@ Failed at time %4d\033[0m", $time);
            $display("got");
            $display("spill %b", spill);
            print_ftb_entry(fb);
            $display("expected");
            $display("spill %b", exp_spill);
            print_ftb_entry(exp_fb);
            $finish();
        end
    endtask

    initial begin
        $display("\nStart Testbench");
        md_cond = '{
            cond    : 1,
            call    : 0,
            ret     : 0,
            jalr    : 0
        };
        md_call = '{
            cond    : 0,
            call    : 1,
            ret     : 0,
            jalr    : 1
        };

        tgt[0] = 1000;
        tgt[1] = 2111;
        tgt[2] = 3222;



`ifndef SYNTH_UFTB
        $display("\nTest 1: vld = [0, 0]");
        save = '0;

        $display("  1A: udat = {off = 1, tgt0, md_call}");
        udat= init_udat(udat, 1, tgt[0], md_call);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(0, init_fb(
            '0,
            '0,
            '{1, 1, tgt[0], md_call}
        ));

        $display("  1B: udat = {off = 1, tgt0, md_cond}");
        udat= init_udat(udat, 1, tgt[0], md_cond);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(0, init_fb(
            '0,
            '{1, 1, tgt[0]},
            '0
        ));

        // fb = init_fb(
        //     fb,
        //     '{1, 3, tgt[0]},
        //     '{1, 4, tgt[1], md_cond}
        // );

        $display("\nTest 2: vld = [1, 0]");
        save = init_fb(
            '0,
            '{1, 1, tgt[0]},
            '0
        );

        $display("  2A: udat = {off = br0_off, tgt1, md_cond}");
        udat= init_udat(udat, 1, tgt[1], md_cond);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(0, init_fb(
            '0,
            '{1, 1, tgt[1]},
            '0
        ));

        $display("  2B: udat = {off < br0_off, tgt1, md_cond}");
        udat= init_udat(udat, 0, tgt[1], md_cond);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(0, init_fb(
            '0,
            '{1, 0, tgt[1]},
            '{1, 1, tgt[0], md_cond}
        ));

        $display("  2C: udat = {off > br0_off, tgt1, md_cond}");
        udat= init_udat(udat, 2, tgt[1], md_cond);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(0, init_fb(
            '0,
            '{1, 1, tgt[0]},
            '{1, 2, tgt[1], md_cond}
        ));

        $display("  2A': udat = {off = br0_off, tgt1, md_call}");
        udat= init_udat(udat, 1, tgt[1], md_call);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(0, init_fb(
            '0,
            '0,
            '{1, 1, tgt[1], md_call}
        ));

        $display("  2B': udat = {off < br0_off, tgt1, md_call}");
        udat= init_udat(udat, 0, tgt[1], md_call);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(0, init_fb(
            '0,
            '0,
            '{1, 0, tgt[1], md_call}
        ));

        $display("  2C': udat = {off > br0_off, tgt1, md_call}");
        udat= init_udat(udat, 2, tgt[1], md_call);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(0, init_fb(
            '0,
            '{1, 1, tgt[0]},
            '{1, 2, tgt[1], md_call}
        ));


        $display("\nTest 3: vld = [0, 1]");
        save = init_fb(
            '0,
            '0,
            '{1, 1, tgt[0], md_cond}
        );

        $display("  3A: udat = {off = br1_off, tgt1, md_cond}");
        udat= init_udat(udat, 1, tgt[1], md_cond);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(0, init_fb(
            '0,
            '0,
            '{1, 1, tgt[1], md_cond}
        ));

        $display("  3B: udat = {off < br1_off, tgt1, md_cond}");
        udat= init_udat(udat, 0, tgt[1], md_cond);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(0, init_fb(
            '0,
            '{1, 0, tgt[1]},
            '{1, 1, tgt[0], md_cond}
        ));

        $display("  3C: udat = {off > br1_off, tgt1, md_cond}");
        udat= init_udat(udat, 2, tgt[1], md_cond);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(1, '0);


        $display("  3A': udat = {off = br1_off, tgt1, md_call}");
        udat= init_udat(udat, 1, tgt[1], md_call);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(0, init_fb(
            '0,
            '0,
            '{1, 1, tgt[1], md_call}
        ));

        $display("  3B': udat = {off < br1_off, tgt1, md_call}");
        udat= init_udat(udat, 0, tgt[1], md_call);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(0, init_fb(
            '0,
            '0,
            '{1, 0, tgt[1], md_call}
        ));

        $display("  3C': udat = {off > br1_off, tgt1, md_call}");
        udat= init_udat(udat, 2, tgt[1], md_call);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(1, '0);


        $display("\nTest 4: vld = [1, 1]");
        save = init_fb(
            '0,
            '{1, 1, tgt[0]},
            '{1, 3, tgt[1], md_cond}
        );

        $display("  4A: udat = {off < br0_off, tgt3, md_cond}");
        udat= init_udat(udat, 0, tgt[2], md_cond);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(0, init_fb(
            '0,
            '{1, 0, tgt[2]},
            '{1, 1, tgt[0], md_cond}
        ));

        $display("  4B: udat = {off = br0_off, tgt3, md_cond}");
        udat= init_udat(udat, 1, tgt[2], md_cond);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(0, init_fb(
            '0,
            '{1, 1, tgt[2]},
            '{1, 3, tgt[1], md_cond}
        ));

        $display("  4C: udat = {br0 < off < br1, tgt3, md_cond}");
        udat= init_udat(udat, 2, tgt[2], md_cond);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(0, init_fb(
            '0,
            '{1, 1, tgt[0]},
            '{1, 2, tgt[2], md_cond}
        ));

        $display("  4D: udat = {off = br1_off, tgt3, md_cond}");
        udat= init_udat(udat, 3, tgt[2], md_cond);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(0, init_fb(
            '0,
            '{1, 1, tgt[0]},
            '{1, 3, tgt[2], md_cond}
        ));

        $display("  4E: udat = {off > br1_off, tgt3, md_cond}");
        udat= init_udat(udat, 4, tgt[2], md_cond);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(1, '0);

        $display("  4A': udat = {off < br0_off, tgt3, md_call}");
        udat= init_udat(udat, 0, tgt[2], md_call);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(0, init_fb(
            '0,
            '0,
            '{1, 0, tgt[2], md_call}
        ));

        $display("  4B': udat = {off = br0_off, tgt3, md_call}");
        udat= init_udat(udat, 1, tgt[2], md_call);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(0, init_fb(
            '0,
            '0,
            '{1, 1, tgt[2], md_call}
        ));

        $display("  4C': udat = {br0 < off < br1, tgt3, md_call}");
        udat= init_udat(udat, 2, tgt[2], md_call);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(0, init_fb(
            '0,
            '{1, 1, tgt[0]},
            '{1, 2, tgt[2], md_call}
        ));

        $display("  4D': udat = {off = br1_off, tgt3, md_call}");
        udat= init_udat(udat, 3, tgt[2], md_call);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(0, init_fb(
            '0,
            '{1, 1, tgt[0]},
            '{1, 3, tgt[2], md_call}
        ));

        $display("  4E': udat = {off > br1_off, tgt3, md_call}");
        udat= init_udat(udat, 4, tgt[2], md_call);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(1, '0);

        $display("\nTest 5: vld = [1, 1] (no gap)");
        save = init_fb(
            '0,
            '{1, 1, tgt[0]},
            '{1, 2, tgt[1], md_cond}
        );

        $display("  5A: udat = {off = br0_off, tgt3, md_cond}");
        udat= init_udat(udat, 1, tgt[2], md_cond);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(0, init_fb(
            '0,
            '{1, 1, tgt[2]},
            '{1, 2, tgt[1], md_cond}
        ));

        $display("  5B: udat = {off = br1_off, tgt3, md_cond}");
        udat= init_udat(udat, 2, tgt[2], md_cond);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(0, init_fb(
            '0,
            '{1, 1, tgt[0]},
            '{1, 2, tgt[2], md_cond}
        ));

        $display("  5A': udat = {off = br0_off, tgt3, md_call}");
        udat= init_udat(udat, 1, tgt[2], md_call);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(0, init_fb(
            '0,
            '0,
            '{1, 1, tgt[2], md_call}
        ));

        $display("  5B': udat = {off = br1_off, tgt3, md_call}");
        udat= init_udat(udat, 2, tgt[2], md_call);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(0, init_fb(
            '0,
            '{1, 1, tgt[0]},
            '{1, 2, tgt[2], md_call}
        ));


        $display("\nTest 6: vld = [1, 1] (boundaries)");
        save = init_fb(
            '0,
            '{1, 0, tgt[0]},
            '{1, 15, tgt[1], md_cond}
        );

        $display("  6A: udat = {off = br0_off, tgt3, md_cond}");
        udat= init_udat(udat, 0, tgt[2], md_cond);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(0, init_fb(
            '0,
            '{1, 0, tgt[2]},
            '{1, 15, tgt[1], md_cond}
        ));

        $display("  6B: udat = {br0 < off < br1, tgt3, md_cond}");
        udat= init_udat(udat, 7, tgt[2], md_cond);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(0, init_fb(
            '0,
            '{1, 0, tgt[0]},
            '{1, 7, tgt[2], md_cond}
        ));

        $display("  6C: udat = {off = br1_off, tgt3, md_cond}");
        udat= init_udat(udat, 15, tgt[2], md_cond);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(0, init_fb(
            '0,
            '{1, 0, tgt[0]},
            '{1, 15, tgt[2], md_cond}
        ));

        $display("  6A': udat = {off = br0_off, tgt3, md_call}");
        udat= init_udat(udat, 0, tgt[2], md_call);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(0, init_fb(
            '0,
            '0,
            '{1, 0, tgt[2], md_call}
        ));

        $display("  6B': udat = {br0 < off < br1, tgt3, md_call}");
        udat= init_udat(udat, 7, tgt[2], md_call);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(0, init_fb(
            '0,
            '{1, 0, tgt[0]},
            '{1, 7, tgt[2], md_call}
        ));

        $display("  6C': udat = {off = br1_off, tgt3, md_call}");
        udat= init_udat(udat, 15, tgt[2], md_call);
        fb  = uftb.update_fb(_d, spill, save, udat);
        chk(0, init_fb(
            '0,
            '{1, 0, tgt[0]},
            '{1, 15, tgt[2], md_call}
        ));
`endif

        $finish;
    end


endmodule