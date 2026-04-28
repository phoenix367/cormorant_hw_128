// mm_classes.svh — MatmulKernel testbench classes.
//
// DDR layout (base 0x3000_0000, gaps of MEM_GAP between tensors):
//   addr_a | a_region + MEM_GAP | addr_b | b_region + MEM_GAP | addr_c
//
// Batch strides: a_batch_stride=0 → A broadcasts across all batch slices.
//               b_batch_stride=0 → B broadcasts (or batch==1, stride ignored).
//               c_batch_stride  = N×M always.

// =========================================================================
// mm_item
// =========================================================================
class mm_item;
    int unsigned n;
    int unsigned k;
    int unsigned m;
    int unsigned batch;
    int unsigned a_batch_stride;
    int unsigned b_batch_stride;
    int unsigned c_batch_stride;

    logic [15:0] a_val;
    logic [15:0] b_val;
    logic [15:0] c_expected;

    logic [39:0] addr_a;
    logic [39:0] addr_b;
    logic [39:0] addr_c;

    string label;

    function new(
        string         lbl,
        int unsigned   n_,
        int unsigned   k_,
        int unsigned   m_,
        logic [15:0]   a,
        logic [15:0]   b,
        int unsigned   batch_          = 1,
        int unsigned   a_batch_stride_ = 0,
        int unsigned   b_batch_stride_ = 0
    );
        int unsigned a_region_bytes, b_region_bytes;

        this.label   = lbl;
        this.n       = n_;
        this.k       = k_;
        this.m       = m_;
        this.batch   = batch_;
        this.a_val   = a;
        this.b_val   = b;
        this.c_expected     = compute_mm_const(a, b, k_);
        this.a_batch_stride = a_batch_stride_;
        this.b_batch_stride = b_batch_stride_;
        this.c_batch_stride = n_ * m_;

        a_region_bytes = (a_batch_stride_ == 0 && batch_ > 1)
                       ? align_up(n_ * k_ * ELEM_BYTES, 16)
                       : align_up(batch_ * n_ * k_ * ELEM_BYTES, 16);
        b_region_bytes = (b_batch_stride_ == 0 && batch_ > 1)
                       ? align_up(k_ * m_ * ELEM_BYTES, 16)
                       : align_up(batch_ * k_ * m_ * ELEM_BYTES, 16);

        this.addr_a = 40'h3000_0000;
        this.addr_b = this.addr_a + 40'(a_region_bytes) + 40'(MEM_GAP);
        this.addr_c = this.addr_b + 40'(b_region_bytes) + 40'(MEM_GAP);
    endfunction

    function string to_string();
        return $sformatf(
            "%-26s  N=%0d K=%0d M=%0d  batch=%0d  A=0x%04h B=0x%04h  exp_C=0x%04h  a_str=%0d b_str=%0d",
            label, n, k, m, batch, a_val, b_val, c_expected,
            a_batch_stride, b_batch_stride);
    endfunction
endclass

// =========================================================================
// mm_driver
// =========================================================================
class mm_driver extends axil_agent;
    function new(); super.new("MM_DRV"); endfunction

    task run(mm_item item);
        int unsigned a_total_bytes, b_total_bytes, c_total_bytes;

        $display("[%0t][MM_DRV] %s", $time, item.to_string());

        a_total_bytes = (item.a_batch_stride == 0 && item.batch > 1)
                      ? align_up(item.n * item.k * ELEM_BYTES, 16)
                      : align_up(item.batch * item.n * item.k * ELEM_BYTES, 16);
        b_total_bytes = (item.b_batch_stride == 0 && item.batch > 1)
                      ? align_up(item.k * item.m * ELEM_BYTES, 16)
                      : align_up(item.batch * item.k * item.m * ELEM_BYTES, 16);
        c_total_bytes = align_up(item.batch * item.n * item.m * ELEM_BYTES, 16);

        $display("[%0t][MM_DRV] Loading A (%0d B, val=0x%04h) ...",
                 $time, a_total_bytes, item.a_val);
        fill_const_ddr(item.addr_a, a_total_bytes, item.a_val);

        $display("[%0t][MM_DRV] Loading B (%0d B, val=0x%04h) ...",
                 $time, b_total_bytes, item.b_val);
        fill_const_ddr(item.addr_b, b_total_bytes, item.b_val);

        $display("[%0t][MM_DRV] Pre-filling C (%0d B) with 0x%04h ...",
                 $time, c_total_bytes, POISON);
        fill_const_ddr(item.addr_c, c_total_bytes, POISON);

        $display("[%0t][MM_DRV] Programming registers ...", $time);
        axil_write(MM_A_LO,        item.addr_a[31:0]);
        axil_write(MM_A_HI,        {24'b0, item.addr_a[39:32]});
        axil_write(MM_B_LO,        item.addr_b[31:0]);
        axil_write(MM_B_HI,        {24'b0, item.addr_b[39:32]});
        axil_write(MM_C_LO,        item.addr_c[31:0]);
        axil_write(MM_C_HI,        {24'b0, item.addr_c[39:32]});
        axil_write(MM_N,           32'(item.n));
        axil_write(MM_K,           32'(item.k));
        axil_write(MM_M,           32'(item.m));
        axil_write(MM_BATCH,       32'(item.batch));
        axil_write(MM_A_BATCH_STR, 32'(item.a_batch_stride));
        axil_write(MM_B_BATCH_STR, 32'(item.b_batch_stride));
        axil_write(MM_C_BATCH_STR, 32'(item.c_batch_stride));
        axil_write(MM_GIE,         32'h1);
        axil_write(MM_IER,         32'h1);
        $display("[%0t][MM_DRV] Asserting ap_start ...", $time);
        axil_write(MM_AP_CTRL,     32'h1);
    endtask
endclass

// =========================================================================
// mm_monitor
// =========================================================================
class mm_monitor extends axil_agent;
    local int unsigned irq_ch;
    virtual irq_if     irq;

    function new(virtual irq_if i, int unsigned ch = 1, string tag = "MM_MON");
        super.new(tag);
        this.irq    = i;
        this.irq_ch = ch;
    endfunction

    task run(mm_item item);
        logic [15:0] irq_status;
        logic [31:0] isr_val, ap_ctrl_val;

        $display("[%0t][MM_MON] Waiting for interrupt ...", $time);
        irq_status = 16'h0;
        fork
            begin : mm_irq_wait
                `PS.wait_interrupt(4'(irq_ch), irq_status);
            end
            begin : mm_irq_timeout
                #500_000_000;
            end
        join_any
        disable fork;

        if (!irq_status[irq_ch]) begin
            $error("[%0t][MM_MON] TIMEOUT: no interrupt after 500 ms  test=%s",
                   $time, item.label);
            $finish;
        end
        $display("[%0t][MM_MON] Interrupt received (irq_status=0x%04h)", $time, irq_status);

        axil_read(MM_AP_CTRL, ap_ctrl_val);
        $display("[%0t][MM_MON] ap_ctrl=0x%08h  done=%0b  idle=%0b  ready=%0b",
                 $time, ap_ctrl_val, ap_ctrl_val[1], ap_ctrl_val[2], ap_ctrl_val[3]);

        axil_read(MM_ISR, isr_val);
        $display("[%0t][MM_MON] ISR=0x%08h  ap_done=%0b  ap_ready=%0b",
                 $time, isr_val, isr_val[0], isr_val[1]);
        axil_write(MM_ISR, isr_val);
        axil_write(MM_GIE, 32'h0);

        if (irq.sig) begin
            $display("[%0t][MM_MON] Waiting for interrupt line to deassert ...", $time);
            @(negedge irq.sig);
        end
        $display("[%0t][MM_MON] Interrupt line low - ready for next test.", $time);
    endtask
endclass

// =========================================================================
// mm_scoreboard
// =========================================================================
class mm_scoreboard extends base_scoreboard;
    virtual function string kernel_name(); return "MatmulKernel"; endfunction

    task run(mm_item item);
        logic [CHUNK_BITS-1:0] chunk_buf;
        int unsigned n_bytes, n_chunks, rem, errors, eidx, w;
        logic [15:0] elem;

        n_bytes  = item.batch * item.n * item.m * ELEM_BYTES;
        n_chunks = n_bytes / CHUNK_BYTES;
        rem      = n_bytes % CHUNK_BYTES;
        errors   = 0;

        $display("[%0t][MM_SCB] Verifying C[0..%0d] (%0d elem × %0d B = %0d B)  exp=0x%04h ...",
                 $time,
                 item.batch * item.n * item.m - 1,
                 item.batch * item.n * item.m,
                 ELEM_BYTES, n_bytes, item.c_expected);

        for (int i = 0; i < int'(n_chunks); i++) begin
            `PS.read_mem(item.addr_c + 40'(i * CHUNK_BYTES), CHUNK_BYTES, chunk_buf);
            for (w = 0; w < CHUNK_BYTES / 2; w++) begin
                eidx = i * (CHUNK_BYTES / 2) + w;
                elem = chunk_buf[w*16 +: 16];
                if (elem !== item.c_expected) begin
                    if (errors < 5)
                        $display("[%0t][MM_SCB] MISMATCH C[%0d]: got=0x%04h  exp=0x%04h",
                                 $time, eidx, elem, item.c_expected);
                    errors++;
                end
            end
        end
        if (rem > 0) begin
            `PS.read_mem(item.addr_c + 40'(n_chunks * CHUNK_BYTES), rem, chunk_buf);
            for (w = 0; w < rem / 2; w++) begin
                eidx = n_chunks * (CHUNK_BYTES / 2) + w;
                elem = chunk_buf[w*16 +: 16];
                if (elem !== item.c_expected) begin
                    if (errors < 5)
                        $display("[%0t][MM_SCB] MISMATCH C[%0d]: got=0x%04h  exp=0x%04h",
                                 $time, eidx, elem, item.c_expected);
                    errors++;
                end
            end
        end

        total_tests++;
        if (errors == 0) begin
            pass_cnt++;
            $display("[%0t][MM_SCB] PASS  %-26s  %0d×%0d×%0d batch=%0d",
                     $time, item.label, item.n, item.k, item.m, item.batch);
        end else begin
            fail_cnt++;
            $display("[%0t][MM_SCB] FAIL  %-26s  %0d/%0d mismatches",
                     $time, item.label, errors, item.batch * item.n * item.m);
        end
    endtask
endclass

// =========================================================================
// mm_env
// =========================================================================
class mm_env;
    mm_driver     drv;
    mm_monitor    mon;
    mm_scoreboard scb;

    function new(virtual irq_if irq);
        drv = new();
        mon = new(irq, 1);
        scb = new();
    endfunction

    task run_one(mm_item item);
        drv.run(item);
        mon.run(item);
        scb.run(item);
    endtask
endclass

// =========================================================================
// mm_test — 10 MatmulKernel test cases
//
// Expected value: C_raw = clip( K × a_raw × b_raw >>> 8, -32768, 32767 )
//   A=B=1.0(0x0100)  K=1: 1×256×256>>>8  =  256 = 0x0100 (1.0)
//                    K=4: 4×256×256>>>8  = 1024 = 0x0400 (4.0)
//   sat+: A=100(0x6400) B=1(0x0100) K=2: acc=13107200>>>8=51200 → 0x7FFF
//   sat-: A=-100(0x9C00) B=1(0x0100) K=2: → 0x8000
// =========================================================================
class mm_test;
    mm_env         e;
    virtual irq_if irq;

    function new(virtual irq_if i); this.irq = i; endfunction

    task run();
        mm_item tests[$];
        mm_item it;
        int unsigned n;
        e = new(irq);

        it = new("1x1x1",            1, 1, 1,  16'h0100, 16'h0100);
        tests.push_back(it);
        it = new("4x4x16 A=B=1.0",  4, 4, 16, 16'h0100, 16'h0100);
        tests.push_back(it);
        it = new("5x4x16 partial-N", 5, 4, 16, 16'h0100, 16'h0100);
        tests.push_back(it);
        it = new("4x4x17 partial-M", 4, 4, 17, 16'h0100, 16'h0100);
        tests.push_back(it);
        it = new("4x3x16 K%TileN!=0", 4, 3, 16, 16'h0100, 16'h0100);
        tests.push_back(it);
        it = new("4x4x16 A=B=2.0",  4, 4, 16, 16'h0200, 16'h0200);
        tests.push_back(it);
        it = new("sat+ A=100 B=1 K=2",  2, 2, 2, 16'h6400, 16'h0100);
        tests.push_back(it);
        it = new("sat- A=-100 B=1 K=2", 2, 2, 2, 16'h9C00, 16'h0100);
        tests.push_back(it);
        it = new("batch=2 no bcast", 4, 4, 16, 16'h0100, 16'h0100,
                 /*batch=*/2, /*a_str=*/4*4, /*b_str=*/4*16);
        tests.push_back(it);
        it = new("batch=2 A bcast",  4, 4, 16, 16'h0100, 16'h0100,
                 /*batch=*/2, /*a_str=*/0, /*b_str=*/4*16);
        tests.push_back(it);

        n = tests.size();
        $display("==========================================================");
        $display(" MatmulKernel Testbench  -  %0d test cases  ap_fixed<16,8>", n);
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
