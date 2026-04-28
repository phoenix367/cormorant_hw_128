`timescale 1ns / 1ps

// Interface passed to each monitor so class files contain no DUT references.
interface irq_if;
    logic sig;
endinterface

module cormorant_tb;

    // -----------------------------------------------------------------------
    // DUT and PS VIP macro
    // -----------------------------------------------------------------------
    design_cormorant dut ();
    `define PS dut.zynq_ultra_ps_e_0.inst
    `include "cormorant_addr_map.svh"
    `include "vop_regmap.svh"

    // -----------------------------------------------------------------------
    // Testbench parameters
    // -----------------------------------------------------------------------
    localparam int unsigned ELEM_BYTES  = 2;       // sizeof(ap_fixed<16,8>)
    localparam int unsigned CHUNK_BYTES = 1024;    // PS VIP transfer chunk (bytes)
    localparam int unsigned CHUNK_BITS  = CHUNK_BYTES * 8;
    localparam [15:0]       POISON      = 16'hDEAD;
    localparam int unsigned MEM_GAP     = 64 * 1024;  // guard gap between DDR tensors

    `include "conv_regmap.svh"
    `include "mm_regmap.svh"
    `include "pk_regmap.svh"

    // -----------------------------------------------------------------------
    // Shared utilities, base classes, and per-kernel OOP class hierarchies
    // -----------------------------------------------------------------------
    `include "tb_functions.svh"
    `include "axil_agent.svh"
    `include "base_scoreboard.svh"
    `include "vop_classes.svh"
    `include "conv_classes.svh"
    `include "mm_classes.svh"
    `include "pk_classes.svh"
    `include "tb_infra.svh"

    // -----------------------------------------------------------------------
    // DUT interrupt signal wiring — all DUT references are concentrated here
    // -----------------------------------------------------------------------
    irq_if vop_irq_if(); assign vop_irq_if.sig = dut.VectorOPKernel_0_interrupt;
    irq_if conv_irq_if(); assign conv_irq_if.sig = dut.ConvKernel_0_interrupt;
    irq_if mm_irq_if();   assign mm_irq_if.sig   = dut.MatmulKernel_0_interrupt;
    irq_if pk_irq_if();   assign pk_irq_if.sig   = dut.PoolingKernel_0_interrupt;

    // -----------------------------------------------------------------------
    // Top-level test handles
    // -----------------------------------------------------------------------
    vop_test        vt;
    conv_test       ct;
    mm_test         mt;
    pk_test         pt;
    base_scoreboard all_scbs[$];

    // -----------------------------------------------------------------------
    // Main: PS VIP reset sequence → run all kernel tests → overall report
    // -----------------------------------------------------------------------
    initial begin
        `PS.set_stop_on_error(1);
        `PS.set_debug_level_info(1);

        // POR + system reset, then PL fabric reset.
        `PS.por_srstb_reset(1'b0);   // assert  → DDR model enters reset
        `PS.fpga_soft_reset(32'hF);  // assert PL resets
        #500;
        `PS.por_srstb_reset(1'b1);   // deassert → DDR model comes up cleanly
        #800;
        `PS.fpga_soft_reset(32'h0);  // deassert PL resets → interconnect starts
        #900;

        // BEST_CASE (fixed 21-cycle) write-response latency on HPC0_FPD.
        `PS.set_slave_profile("S_AXI_HPC0_FPD", 0);

        // HLS-generated 128-bit AXI masters leave WSTRB registers uninitialised
        // (X) in simulation before the first write beat is issued.  This is a
        // harmless simulation artefact — real hardware always drives valid byte
        // enables.  Suppress the AXI4_ERRM_WSTRB_X false-positive on the HPC0
        // protocol checker for the duration of the simulation.
        //$assertoff(0, cormorant_tb.dut.zynq_ultra_ps_e_0.inst
        //                .S_AXI_HPC0_FPD.slave.IF.PC.axi4_errm_wstrb_x);

        vt = new(vop_irq_if); vt.run();
        ct = new(conv_irq_if); ct.run();
        mt = new(mm_irq_if);   mt.run();
        pt = new(pk_irq_if);   pt.run();

        // Collect scoreboards for the overall report.
        all_scbs.push_back(vt.e.scb);
        all_scbs.push_back(ct.e.scb);
        all_scbs.push_back(mt.e.scb);
        all_scbs.push_back(pt.e.scb);

        begin
            int unsigned total = 0, passed = 0, failed = 0;
            foreach (all_scbs[i]) begin
                total  += all_scbs[i].total_tests;
                passed += all_scbs[i].pass_cnt;
                failed += all_scbs[i].fail_cnt;
            end
            $display("");
            $display("##########################################################");
            $display("##  CORMORANT TESTBENCH — OVERALL RESULTS");
            $display("##########################################################");
            foreach (all_scbs[i])
                $display("##  %-20s  %3d / %3d  (%0d failed)",
                         all_scbs[i].kernel_name(),
                         all_scbs[i].pass_cnt,
                         all_scbs[i].total_tests,
                         all_scbs[i].fail_cnt);
            $display("##########################################################");
            $display("##  TOTAL: %0d / %0d passed", passed, total);
            if (failed == 0)
                $display("##  ALL TESTS PASSED");
            else
                $display("##  %0d TEST(S) FAILED  *** SIMULATION FAILED ***", failed);
            $display("##########################################################");
        end

        $finish;
    end

endmodule
