// vop_classes.svh — VectorOPKernel testbench classes.

// =========================================================================
// vop_item — one complete VectorOPKernel call
// =========================================================================
class vop_item;
    string       label;
    logic [31:0] op;
    int unsigned size;    // elements per outer iteration
    int unsigned outer;   // number of broadcast iterations
    int unsigned a_inc;   // element stride between A-row starts
    int unsigned b_inc;   // element stride between B-row starts (0 = broadcast)
    logic [31:0] act;     // fused activation after the op (Act code, ACT_NONE = 0)
    logic [31:0] alpha;   // LeakyReLU slope, alpha[15:0] / 65536
    logic [31:0] smx_cm   = 32'h0;   // softmax registers (set_smx)
    logic [31:0] smx_cfg  = 32'h0;
    logic [31:0] smx_mask = 32'h0;

    // a_fills[i] / b_fills[i]: fill value per outer row (length == outer).
    logic [15:0] a_fills[];
    logic [15:0] b_fills[];

    logic [39:0] addr_a;
    logic [39:0] addr_b;   // 40'h0 for unary ops (op >= RELU)
    logic [39:0] addr_c;

    // Expected C value per outer row; all `size` elements in a row are equal.
    logic [15:0] exp_c[];

    function new(
        string       lbl,
        logic [31:0] op_,
        int unsigned size_,
        int unsigned outer_  = 1,
        int unsigned a_inc_  = 0,
        int unsigned b_inc_  = 0,
        logic [15:0] a_val   = 16'h0100,
        logic [15:0] b_val_  = 16'h0000,
        logic [31:0] act_    = ACT_NONE,
        logic [31:0] alpha_  = 32'h0
    );
        this.label  = lbl;
        this.op     = op_;
        this.size   = size_;
        this.outer  = outer_;
        this.a_inc  = a_inc_;
        this.b_inc  = b_inc_;
        this.act    = act_;
        this.alpha  = alpha_;
        this.addr_a = BUF_A;
        this.addr_b = (op_ >= OP_RELU) ? 40'h0 : BUF_B;
        this.addr_c = BUF_C;

        a_fills = new[outer_];
        b_fills = new[outer_];
        exp_c   = new[outer_];
        for (int i = 0; i < int'(outer_); i++) begin
            a_fills[i] = a_val;
            b_fills[i] = b_val_;
            exp_c[i]   = compute_ref(op_, a_val, b_val_, act_);
        end
    endfunction

    function void set_a_row(int unsigned row, logic [15:0] val);
        a_fills[row] = val;
        exp_c[row]   = compute_ref(op, val, b_fills[row], act);
    endfunction

    function void set_b_row(int unsigned row, logic [15:0] val);
        b_fills[row] = val;
        exp_c[row]   = compute_ref(op, a_fills[row], val, act);
    endfunction

    // The SiLU / GELU / LeakyReLU results compute_ref does not model: the
    // expected value of a row, taken from the C++ model (VectorOP.h).
    function void set_exp_row(int unsigned row, logic [15:0] val);
        exp_c[row] = val;
    endfunction

    // A softmax call: its registers and the value of every output element
    // (all inputs equal: P = 1 / valid length).
    function void set_smx(logic [31:0] cm, logic [31:0] cfg, logic [31:0] mask, logic [15:0] p);
        smx_cm   = cm;
        smx_cfg  = cfg;
        smx_mask = mask;
        foreach (exp_c[i]) exp_c[i] = p;
    endfunction

    function bit is_smx();
        return op == OP_SOFTMAX || op == OP_SOFTMAX_T;
    endfunction

    // output rows (column mode: outer & ~15) and their stride
    function int unsigned c_rows();
        return (op == OP_SOFTMAX_T) ? (outer & ~32'd15) : outer;
    endfunction

    function int unsigned c_inc();
        return is_smx() ? b_inc : a_inc + b_inc;
    endfunction

    function string to_string();
        return $sformatf(
            "%-16s  op=%0d act=%0d alpha=0x%0h size=%0d outer=%0d a_inc=%0d b_inc=%0d  a[0]=0x%04h b[0]=0x%04h  exp[0]=0x%04h",
            label, op, act, alpha, size, outer, a_inc, b_inc, a_fills[0], b_fills[0], exp_c[0]);
    endfunction
endclass

// =========================================================================
// vop_driver
// =========================================================================
class vop_driver extends axil_agent;
    function new(); super.new("VOP_DRV"); endfunction

    task run(vop_item item);
        int unsigned a_row_bytes, b_bytes, c_bytes, c_inc, a_rows;
        logic [39:0] row_base;

        $display("[%0t][VOP_DRV] %s", $time, item.to_string());

        a_row_bytes = (item.a_inc > 0) ?
            item.a_inc * ELEM_BYTES : item.size * ELEM_BYTES;
        if (a_row_bytes < 16) a_row_bytes = 16;
        // column-mode softmax: size key rows (every one the first fill)
        a_rows = (item.op == OP_SOFTMAX_T) ? item.size : item.outer;
        $display("[%0t][VOP_DRV] Loading A (%0d rows × %0d B) ...",
                 $time, a_rows, a_row_bytes);
        for (int i = 0; i < int'(a_rows); i++) begin
            row_base = item.addr_a;
            if (item.a_inc > 0)
                row_base += 40'(i) * 40'(item.a_inc) * 40'(ELEM_BYTES);
            fill_const_ddr(row_base, a_row_bytes,
                           item.a_fills[(item.op == OP_SOFTMAX_T) ? 0 : i]);
        end

        if (item.addr_b != 40'h0) begin
            if (item.b_inc > 0) begin
                b_bytes = item.b_inc * ELEM_BYTES;
                if (b_bytes < 16) b_bytes = 16;
                $display("[%0t][VOP_DRV] Loading B (%0d rows × %0d B) ...",
                         $time, item.outer, b_bytes);
                for (int i = 0; i < int'(item.outer); i++) begin
                    row_base = item.addr_b
                             + 40'(i) * 40'(item.b_inc) * 40'(ELEM_BYTES);
                    fill_const_ddr(row_base, b_bytes, item.b_fills[i]);
                end
            end else begin
                b_bytes = item.size * ELEM_BYTES;
                if (b_bytes < 64) b_bytes = 64;
                $display("[%0t][VOP_DRV] Loading B (%0d B, val=0x%04h) ...",
                         $time, b_bytes, item.b_fills[0]);
                fill_const_ddr(item.addr_b, b_bytes, item.b_fills[0]);
            end
        end

        c_inc   = item.c_inc();
        c_bytes = (c_inc > 0) ?
            item.outer * c_inc * ELEM_BYTES : item.size * ELEM_BYTES;
        if (c_bytes < 16) c_bytes = 16;
        $display("[%0t][VOP_DRV] Poisoning C (%0d B) with 0x%04h ...",
                 $time, c_bytes, POISON);
        fill_const_ddr(item.addr_c, c_bytes, POISON);

        $display("[%0t][VOP_DRV] Programming registers ...", $time);
        axil_write(REG_A_LO,  item.addr_a[31:0]);
        axil_write(REG_A_HI,  {24'h0, item.addr_a[39:32]});
        axil_write(REG_B_LO,  item.addr_b[31:0]);
        axil_write(REG_B_HI,  {24'h0, item.addr_b[39:32]});
        axil_write(REG_C_LO,  item.addr_c[31:0]);
        axil_write(REG_C_HI,  {24'h0, item.addr_c[39:32]});
        axil_write(REG_SIZE,  32'(item.size));
        axil_write(REG_OP,    item.op);
        axil_write(REG_OUTER, 32'(item.outer));
        axil_write(REG_A_INC, 32'(item.a_inc));
        axil_write(REG_B_INC, 32'(item.b_inc));
        axil_write(REG_ACT,   item.act);        // always: registers persist between tests
        axil_write(REG_ALPHA, item.alpha);
        axil_write(REG_SMX_CM,   item.smx_cm);
        axil_write(REG_SMX_CFG,  item.smx_cfg);
        axil_write(REG_SMX_MASK, item.smx_mask);
        axil_write(REG_GIE,     32'h1);
        axil_write(REG_IER,     32'h1);
        $display("[%0t][VOP_DRV] Asserting ap_start ...", $time);
        axil_write(REG_AP_CTRL, 32'h1);
    endtask
endclass

// =========================================================================
// vop_monitor
// =========================================================================
class vop_monitor extends axil_agent;
    local int unsigned irq_ch;
    virtual irq_if     irq;

    function new(virtual irq_if i, int unsigned ch = 0, string tag = "VOP_MON");
        super.new(tag);
        this.irq    = i;
        this.irq_ch = ch;
    endfunction

    task run(vop_item item);
        logic [15:0] irq_status;
        logic [31:0] isr_val, ap_ctrl_val;

        $display("[%0t][VOP_MON] Waiting for interrupt ...", $time);
        irq_status = 16'h0;
        fork
            begin : irq_wait
                `PS.wait_interrupt(4'(irq_ch), irq_status);
            end
            begin : irq_timeout
                #500_000_000;
            end
        join_any
        disable fork;

        if (!irq_status[irq_ch]) begin
            $error("[%0t][VOP_MON] TIMEOUT: no interrupt after 500 ms  test=%s",
                   $time, item.label);
            $finish;
        end
        $display("[%0t][VOP_MON] Interrupt received (irq_status=0x%04h)", $time, irq_status);

        axil_read(REG_AP_CTRL, ap_ctrl_val);
        $display("[%0t][VOP_MON] ap_ctrl=0x%08h  done=%0b  idle=%0b  ready=%0b",
                 $time, ap_ctrl_val, ap_ctrl_val[1], ap_ctrl_val[2], ap_ctrl_val[3]);

        axil_read(REG_ISR, isr_val);
        $display("[%0t][VOP_MON] ISR=0x%08h  ap_done=%0b  ap_ready=%0b",
                 $time, isr_val, isr_val[0], isr_val[1]);
        axil_write(REG_ISR, isr_val);
        axil_write(REG_GIE, 32'h0);

        if (irq.sig) begin
            $display("[%0t][VOP_MON] Waiting for interrupt line to deassert ...", $time);
            @(negedge irq.sig);
        end
        $display("[%0t][VOP_MON] Interrupt line low - ready for next test.", $time);
    endtask
endclass

// =========================================================================
// vop_scoreboard
// =========================================================================
class vop_scoreboard extends base_scoreboard;
    virtual function string kernel_name(); return "VectorOPKernel"; endfunction

    task run(vop_item item);
        logic [CHUNK_BITS-1:0] rd_buf;
        int unsigned c_inc, row_bytes, read_bytes, errors, total_elems;
        logic [39:0] row_base;
        logic [15:0] got;

        c_inc       = item.c_inc();
        row_bytes   = (c_inc > 0) ? c_inc * ELEM_BYTES : item.size * ELEM_BYTES;
        total_elems = item.c_rows() * item.size;
        errors      = 0;

        read_bytes = item.size * ELEM_BYTES;
        if (read_bytes < 4) read_bytes = 4;
        if (read_bytes % 4 != 0) read_bytes += 4 - (read_bytes % 4);

        $display("[%0t][VOP_SCB] Verifying C (%0d outer × %0d elem = %0d total)  exp[0]=0x%04h ...",
                 $time, item.outer, item.size, total_elems, item.exp_c[0]);

        for (int row = 0; row < int'(item.c_rows()); row++) begin
            row_base = item.addr_c + 40'(row) * 40'(row_bytes);
            `PS.read_mem(row_base, read_bytes, rd_buf);
            for (int e = 0; e < int'(item.size); e++) begin
                got = rd_buf[e*16 +: 16];
                if (got !== item.exp_c[row]) begin
                    if (errors < 5)
                        $display(
                            "[%0t][VOP_SCB] MISMATCH row=%0d e=%0d: got=0x%04X (%.4f)  exp=0x%04X (%.4f)",
                            $time, row, e,
                            got,             $itor($signed(got))             / 256.0,
                            item.exp_c[row], $itor($signed(item.exp_c[row])) / 256.0);
                    errors++;
                end
            end
        end

        total_tests++;
        if (errors == 0) begin
            pass_cnt++;
            $display("[%0t][VOP_SCB] PASS  %-16s  outer=%0d size=%0d op=%0d",
                     $time, item.label, item.outer, item.size, item.op);
        end else begin
            fail_cnt++;
            $display("[%0t][VOP_SCB] FAIL  %-16s  %0d/%0d mismatches",
                     $time, item.label, errors, total_elems);
        end
    endtask
endclass

// =========================================================================
// vop_env
// =========================================================================
class vop_env;
    vop_driver     drv;
    vop_monitor    mon;
    vop_scoreboard scb;

    function new(virtual irq_if irq);
        drv = new();
        mon = new(irq, 0);
        scb = new();
    endfunction

    task run_one(vop_item item);
        drv.run(item);
        mon.run(item);
        scb.run(item);
    endtask
endclass

// =========================================================================
// vop_test — 29 test cases covering all ops, fused activations, saturation,
// broadcasting and the softmax.  Alignment contract (VectorOP.h): every run start of a,
// b, c is 16-byte aligned, so a_inc / b_inc are 0 or multiples of 8 elements.
//
// Expected value reference  (raw = real × 256):
//   ADD:     0x0200+0x0180=0x0380 (2.0+1.5=3.5)
//   SUB:     0x0400-0x0100=0x0300 (4.0-1.0=3.0)
//   MUL:     0x0200×0x0300>>>8=0x60000>>>8=0x0600 (2.0×3.0=6.0)
//   DIV:     (0x0600<<8)/0x0200=0x060000/512=0x0300 (6.0/2.0=3.0)
//   RELU:    0xFF00(-1.0)→0x0000;  0x0200(2.0)→0x0200
//   RELU6:   0x0800(8.0)→0x0600;  0x0300(3.0)→0x0300
//   sat+:    0x6400+0x6400=0xC800 > 0x7FFF → 0x7FFF
//   sat-:    0xFE00×0x6400=-512×25600=-13107200; >>>8=-51200 → 0x8000
//   act:     ADD 1.0 + -2.0 = -1.0 → relu 0x0000;  ADD 4.0 + 4.0 = 8.0 → relu6 0x0600
//   activation unit (round to nearest, ties to even): GELU(1.0) = 0.8413 → 0x00D7;
//            SiLU(-1.0, 2.5, 9.0) → 0xFFBB, 0x024F, 0x0900;  LeakyReLU(-2.0, alpha
//            0x199A = 0.1) = -0.2000 → 0xFFCD;  GELU_tanh(0.5) → 0x0059;  SiLU(1.5) → 0x013A
// =========================================================================
class vop_test;
    vop_env        e;
    virtual irq_if irq;

    function new(virtual irq_if i); this.irq = i; endfunction

    task run();
        vop_item tests[$];
        vop_item it;
        int unsigned n;
        e = new(irq);

        // ---- Scalar binary operations (outer=1, size=8) -----------------
        it = new("add_basic",   OP_ADD,   8, .a_val(16'h0200), .b_val_(16'h0180));
        tests.push_back(it);
        it = new("sub_basic",   OP_SUB,   8, .a_val(16'h0400), .b_val_(16'h0100));
        tests.push_back(it);
        it = new("mul_basic",   OP_MUL,   8, .a_val(16'h0200), .b_val_(16'h0300));
        tests.push_back(it);
        it = new("div_basic",   OP_DIV,   8, .a_val(16'h0600), .b_val_(16'h0200));
        tests.push_back(it);

        // ---- Unary activation (outer=1, size=8) -------------------------
        it = new("relu_neg",    OP_RELU,  8, .a_val(16'hFF00));
        tests.push_back(it);
        it = new("relu_pos",    OP_RELU,  8, .a_val(16'h0200));
        tests.push_back(it);
        it = new("relu6_clip",  OP_RELU6, 8, .a_val(16'h0800));
        tests.push_back(it);
        it = new("relu6_below", OP_RELU6, 8, .a_val(16'h0300));
        tests.push_back(it);

        // ---- Saturation -------------------------------------------------
        it = new("sat_add_pos", OP_ADD,   8, .a_val(16'h6400), .b_val_(16'h6400));
        tests.push_back(it);
        it = new("sat_mul_neg", OP_MUL,   8, .a_val(16'hFE00), .b_val_(16'h6400));
        tests.push_back(it);

        // ---- Size variation (outer=1, no broadcasting) ------------------
        it = new("size4_add",   OP_ADD,   4, .a_val(16'h0200), .b_val_(16'h0180));
        tests.push_back(it);
        it = new("size16_mul",  OP_MUL,  16, .a_val(16'h0200), .b_val_(16'h0300));
        tests.push_back(it);
        it = new("size32_sub",  OP_SUB,  32, .a_val(16'h0400), .b_val_(16'h0100));
        tests.push_back(it);

        // ---- A advances, B broadcasts (a_inc>0, b_inc=0) ----------------
        // row 0: a=1.0+b=0.5→1.5;  row 1: a=2.0+b=0.5→2.5
        it = new("bcast_add",     OP_ADD,  8, /*outer*/2, /*a_inc*/8, /*b_inc*/0,
                 16'h0100, 16'h0080);
        it.set_a_row(1, 16'h0200);
        tests.push_back(it);

        // worst-case gap; a=1.0 b=0.25→1.25 for all 4 rows
        it = new("chunk_one",     OP_ADD,  1, /*outer*/4, /*a_inc*/8, /*b_inc*/0,
                 16'h0100, 16'h0040);
        tests.push_back(it);

        // row 0: a=1.0+b=0.5→1.5;  row 1: a=2.0+b=0.5→2.5
        it = new("bcast_add_s16", OP_ADD, 16, /*outer*/2, /*a_inc*/16, /*b_inc*/0,
                 16'h0100, 16'h0080);
        it.set_a_row(1, 16'h0200);
        tests.push_back(it);

        // ---- B advances, A broadcasts (a_inc=0, b_inc>0) ----------------
        // row 0: 6.0÷3.0→2.0;  row 1: 6.0÷2.0→3.0
        it = new("bcast_b_div",   OP_DIV,  8, /*outer*/2, /*a_inc*/0, /*b_inc*/8,
                 16'h0600, 16'h0300);
        it.set_b_row(1, 16'h0200);
        tests.push_back(it);

        // row 0: +0.5→1.5;  row 1: +1.0→2.0;  row 2: +2.0→3.0
        it = new("bcast_b_add",   OP_ADD,  8, /*outer*/3, /*a_inc*/0, /*b_inc*/8,
                 16'h0100, 16'h0080);
        it.set_b_row(1, 16'h0100);
        it.set_b_row(2, 16'h0200);
        tests.push_back(it);

        // ---- Both A and B advance (a_inc>0, b_inc>0) --------------------
        // row 0: a=2.0×b=3.0→6.0;  row 1: a=1.0×b=4.0→4.0
        it = new("bcast_both_mul", OP_MUL, 8, /*outer*/2, /*a_inc*/8, /*b_inc*/8,
                 16'h0200, 16'h0300);
        it.set_a_row(1, 16'h0100);
        it.set_b_row(1, 16'h0400);
        tests.push_back(it);

        // ---- Unary broadcast (a_inc>0, b_inc=0) -------------------------
        // row 0: a=-2.0→0.0;  row 1: a=4.0→4.0;  row 2: a=10.0→6.0
        // (size 4 < a_inc 8: each output run's last word is written whole,
        // tail lanes 0, inside the 8-element row gap)
        it = new("bcast_relu6",   OP_RELU6, 4, /*outer*/3, /*a_inc*/8, /*b_inc*/0,
                 16'hFE00);
        it.set_a_row(1, 16'h0400);
        it.set_a_row(2, 16'h0A00);
        tests.push_back(it);

        // ---- Fused activation (register act) ----------------------------
        it = new("add_act_relu",  OP_ADD, 8, .a_val(16'h0100), .b_val_(16'hFE00),
                 .act_(ACT_RELU));
        tests.push_back(it);
        it = new("add_act_relu6", OP_ADD, 8, .a_val(16'h0400), .b_val_(16'h0400),
                 .act_(ACT_RELU6));
        tests.push_back(it);

        // ---- Activation unit: SiLU / GELU / LeakyReLU (expected values from
        // the C++ model: round to nearest, ties to even) -----------------------
        it = new("gelu_op", OP_GELU, 16, .a_val(16'h0100));            // GELU(1.0)
        it.set_exp_row(0, 16'h00D7);
        tests.push_back(it);
        it = new("silu_bcast", OP_SILU, 4, /*outer*/3, /*a_inc*/8, /*b_inc*/0,
                 16'hFF00);                                             // -1.0, 2.5, 9.0
        it.set_a_row(1, 16'h0280);
        it.set_a_row(2, 16'h0900);
        it.set_exp_row(0, 16'hFFBB);
        it.set_exp_row(1, 16'h024F);
        it.set_exp_row(2, 16'h0900);
        tests.push_back(it);
        it = new("leaky_op", OP_LEAKY_RELU, 8, .a_val(16'hFE00),
                 .alpha_(32'h0000_199A));                               // -2.0 x 0.1
        it.set_exp_row(0, 16'hFFCD);
        tests.push_back(it);
        it = new("add_act_gelu_t", OP_ADD, 8, .a_val(16'h0100), .b_val_(16'hFF80),
                 .act_(ACT_GELU_TANH));                                 // GELU_tanh(0.5)
        it.set_exp_row(0, 16'h0059);
        tests.push_back(it);
        it = new("div_act_silu", OP_DIV, 8, .a_val(16'h0300), .b_val_(16'h0200),
                 .act_(ACT_SILU));                                      // SiLU(1.5)
        it.set_exp_row(0, 16'h013A);
        tests.push_back(it);

        // ---- Softmax (equal inputs: P = 1 / n; Cm / Cs of scores at 2^-8,
        //      P at 2^-8) ---------------------------------------------------
        it = new("softmax_rows", OP_SOFTMAX, 8, .outer_(2), .a_inc_(8), .b_inc_(8),
                 .a_val(16'h0180));
        it.set_smx(32'd12102203, 32'h0813, 32'd8, 16'h0020);           // 1/8
        tests.push_back(it);
        it = new("softmax_cols", OP_SOFTMAX_T, 16, .outer_(16), .a_inc_(16), .b_inc_(16),
                 .a_val(16'hFE40));
        it.set_smx(32'd12102203, 32'h0813, 32'd16, 16'h0010);          // 16 keys: 1/16
        tests.push_back(it);

        // ---- Run all tests ----------------------------------------------
        n = tests.size();
        $display("==========================================================");
        $display(" VectorOPKernel Testbench  -  %0d test cases  ap_fixed<16,8>", n);
        $display("==========================================================");
        foreach (tests[i]) begin
            $display("----------------------------------------------------------");
            $display(" Test %0d / %0d : %s", i+1, n, tests[i].to_string());
            $display("----------------------------------------------------------");
            e.run_one(tests[i]);
        end
        e.scb.print_summary();
    endtask
endclass
