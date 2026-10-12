// tb_infra.svh — PS VIP DDRC write-commit workaround.
//
// The PS VIP arb_wr_6 module asserts wr_req in the active event region before
// wr_data/wr_strb settle (inactive region race), so the DDRC's own
// ddr.write_mem() may commit a mix of the previous transfer's address, byte
// count and data with the new one's — observed on the HP0 port as stale or
// zero bytes just past a burst's end (the previous transfer's byte count
// applied at the new address), where this bench poisons and checks every
// byte.  This initial block intercepts every wr_req rising edge, waits 1 ns
// for the settled values, then commits the transfer's strobed bytes directly
// into ddr_mem0/ddr_mem1 (the arrays read_mem() reads), restores its
// unstrobed bytes, and restores every byte the racing write could have
// touched — the previous transfer's range and the 32 bytes past either
// range — from the shadow of everything written (tb_functions.svh
// shadow_mem: every backdoor write and every strobed beat).
initial begin : ddrc_wr_fix
    int unsigned nb, boff, prev_nb;
    logic [39:0] ba, cur_addr, prev_addr;
    logic [31:0] wa;
    logic [ 7:0] bd;
    logic [31:0] tmp_word;
    prev_addr = '0;
    prev_nb   = 0;
    forever begin
        @(posedge dut.zynq_ultra_ps_e_0.inst.ddrc.wr_req);
        #1;
        nb       = int'(dut.zynq_ultra_ps_e_0.inst.ddrc.wr_bytes);
        cur_addr = dut.zynq_ultra_ps_e_0.inst.ddrc.wr_addr;
        // the transfer itself: strobed bytes committed (and shadowed), the rest restored
        for (int b = 0; b < nb; b++) begin
            ba = cur_addr + 40'(b);
            if (dut.zynq_ultra_ps_e_0.inst.ddrc.wr_strb[b]) begin
                bd = dut.zynq_ultra_ps_e_0.inst.ddrc.wr_data[b*8 +: 8];
                shadow_mem[longint'(ba)] = bd;
            end else if (shadow_mem.exists(longint'(ba))) begin
                bd = shadow_mem[longint'(ba)];     // undo the VIP's racing write
            end else begin
                continue;
            end
            ddr_poke(ba, bd);
        end
        // what the racing write may have clobbered: past this transfer, and the
        // previous transfer's range (its byte count applied at the new address,
        // or the new data at its address) plus 32 bytes
        for (int b = 0; b < 32; b++) ddr_restore(cur_addr + 40'(nb) + 40'(b));
        for (int b = 0; b < int'(prev_nb) + 32; b++) begin
            ba = prev_addr + 40'(b);
            if (ba < cur_addr || ba >= cur_addr + 40'(nb)) ddr_restore(ba);
        end
        for (int b = 0; b < int'(prev_nb) + 32; b++) begin
            ba = cur_addr + 40'(b);
            if (ba >= cur_addr + 40'(nb)) ddr_restore(ba);
        end
        prev_addr = cur_addr;
        prev_nb   = nb;
    end
end

// one byte into the VIP's DDR arrays (32-bit words, two halves of 1 GiB)
function automatic void ddr_poke(input logic [39:0] ba, input logic [7:0] bd);
    logic [31:0] wa, tmp_word;
    int unsigned boff;
    wa   = ba[33:2];
    boff = int'(ba[1:0]);
    if (wa[28] == 1'b0) begin
        tmp_word = dut.zynq_ultra_ps_e_0.inst.ddrc.ddr.ddr_mem0[wa[27:0]];
        tmp_word[boff*8 +: 8] = bd;
        dut.zynq_ultra_ps_e_0.inst.ddrc.ddr.ddr_mem0[wa[27:0]] = tmp_word;
    end else begin
        tmp_word = dut.zynq_ultra_ps_e_0.inst.ddrc.ddr.ddr_mem1[wa[27:0]];
        tmp_word[boff*8 +: 8] = bd;
        dut.zynq_ultra_ps_e_0.inst.ddrc.ddr.ddr_mem1[wa[27:0]] = tmp_word;
    end
endfunction

// a byte back to its last written value, when one is known
function automatic void ddr_restore(input logic [39:0] ba);
    if (shadow_mem.exists(longint'(ba))) ddr_poke(ba, shadow_mem[longint'(ba)]);
endfunction
