// conv_classes.svh — ConvKernel testbench classes.
//
// DDR layout (base 0x2000_0000, gaps of MEM_GAP between tensors):
//   addr_x | x_bytes + MEM_GAP | addr_w | w_bytes + MEM_GAP |
//   addr_b | b_bytes + MEM_GAP | addr_y
//
// Standard:  n_active = in_ch × kh × kw
// Depthwise: n_active = kh × kw  (weight shape: out_ch × 1 × kh × kw)

// =========================================================================
// conv_item
// =========================================================================
class conv_item;
    int unsigned batch;
    int unsigned in_ch, in_h, in_w;
    int unsigned out_ch, out_h, out_w;
    int unsigned kh, kw;
    int unsigned stride_h, stride_w;
    int unsigned dilation_h, dilation_w;
    int unsigned pad_top, pad_left;
    int unsigned has_bias;
    int unsigned is_depthwise;

    logic [15:0] x_val;
    logic [15:0] w_val;
    logic [15:0] b_val;
    logic [15:0] y_expected;

    logic [39:0] addr_x;
    logic [39:0] addr_w;
    logic [39:0] addr_b;
    logic [39:0] addr_y;

    string label;

    function new(
        string         lbl,
        int unsigned   batch_,
        int unsigned   in_ch_,      int unsigned in_h_,      int unsigned in_w_,
        int unsigned   out_ch_,     int unsigned out_h_,     int unsigned out_w_,
        int unsigned   kh_,         int unsigned kw_,
        int unsigned   stride_h_   = 1, int unsigned stride_w_   = 1,
        int unsigned   dilation_h_ = 1, int unsigned dilation_w_ = 1,
        int unsigned   pad_top_    = 0, int unsigned pad_left_   = 0,
        int unsigned   has_bias_   = 0,
        logic [15:0]   x_          = 16'h0100,
        logic [15:0]   w_          = 16'h0100,
        logic [15:0]   b_          = 16'h0000,
        int unsigned   is_depthwise_ = 0
    );
        int unsigned x_bytes, w_bytes, b_bytes, n_active;

        this.label       = lbl;
        this.batch       = batch_;
        this.in_ch       = in_ch_;
        this.in_h        = in_h_;
        this.in_w        = in_w_;
        this.out_ch      = out_ch_;
        this.out_h       = out_h_;
        this.out_w       = out_w_;
        this.kh          = kh_;
        this.kw          = kw_;
        this.stride_h    = stride_h_;
        this.stride_w    = stride_w_;
        this.dilation_h  = dilation_h_;
        this.dilation_w  = dilation_w_;
        this.pad_top     = pad_top_;
        this.pad_left    = pad_left_;
        this.has_bias    = has_bias_;
        this.x_val       = x_;
        this.w_val       = w_;
        this.b_val       = b_;
        this.is_depthwise = is_depthwise_;

        n_active = (is_depthwise_ ? 1 : in_ch_) * kh_ * kw_;
        this.y_expected = compute_conv_const(x_, w_, n_active, b_, logic'(has_bias_));

        x_bytes = align_up(batch_ * in_ch_ * in_h_ * in_w_ * ELEM_BYTES, 16);
        w_bytes = align_up(out_ch_ * (is_depthwise_ ? 1 : in_ch_) * kh_ * kw_ * ELEM_BYTES, 16);
        b_bytes = align_up(out_ch_ * ELEM_BYTES, 16);

        this.addr_x = 40'h2000_0000;
        this.addr_w = this.addr_x + 40'(x_bytes) + 40'(MEM_GAP);
        this.addr_b = this.addr_w + 40'(w_bytes) + 40'(MEM_GAP);
        this.addr_y = this.addr_b + 40'(b_bytes) + 40'(MEM_GAP);
    endfunction

    function string to_string();
        return $sformatf(
            "%-32s  N=%0d IC=%0d IH=%0d IW=%0d  OC=%0d OH=%0d OW=%0d  k=%0dx%0d s=%0dx%0d d=%0dx%0d p=%0d,%0d  bias=%0d dw=%0d  x=0x%04h w=0x%04h  exp_y=0x%04h",
            label, batch, in_ch, in_h, in_w, out_ch, out_h, out_w,
            kh, kw, stride_h, stride_w, dilation_h, dilation_w,
            pad_top, pad_left, has_bias, is_depthwise, x_val, w_val, y_expected);
    endfunction
endclass

// =========================================================================
// conv_driver
// =========================================================================
class conv_driver extends axil_agent;
    function new(); super.new("CK_DRV"); endfunction

    task run(conv_item item);
        int unsigned x_bytes, w_bytes, b_bytes, y_bytes;

        $display("[%0t][CK_DRV] %s", $time, item.to_string());

        x_bytes = item.batch  * item.in_ch  * item.in_h  * item.in_w  * ELEM_BYTES;
        w_bytes = item.out_ch * (item.is_depthwise ? 1 : item.in_ch) *
                  item.kh * item.kw * ELEM_BYTES;
        b_bytes = item.out_ch * ELEM_BYTES;
        y_bytes = item.batch  * item.out_ch * item.out_h * item.out_w * ELEM_BYTES;

        $display("[%0t][CK_DRV] Loading x (%0d B, val=0x%04h) ...",
                 $time, x_bytes, item.x_val);
        fill_const_ddr(item.addr_x, align_up(x_bytes, 16), item.x_val);

        $display("[%0t][CK_DRV] Loading weight (%0d B, val=0x%04h) ...",
                 $time, w_bytes, item.w_val);
        fill_const_ddr(item.addr_w, align_up(w_bytes, 16), item.w_val);

        $display("[%0t][CK_DRV] Loading bias (%0d B, val=0x%04h, has_bias=%0d) ...",
                 $time, b_bytes, item.b_val, item.has_bias);
        fill_const_ddr(item.addr_b, align_up(b_bytes, 16), item.b_val);

        $display("[%0t][CK_DRV] Pre-filling y (%0d B) with 0x%04h ...",
                 $time, align_up(y_bytes, 16), POISON);
        fill_const_ddr(item.addr_y, align_up(y_bytes, 16), POISON);

        $display("[%0t][CK_DRV] Programming registers ...", $time);
        axil_write(CK_X_LO,          item.addr_x[31:0]);
        axil_write(CK_X_HI,          {24'b0, item.addr_x[39:32]});
        axil_write(CK_W_LO,          item.addr_w[31:0]);
        axil_write(CK_W_HI,          {24'b0, item.addr_w[39:32]});
        axil_write(CK_B_LO,          item.addr_b[31:0]);
        axil_write(CK_B_HI,          {24'b0, item.addr_b[39:32]});
        axil_write(CK_Y_LO,          item.addr_y[31:0]);
        axil_write(CK_Y_HI,          {24'b0, item.addr_y[39:32]});
        axil_write(CK_BATCH,         32'(item.batch));
        axil_write(CK_IN_CH,         32'(item.in_ch));
        axil_write(CK_IN_H,          32'(item.in_h));
        axil_write(CK_IN_W,          32'(item.in_w));
        axil_write(CK_OUT_CH,        32'(item.out_ch));
        axil_write(CK_OUT_H,         32'(item.out_h));
        axil_write(CK_OUT_W,         32'(item.out_w));
        axil_write(CK_KH,            32'(item.kh));
        axil_write(CK_KW,            32'(item.kw));
        axil_write(CK_STRIDE_H,      32'(item.stride_h));
        axil_write(CK_STRIDE_W,      32'(item.stride_w));
        axil_write(CK_DIL_H,         32'(item.dilation_h));
        axil_write(CK_DIL_W,         32'(item.dilation_w));
        axil_write(CK_PAD_TOP,       32'(item.pad_top));
        axil_write(CK_PAD_LEFT,      32'(item.pad_left));
        axil_write(CK_HAS_BIAS,      32'(item.has_bias));
        axil_write(CK_IS_DEPTHWISE,  32'(item.is_depthwise));
        axil_write(CK_GIE,           32'h1);
        axil_write(CK_IER,           32'h1);
        $display("[%0t][CK_DRV] Asserting ap_start ...", $time);
        axil_write(CK_AP_CTRL,       32'h1);
    endtask
endclass

// =========================================================================
// conv_monitor
// =========================================================================
class conv_monitor extends axil_agent;
    local int unsigned irq_ch;
    virtual irq_if     irq;

    function new(virtual irq_if i, int unsigned ch = 2, string tag = "CK_MON");
        super.new(tag);
        this.irq    = i;
        this.irq_ch = ch;
    endfunction

    task run(conv_item item);
        logic [15:0] irq_status;
        logic [31:0] isr_val, ap_ctrl_val;

        $display("[%0t][CK_MON] Waiting for interrupt ...", $time);
        irq_status = 16'h0;
        fork
            begin : ck_irq_wait
                `PS.wait_interrupt(4'(irq_ch), irq_status);
            end
            begin : ck_irq_timeout
                #2_000_000_000;
            end
        join_any
        disable fork;

        if (!irq_status[irq_ch]) begin
            $error("[%0t][CK_MON] TIMEOUT: no interrupt after 2 s  test=%s",
                   $time, item.label);
            $finish;
        end
        $display("[%0t][CK_MON] Interrupt received (irq_status=0x%04h)", $time, irq_status);

        axil_read(CK_AP_CTRL, ap_ctrl_val);
        $display("[%0t][CK_MON] ap_ctrl=0x%08h  done=%0b  idle=%0b  ready=%0b",
                 $time, ap_ctrl_val, ap_ctrl_val[1], ap_ctrl_val[2], ap_ctrl_val[3]);

        axil_read(CK_ISR, isr_val);
        $display("[%0t][CK_MON] ISR=0x%08h  ap_done=%0b  ap_ready=%0b",
                 $time, isr_val, isr_val[0], isr_val[1]);
        axil_write(CK_ISR, isr_val);
        axil_write(CK_GIE, 32'h0);

        if (irq.sig) begin
            $display("[%0t][CK_MON] Waiting for interrupt line to deassert ...", $time);
            @(negedge irq.sig);
        end
        $display("[%0t][CK_MON] Interrupt line low - ready for next test.", $time);
    endtask
endclass

// =========================================================================
// conv_scoreboard
// =========================================================================
class conv_scoreboard extends base_scoreboard;
    virtual function string kernel_name(); return "ConvKernel"; endfunction

    task run(conv_item item);
        logic [CHUNK_BITS-1:0] chunk_buf;
        int unsigned n_bytes, n_chunks, rem, errors, eidx, w;
        logic [15:0] elem;

        n_bytes  = item.batch * item.out_ch * item.out_h * item.out_w * ELEM_BYTES;
        n_chunks = n_bytes / CHUNK_BYTES;
        rem      = n_bytes % CHUNK_BYTES;
        errors   = 0;

        $display("[%0t][CK_SCB] Verifying y[0..%0d] (%0d elem × %0d B = %0d B)  exp=0x%04h ...",
                 $time,
                 item.batch * item.out_ch * item.out_h * item.out_w - 1,
                 item.batch * item.out_ch * item.out_h * item.out_w,
                 ELEM_BYTES, n_bytes, item.y_expected);

        for (int i = 0; i < int'(n_chunks); i++) begin
            `PS.read_mem(item.addr_y + 40'(i * CHUNK_BYTES), CHUNK_BYTES, chunk_buf);
            for (w = 0; w < CHUNK_BYTES / 2; w++) begin
                eidx = i * (CHUNK_BYTES / 2) + w;
                elem = chunk_buf[w*16 +: 16];
                if (elem !== item.y_expected) begin
                    if (errors < 5)
                        $display("[%0t][CK_SCB] MISMATCH y[%0d]: got=0x%04h  exp=0x%04h",
                                 $time, eidx, elem, item.y_expected);
                    errors++;
                end
            end
        end
        if (rem > 0) begin
            `PS.read_mem(item.addr_y + 40'(n_chunks * CHUNK_BYTES), rem, chunk_buf);
            for (w = 0; w < rem / 2; w++) begin
                eidx = n_chunks * (CHUNK_BYTES / 2) + w;
                elem = chunk_buf[w*16 +: 16];
                if (elem !== item.y_expected) begin
                    if (errors < 5)
                        $display("[%0t][CK_SCB] MISMATCH y[%0d]: got=0x%04h  exp=0x%04h",
                                 $time, eidx, elem, item.y_expected);
                    errors++;
                end
            end
        end

        total_tests++;
        if (errors == 0) begin
            pass_cnt++;
            $display("[%0t][CK_SCB] PASS  %-32s  N=%0d IC=%0d OH=%0d OW=%0d OC=%0d dw=%0d",
                     $time, item.label,
                     item.batch, item.in_ch, item.out_h, item.out_w, item.out_ch,
                     item.is_depthwise);
        end else begin
            fail_cnt++;
            $display("[%0t][CK_SCB] FAIL  %-32s  %0d/%0d mismatches",
                     $time, item.label, errors,
                     item.batch * item.out_ch * item.out_h * item.out_w);
        end
    endtask
endclass

// =========================================================================
// conv_env
// =========================================================================
class conv_env;
    conv_driver     drv;
    conv_monitor    mon;
    conv_scoreboard scb;

    function new(virtual irq_if irq);
        drv = new();
        mon = new(irq, 2);
        scb = new();
    endfunction

    task run_one(conv_item item);
        drv.run(item);
        mon.run(item);
        scb.run(item);
    endtask
endclass

// =========================================================================
// conv_test — 12 standard + 5 depthwise convolution cases
//
// Expected value reference (x=1.0=0x0100, w=1.0=0x0100, no padding):
//   n=1:  1×256×256>>>8  =  256 = 0x0100 (1.0)
//   n=9:  9×256×256>>>8  = 2304 = 0x0900 (9.0)
//   n=36: 36×256×256>>>8 = 9216 = 0x2400 (36.0)
//   Bias (b=0.5=0x0080, n=1):  acc=256²+128×256=98304; >>>8=384=0x0180 (1.5)
//   sat+: x=100(0x6400) w=1 IC=2 k=1×1: acc=2×25600×256>>>8=51200 → 0x7FFF
//   sat-: x=-100(0x9C00) w=1 IC=2 k=1×1:                           → 0x8000
// =========================================================================
class conv_test;
    conv_env       e;
    virtual irq_if irq;

    function new(virtual irq_if i); this.irq = i; endfunction

    task run();
        conv_item tests[$];
        conv_item it;
        int unsigned n;
        e = new(irq);

        // ---- Standard convolution ----------------------------------------

        // 1×1×1×1 k=1×1  degenerate minimum  n_active=1 → 0x0100
        it = new("1x1x1x1 k=1x1",
                 1, 1, 1, 1,  1, 1, 1,  1, 1);
        tests.push_back(it);

        // 1×1×3×3 k=1×1  spatial sweep, no reduction  n_active=1 → 0x0100
        it = new("1x1x3x3 k=1x1",
                 1, 1, 3, 3,  1, 3, 3,  1, 1);
        tests.push_back(it);

        // 1×1×5×5 k=3×3  9-tap spatial reduction  n_active=9 → 0x0900
        it = new("1x1x5x5 k=3x3",
                 1, 1, 5, 5,  1, 3, 3,  3, 3);
        tests.push_back(it);

        // 1×4×5×5 k=3×3  IC=4 channel reduction (4×9=36)  → 0x2400
        it = new("1x4x5x5 k=3x3 IC=4",
                 1, 4, 5, 5,  1, 3, 3,  3, 3);
        tests.push_back(it);

        // 1×1×5×5 k=3×3  OC=4  four independent output channels  → 0x0900
        it = new("1x1x5x5 k=3x3 OC=4",
                 1, 1, 5, 5,  4, 3, 3,  3, 3);
        tests.push_back(it);

        // 1×4×5×5 k=3×3  IC=4 OC=8  exercises tiling  → 0x2400
        it = new("1x4x5x5 k=3x3 IC=4 OC=8",
                 1, 4, 5, 5,  8, 3, 3,  3, 3);
        tests.push_back(it);

        // 1×1×7×7 k=3×3  stride=2: OH=OW=3  n_active=9 → 0x0900
        it = new("1x1x7x7 k=3x3 stride=2",
                 1, 1, 7, 7,  1, 3, 3,  3, 3,
                 /*stride_h=*/2, /*stride_w=*/2);
        tests.push_back(it);

        // 1×1×7×7 k=3×3  dilation=2: effective 5×5; OH=OW=3  → 0x0900
        it = new("1x1x7x7 k=3x3 dil=2",
                 1, 1, 7, 7,  1, 3, 3,  3, 3,
                 /*stride_h=*/1, /*stride_w=*/1,
                 /*dilation_h=*/2, /*dilation_w=*/2);
        tests.push_back(it);

        // 2×1×5×5 k=3×3  batch=2, both slices identical  → 0x0900
        it = new("2x1x5x5 k=3x3 batch=2",
                 2, 1, 5, 5,  1, 3, 3,  3, 3);
        tests.push_back(it);

        // Saturation: positive  acc=51200 > 32767 → 0x7FFF
        it = new("sat+ x=100 w=1 IC=2 k=1x1",
                 1, 2, 1, 1,  1, 1, 1,  1, 1,
                 1, 1, 1, 1, 0, 0, 0,
                 16'h6400, 16'h0100, 16'h0000);
        tests.push_back(it);

        // Saturation: negative  acc=-51200 < -32768 → 0x8000
        it = new("sat- x=-100 w=1 IC=2 k=1x1",
                 1, 2, 1, 1,  1, 1, 1,  1, 1,
                 1, 1, 1, 1, 0, 0, 0,
                 16'h9C00, 16'h0100, 16'h0000);
        tests.push_back(it);

        // Bias: x=1 w=1 b=0.5(0x0080) n=1 OC=2  → 0x0180 (1.5)
        it = new("bias k=1x1 OC=2 b=0.5",
                 1, 1, 3, 3,  2, 3, 3,  1, 1,
                 1, 1, 1, 1, 0, 0,
                 /*has_bias=*/1,
                 16'h0100, 16'h0100, 16'h0080);
        tests.push_back(it);

        // ---- Depthwise convolution (is_depthwise=1) ----------------------

        // dw 1×4×5×5 k=3×3  n_active_dw=9 → 0x0900
        it = new("dw 1x4x5x5 k=3x3",
                 1, 4, 5, 5,  4, 3, 3,  3, 3,
                 1, 1, 1, 1, 0, 0,
                 /*has_bias=*/0,
                 16'h0100, 16'h0100, 16'h0000,
                 /*is_depthwise=*/1);
        tests.push_back(it);

        // dw 1×4×5×5 k=3×3 with bias b=0.5  → 0x0980 (9.5)
        it = new("dw 1x4x5x5 k=3x3 bias",
                 1, 4, 5, 5,  4, 3, 3,  3, 3,
                 1, 1, 1, 1, 0, 0,
                 /*has_bias=*/1,
                 16'h0100, 16'h0100, 16'h0080,
                 /*is_depthwise=*/1);
        tests.push_back(it);

        // dw 1×4×7×7 k=3×3 stride=2: OH=OW=3  → 0x0900
        it = new("dw 1x4x7x7 k=3x3 stride=2",
                 1, 4, 7, 7,  4, 3, 3,  3, 3,
                 /*stride_h=*/2, /*stride_w=*/2,
                 1, 1, 0, 0,
                 /*has_bias=*/0,
                 16'h0100, 16'h0100, 16'h0000,
                 /*is_depthwise=*/1);
        tests.push_back(it);

        // dw 2×4×5×5 k=3×3 batch=2  → 0x0900 both slices
        it = new("dw 2x4x5x5 k=3x3 batch=2",
                 2, 4, 5, 5,  4, 3, 3,  3, 3,
                 1, 1, 1, 1, 0, 0,
                 /*has_bias=*/0,
                 16'h0100, 16'h0100, 16'h0000,
                 /*is_depthwise=*/1);
        tests.push_back(it);

        // dw 1×16×5×5 k=3×3  OC=16 > kTileM  → 0x0900
        it = new("dw 1x16x5x5 k=3x3 OC=16",
                 1, 16, 5, 5,  16, 3, 3,  3, 3,
                 1, 1, 1, 1, 0, 0,
                 /*has_bias=*/0,
                 16'h0100, 16'h0100, 16'h0000,
                 /*is_depthwise=*/1);
        tests.push_back(it);

        // ---- Run all tests -----------------------------------------------
        n = tests.size();
        $display("==========================================================");
        $display(" ConvKernel Testbench  -  %0d test cases  ap_fixed<16,8>", n);
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
