// tb_infra.svh — PS VIP DDRC write-commit workaround.
//
// The PS VIP arb_wr_6 module asserts wr_req in the active event region before
// wr_data/wr_strb settle (inactive region race).  This initial block intercepts
// every wr_req rising edge, waits 1 ns, then directly commits each byte-enabled
// byte into ddr_mem0/ddr_mem1 — the same arrays that read_mem() reads.
initial begin : ddrc_wr_fix
    int unsigned nb, boff;
    logic [39:0] ba;
    logic [31:0] wa;
    logic [ 7:0] bd;
    logic [31:0] tmp_word;
    forever begin
        @(posedge dut.zynq_ultra_ps_e_0.inst.ddrc.wr_req);
        #1;
        nb = int'(dut.zynq_ultra_ps_e_0.inst.ddrc.wr_bytes);
        for (int b = 0; b < nb; b++) begin
            if (dut.zynq_ultra_ps_e_0.inst.ddrc.wr_strb[b]) begin
                ba   = dut.zynq_ultra_ps_e_0.inst.ddrc.wr_addr + 40'(b);
                wa   = ba[33:2];
                boff = int'(ba[1:0]);
                bd   = dut.zynq_ultra_ps_e_0.inst.ddrc.wr_data[b*8 +: 8];
                if (wa[28] == 1'b0) begin
                    tmp_word = dut.zynq_ultra_ps_e_0.inst.ddrc.ddr.ddr_mem0[wa[27:0]];
                    tmp_word[boff*8 +: 8] = bd;
                    dut.zynq_ultra_ps_e_0.inst.ddrc.ddr.ddr_mem0[wa[27:0]] = tmp_word;
                end else begin
                    tmp_word = dut.zynq_ultra_ps_e_0.inst.ddrc.ddr.ddr_mem1[wa[27:0]];
                    tmp_word[boff*8 +: 8] = bd;
                    dut.zynq_ultra_ps_e_0.inst.ddrc.ddr.ddr_mem1[wa[27:0]] = tmp_word;
                end
            end
        end
    end
end
