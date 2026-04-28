// pk_classes.svh — PoolingKernel testbench classes.
//
// DDR layout (base 0x4000_0000):
//   addr_x | x_bytes + MEM_GAP | addr_y

// =========================================================================
// pk_item
// =========================================================================
class pk_item;
    int unsigned batch;
    int unsigned channels;
    int unsigned in_h,  in_w;
    int unsigned out_h, out_w;
    int unsigned pool_h, pool_w;
    int unsigned stride_h, stride_w;
    int unsigned pad_top, pad_left;
    int unsigned dil_h, dil_w;
    int unsigned pool_type;        // 0=Max  1=Avg  2=Lp
    int unsigned lp_order;
    int unsigned count_include_pad;
    logic [15:0] x_val;
    logic [15:0] y_expected;
    logic [39:0] addr_x;
    logic [39:0] addr_y;
    string       label;

    function new(
        string       lbl,
        int unsigned batch_,
        int unsigned channels_,
        int unsigned in_h_,         int unsigned in_w_,
        int unsigned pool_h_   = 1, int unsigned pool_w_        = 1,
        int unsigned stride_h_ = 1, int unsigned stride_w_      = 1,
        int unsigned pad_top_  = 0, int unsigned pad_left_      = 0,
        int unsigned dil_h_    = 1, int unsigned dil_w_         = 1,
        int unsigned pool_type_          = 0,
        int unsigned lp_order_           = 1,
        int unsigned count_include_pad_  = 0,
        logic [15:0] x_                  = 16'h0100);
        int unsigned x_bytes, n_active;
        this.label             = lbl;
        this.batch             = batch_;
        this.channels          = channels_;
        this.in_h              = in_h_;
        this.in_w              = in_w_;
        this.pool_h            = pool_h_;
        this.pool_w            = pool_w_;
        this.stride_h          = stride_h_;
        this.stride_w          = stride_w_;
        this.pad_top           = pad_top_;
        this.pad_left          = pad_left_;
        this.dil_h             = dil_h_;
        this.dil_w             = dil_w_;
        this.pool_type         = pool_type_;
        this.lp_order          = lp_order_;
        this.count_include_pad = count_include_pad_;
        this.x_val             = x_;
        this.out_h = (in_h_ + 2*pad_top_  - dil_h_*(pool_h_-1) - 1) / stride_h_ + 1;
        this.out_w = (in_w_ + 2*pad_left_ - dil_w_*(pool_w_-1) - 1) / stride_w_ + 1;
        n_active = pool_h_ * pool_w_;
        this.y_expected = compute_pool_const(x_, n_active, pool_type_, lp_order_);
        x_bytes = align_up(batch_ * channels_ * in_h_ * in_w_ * ELEM_BYTES, 16);
        this.addr_x = 40'h4000_0000;
        this.addr_y = this.addr_x + 40'(x_bytes) + 40'(MEM_GAP);
    endfunction

    function string to_string();
        return $sformatf(
            "%-36s  N=%0d C=%0d IH=%0d IW=%0d  OH=%0d OW=%0d  k=%0dx%0d s=%0dx%0d d=%0dx%0d p=%0d,%0d  type=%0d lp=%0d  x=0x%04h  exp_y=0x%04h",
            label, batch, channels, in_h, in_w, out_h, out_w,
            pool_h, pool_w, stride_h, stride_w, dil_h, dil_w,
            pad_top, pad_left, pool_type, lp_order, x_val, y_expected);
    endfunction
endclass

// =========================================================================
// pk_driver
// =========================================================================
class pk_driver extends axil_agent;
    function new(); super.new("PK_DRV"); endfunction

    task run(pk_item item);
        int unsigned x_bytes, y_bytes;
        $display("[%0t][PK_DRV] %s", $time, item.to_string());
        x_bytes = item.batch * item.channels * item.in_h  * item.in_w  * ELEM_BYTES;
        y_bytes = item.batch * item.channels * item.out_h * item.out_w * ELEM_BYTES;
        fill_const_ddr(item.addr_x, align_up(x_bytes, 16), item.x_val);
        fill_const_ddr(item.addr_y, align_up(y_bytes, 16), POISON);
        axil_write(PK_X_LO,              item.addr_x[31:0]);
        axil_write(PK_X_HI,              {24'b0, item.addr_x[39:32]});
        axil_write(PK_Y_LO,              item.addr_y[31:0]);
        axil_write(PK_Y_HI,              {24'b0, item.addr_y[39:32]});
        axil_write(PK_BATCH,             32'(item.batch));
        axil_write(PK_CHANNELS,          32'(item.channels));
        axil_write(PK_IN_H,              32'(item.in_h));
        axil_write(PK_IN_W,              32'(item.in_w));
        axil_write(PK_OUT_H,             32'(item.out_h));
        axil_write(PK_OUT_W,             32'(item.out_w));
        axil_write(PK_POOL_H,            32'(item.pool_h));
        axil_write(PK_POOL_W,            32'(item.pool_w));
        axil_write(PK_STRIDE_H,          32'(item.stride_h));
        axil_write(PK_STRIDE_W,          32'(item.stride_w));
        axil_write(PK_PAD_TOP,           32'(item.pad_top));
        axil_write(PK_PAD_LEFT,          32'(item.pad_left));
        axil_write(PK_DIL_H,             32'(item.dil_h));
        axil_write(PK_DIL_W,             32'(item.dil_w));
        axil_write(PK_POOL_TYPE,         32'(item.pool_type));
        axil_write(PK_LP_ORDER,          32'(item.lp_order));
        axil_write(PK_COUNT_INCLUDE_PAD, 32'(item.count_include_pad));
        axil_write(PK_GIE,               32'h1);
        axil_write(PK_IER,               32'h1);
        axil_write(PK_AP_CTRL,           32'h1);
    endtask
endclass

// =========================================================================
// pk_monitor
// =========================================================================
class pk_monitor extends axil_agent;
    local int unsigned irq_ch;
    virtual irq_if     irq;

    function new(virtual irq_if i, int unsigned ch = 3, string tag = "PK_MON");
        super.new(tag);
        this.irq    = i;
        this.irq_ch = ch;
    endfunction

    task run(pk_item item);
        logic [15:0] irq_status;
        logic [31:0] isr_val, ap_ctrl_val;
        $display("[%0t][PK_MON] Waiting for interrupt ...", $time);
        irq_status = 16'h0;
        fork
            begin : pk_irq_wait
                `PS.wait_interrupt(4'(irq_ch), irq_status);
            end
            begin : pk_irq_timeout
                #2_000_000_000;
            end
        join_any
        disable fork;
        if (!irq_status[irq_ch]) begin
            $error("[%0t][PK_MON] TIMEOUT: no interrupt after 2 s sim-time  test=%s",
                   $time, item.label);
            $finish;
        end
        $display("[%0t][PK_MON] Interrupt received (irq_status=0x%04h)", $time, irq_status);
        axil_read(PK_AP_CTRL, ap_ctrl_val);
        $display("[%0t][PK_MON] ap_ctrl=0x%08h  done=%0b  idle=%0b  ready=%0b",
                 $time, ap_ctrl_val, ap_ctrl_val[1], ap_ctrl_val[2], ap_ctrl_val[3]);
        axil_read(PK_ISR, isr_val);
        axil_write(PK_ISR, isr_val);
        axil_write(PK_GIE, 32'h0);
        if (irq.sig) begin
            $display("[%0t][PK_MON] Waiting for interrupt line to deassert ...", $time);
            @(negedge irq.sig);
        end
        $display("[%0t][PK_MON] Interrupt line low - ready for next test.", $time);
    endtask
endclass

// =========================================================================
// pk_scoreboard
// =========================================================================
class pk_scoreboard extends base_scoreboard;
    virtual function string kernel_name(); return "PoolingKernel"; endfunction

    task run(pk_item item);
        logic [CHUNK_BITS-1:0] chunk_buf;
        int unsigned n_bytes, n_chunks, rem, errors, eidx, w;
        logic [15:0] elem;
        n_bytes  = item.batch * item.channels * item.out_h * item.out_w * ELEM_BYTES;
        n_chunks = n_bytes / CHUNK_BYTES;
        rem      = n_bytes % CHUNK_BYTES;
        errors   = 0;
        for (int i = 0; i < int'(n_chunks); i++) begin
            `PS.read_mem(item.addr_y + 40'(i * CHUNK_BYTES), CHUNK_BYTES, chunk_buf);
            for (w = 0; w < CHUNK_BYTES/2; w++) begin
                eidx = i * (CHUNK_BYTES/2) + w;
                elem = chunk_buf[w*16 +: 16];
                if (elem !== item.y_expected) begin
                    if (errors < 5)
                        $display("[%0t][PK_SCB] MISMATCH y[%0d]: got=0x%04h  exp=0x%04h",
                                 $time, eidx, elem, item.y_expected);
                    errors++;
                end
            end
        end
        if (rem > 0) begin
            `PS.read_mem(item.addr_y + 40'(n_chunks * CHUNK_BYTES), rem, chunk_buf);
            for (w = 0; w < rem/2; w++) begin
                eidx = n_chunks * (CHUNK_BYTES/2) + w;
                elem = chunk_buf[w*16 +: 16];
                if (elem !== item.y_expected) begin
                    if (errors < 5)
                        $display("[%0t][PK_SCB] MISMATCH y[%0d]: got=0x%04h  exp=0x%04h",
                                 $time, eidx, elem, item.y_expected);
                    errors++;
                end
            end
        end
        total_tests++;
        if (errors == 0) begin
            pass_cnt++;
            $display("[%0t][PK_SCB] PASS  %-36s  N=%0d C=%0d OH=%0d OW=%0d",
                     $time, item.label, item.batch, item.channels, item.out_h, item.out_w);
        end else begin
            fail_cnt++;
            $display("[%0t][PK_SCB] FAIL  %-36s  %0d/%0d mismatches",
                     $time, item.label, errors,
                     item.batch * item.channels * item.out_h * item.out_w);
        end
    endtask
endclass

// =========================================================================
// pk_env
// =========================================================================
class pk_env;
    pk_driver     drv;
    pk_monitor    mon;
    pk_scoreboard scb;

    function new(virtual irq_if irq);
        drv = new(); mon = new(irq, 3); scb = new();
    endfunction

    task run_one(pk_item item);
        drv.run(item);
        mon.run(item);
        scb.run(item);
    endtask
endclass

// =========================================================================
// pk_test — 19 PoolingKernel test cases
//
// MaxPool / AvgPool: y = x  (max/avg of identical constant-fill values)
// LpPool p=1, N:  y = floor(N × |x_float| × 256)
// LpPool p=2, N:  y = floor(sqrt(N) × |x_float| × 256)
// sat+:  x=16.0(0x1000), k=3×3 N=9:  9×16=144 → 0x7FFF
// =========================================================================
class pk_test;
    pk_env         e;
    virtual irq_if irq;

    function new(virtual irq_if i); this.irq = i; endfunction

    task run();
        pk_item tests[$];
        pk_item it;
        int unsigned n;
        e = new(irq);

        // MaxPool tests ------------------------------------------------
        it = new("maxpool 1×1×1×1 k=1×1",         1, 1, 1, 1, 1, 1);
        tests.push_back(it);
        it = new("maxpool 1×1×4×4 k=2×2 s=2",      1, 1, 4, 4, 2, 2, 2, 2);
        tests.push_back(it);
        it = new("maxpool 1×1×7×7 k=3×3",          1, 1, 7, 7, 3, 3, 1, 1);
        tests.push_back(it);
        it = new("maxpool 1×4×4×4 k=2×2 s=2",      1, 4, 4, 4, 2, 2, 2, 2);
        tests.push_back(it);
        it = new("maxpool 1×8×4×4 k=2×2 s=2",      1, 8, 4, 4, 2, 2, 2, 2);
        tests.push_back(it);
        it = new("maxpool 2×1×4×4 k=2×2 s=2",      2, 1, 4, 4, 2, 2, 2, 2);
        tests.push_back(it);
        it = new("maxpool sat+ x=100.0",
                 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1, 0, 1, 0, 16'h6400);
        tests.push_back(it);
        it = new("maxpool neg x=-100.0",
                 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1, 0, 1, 0, 16'h9C00);
        tests.push_back(it);
        it = new("maxpool neg x=-1.0 k=2×2",
                 1, 1, 4, 4, 2, 2, 2, 2, 0, 0, 1, 1, 0, 1, 0, 16'hFF00);
        tests.push_back(it);
        it = new("maxpool 1×1×5×5 k=2×2 dil=2",    1, 1, 5, 5, 2, 2, 1, 1, 0, 0, 2, 2);
        tests.push_back(it);

        // AveragePool tests --------------------------------------------
        it = new("avgpool 1×1×4×4 k=2×2 s=2",
                 1, 1, 4, 4, 2, 2, 2, 2, 0, 0, 1, 1, 1);
        tests.push_back(it);
        it = new("avgpool 1×1×6×6 k=3×3 s=3",
                 1, 1, 6, 6, 3, 3, 3, 3, 0, 0, 1, 1, 1);
        tests.push_back(it);
        it = new("avgpool global 1×1×4×4",
                 1, 1, 4, 4, 4, 4, 1, 1, 0, 0, 1, 1, 1);
        tests.push_back(it);
        it = new("avgpool neg x=-1.0",
                 1, 1, 4, 4, 2, 2, 2, 2, 0, 0, 1, 1, 1, 1, 0, 16'hFF00);
        tests.push_back(it);

        // LpPool tests -------------------------------------------------
        it = new("lppool p=1 k=1×1",
                 1, 1, 4, 4, 1, 1, 1, 1, 0, 0, 1, 1, 2, 1);
        tests.push_back(it);
        it = new("lppool p=1 k=2×2",
                 1, 1, 4, 4, 2, 2, 2, 2, 0, 0, 1, 1, 2, 1);
        tests.push_back(it);
        it = new("lppool p=2 k=1×1",
                 1, 1, 4, 4, 1, 1, 1, 1, 0, 0, 1, 1, 2, 2);
        tests.push_back(it);
        it = new("lppool p=2 k=2×2",
                 1, 1, 4, 4, 2, 2, 2, 2, 0, 0, 1, 1, 2, 2);
        tests.push_back(it);
        it = new("lppool p=1 sat+ k=3×3 x=16",
                 1, 1, 7, 7, 3, 3, 1, 1, 0, 0, 1, 1, 2, 1, 0, 16'h1000);
        tests.push_back(it);

        n = tests.size();
        $display("==========================================================");
        $display(" PoolingKernel Testbench  -  %0d test cases  ap_fixed<16,8>", n);
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
