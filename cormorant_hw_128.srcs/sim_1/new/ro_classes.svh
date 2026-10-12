// ro_classes.svh — RowOpsKernel testbench classes.
//
// The cases are the kernel's checked-in fixtures (the parent repo's
// hw/test_data/rowops_test_data: manifest.txt + test_NN_{a,b,p,c}.hex +
// tables.hex, written by kernels/rowops_rtl/scripts/gen_fixtures.py from the
// Python specification), read from the directory of the +ROWOPS_DATA plusarg.
// First the table load (tables.hex into the unit's UltraRAM — once per
// bitstream, as the scheduler's inference_init does), then every fixture: the
// A / B / P images in DDR, the C region poisoned, the job run, and the whole
// C region compared byte for byte with test_NN_c.hex (the untouched bytes
// keep the poison, so a stray write fails too).

// =========================================================================
// ro_item — one job: its registers and its DDR images
// =========================================================================
class ro_item;
    string       label;
    int unsigned idx;
    logic [31:0] op;
    int unsigned n, rows, blocks;
    int unsigned a_s1, a_s2, b_s1, b_s2, c_s1, c_s2;
    logic [63:0] eps;
    logic [31:0] aux, bq_sh, win_lo, win_hi;
    bit          tload;                      // the table load (A = the table image)

    byte unsigned img_a[], img_b[], img_p[], exp_c[];   // DDR images (bytes)

    logic [39:0] addr_a, addr_b, addr_c, addr_p;

    function new(string lbl);
        this.label = lbl;
    endfunction

    function string to_string();
        return $sformatf("%-28s op=0x%05h n=%0d rows=%0d blocks=%0d s=(%0d,%0d|%0d,%0d|%0d,%0d) eps=%0d aux=%0d bq_sh=%0d win=[%0d,0x%08h) a=%0dB b=%0dB p=%0dB c=%0dB",
                         label, op, n, rows, blocks, a_s1, a_s2, b_s1, b_s2, c_s1, c_s2, eps, aux, bq_sh,
                         win_lo, win_hi, img_a.size(), img_b.size(), img_p.size(), exp_c.size());
    endfunction
endclass

// =========================================================================
// fixture files: 16-byte words as 32 hex digits per line, byte 0 first
// =========================================================================
function automatic bit ro_read_hex(string path, ref byte unsigned img[]);
    int fd, nlines;
    string line;
    logic [127:0] w;
    byte unsigned tmp[RO_IMG_MAX];
    fd = $fopen(path, "r");
    if (fd == 0) begin
        img = new[0];
        return 0;
    end
    nlines = 0;
    while (!$feof(fd)) begin
        if ($fgets(line, fd) == 0) break;
        if (line.len() < 32) continue;
        if (!$sscanf(line, "%h", w)) continue;
        if (nlines * 16 + 16 > RO_IMG_MAX) begin
            $error("[RO] %s: image larger than %0d bytes", path, RO_IMG_MAX);
            break;
        end
        for (int b = 0; b < 16; b++)
            tmp[nlines * 16 + b] = w[127 - 8 * b -: 8];
        nlines++;
    end
    $fclose(fd);
    img = new[nlines * 16];
    for (int i = 0; i < nlines * 16; i++) img[i] = tmp[i];
    return 1;
endfunction

// write a byte image to DDR through the PS VIP, in CHUNK_BYTES pieces
task automatic ro_write_ddr(input [39:0] base, ref byte unsigned img[]);
    logic [CHUNK_BITS-1:0] buf_mem;
    int unsigned total, i, j, nb;
    total = img.size();
    for (i = 0; i < total; i += CHUNK_BYTES) begin
        buf_mem = '0;
        nb = (total - i < CHUNK_BYTES) ? total - i : CHUNK_BYTES;
        for (j = 0; j < nb; j++) buf_mem[j*8 +: 8] = img[i + j];
        shadow_write_mem(buf_mem, base + 40'(i), nb);
    end
endtask

// =========================================================================
// ro_driver — loads DDR, programs the registers, starts the job
// =========================================================================
class ro_driver extends axil_agent;
    function new(); super.new("RO_DRV"); endfunction

    task run(ro_item item);
        byte unsigned poison[];
        $display("[%0t][RO_DRV] %s", $time, item.to_string());

        if (item.img_a.size()) ro_write_ddr(item.addr_a, item.img_a);
        if (item.img_b.size()) ro_write_ddr(item.addr_b, item.img_b);
        if (item.img_p.size()) ro_write_ddr(item.addr_p, item.img_p);
        if (item.exp_c.size()) begin
            poison = new[item.exp_c.size()];
            foreach (poison[i]) poison[i] = RO_POISON;
            ro_write_ddr(item.addr_c, poison);
        end

        axil_write(RO_REG_OP,     item.op);
        axil_write(RO_REG_N,      32'(item.n));
        axil_write(RO_REG_ROWS,   32'(item.rows));
        axil_write(RO_REG_BLOCKS, 32'(item.blocks));
        axil_write(RO_REG_A_LO,   item.addr_a[31:0]);
        axil_write(RO_REG_A_HI,   {24'h0, item.addr_a[39:32]});
        axil_write(RO_REG_A_S1,   32'(item.a_s1));
        axil_write(RO_REG_A_S2,   32'(item.a_s2));
        axil_write(RO_REG_B_LO,   item.addr_b[31:0]);
        axil_write(RO_REG_B_HI,   {24'h0, item.addr_b[39:32]});
        axil_write(RO_REG_B_S1,   32'(item.b_s1));
        axil_write(RO_REG_B_S2,   32'(item.b_s2));
        axil_write(RO_REG_C_LO,   item.addr_c[31:0]);
        axil_write(RO_REG_C_HI,   {24'h0, item.addr_c[39:32]});
        axil_write(RO_REG_C_S1,   32'(item.c_s1));
        axil_write(RO_REG_C_S2,   32'(item.c_s2));
        axil_write(RO_REG_P_LO,   item.addr_p[31:0]);
        axil_write(RO_REG_P_HI,   {24'h0, item.addr_p[39:32]});
        axil_write(RO_REG_EPS_LO, item.eps[31:0]);
        axil_write(RO_REG_EPS_HI, item.eps[63:32]);
        axil_write(RO_REG_AUX,    item.aux);
        axil_write(RO_REG_BQ_SH,  item.bq_sh);
        axil_write(RO_REG_WIN_LO, item.win_lo);
        axil_write(RO_REG_WIN_HI, item.win_hi);
        axil_write(RO_REG_GIE,    32'h1);
        axil_write(RO_REG_IER,    32'h1);
        $display("[%0t][RO_DRV] Asserting ap_start ...", $time);
        axil_write(RO_REG_AP_CTRL, 32'h1);
    endtask
endclass

// =========================================================================
// ro_monitor — waits for the interrupt, services it
// =========================================================================
class ro_monitor extends axil_agent;
    local int unsigned irq_ch;
    virtual irq_if     irq;

    function new(virtual irq_if i, int unsigned ch, string tag = "RO_MON");
        super.new(tag);
        this.irq    = i;
        this.irq_ch = ch;
    endfunction

    task run(ro_item item);
        logic [15:0] irq_status;
        logic [31:0] isr_val, ap_ctrl_val;

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
            $error("[%0t][RO_MON] TIMEOUT: no interrupt after 500 ms  test=%s", $time, item.label);
            $finish;
        end
        axil_read(RO_REG_AP_CTRL, ap_ctrl_val);
        axil_read(RO_REG_ISR, isr_val);
        $display("[%0t][RO_MON] Interrupt (irq_status=0x%04h)  ap_ctrl=0x%08h  ISR=0x%08h",
                 $time, irq_status, ap_ctrl_val, isr_val);
        if (!ap_ctrl_val[2])
            $error("[%0t][RO_MON] not idle after done (ap_ctrl=0x%08h)  test=%s", $time, ap_ctrl_val, item.label);
        axil_write(RO_REG_ISR, isr_val);
        axil_write(RO_REG_GIE, 32'h0);
        if (irq.sig) @(negedge irq.sig);
    endtask
endclass

// =========================================================================
// ro_scoreboard — the whole C region against the fixture
// =========================================================================
class ro_scoreboard extends base_scoreboard;
    virtual function string kernel_name(); return "RowOpsKernel"; endfunction

    task run(ro_item item);
        logic [CHUNK_BITS-1:0] rd_buf;
        int unsigned total, i, j, nb, errors;
        byte unsigned got;

        total  = item.exp_c.size();
        errors = 0;
        for (i = 0; i < total; i += CHUNK_BYTES) begin
            nb = (total - i < CHUNK_BYTES) ? total - i : CHUNK_BYTES;
            `PS.read_mem(item.addr_c + 40'(i), nb, rd_buf);
            for (j = 0; j < nb; j++) begin
                got = rd_buf[j*8 +: 8];
                if (got !== item.exp_c[i + j]) begin
                    if (errors < 6)
                        $display("[%0t][RO_SCB] MISMATCH %s byte %0d: got=0x%02x exp=0x%02x",
                                 $time, item.label, i + j, got, item.exp_c[i + j]);
                    errors++;
                end
            end
        end

        total_tests++;
        if (errors == 0) begin
            pass_cnt++;
            $display("[%0t][RO_SCB] PASS  %-28s  %0d bytes", $time, item.label, total);
        end else begin
            fail_cnt++;
            $display("[%0t][RO_SCB] FAIL  %-28s  %0d/%0d bytes wrong", $time, item.label, errors, total);
        end
    endtask
endclass

// =========================================================================
// ro_env
// =========================================================================
class ro_env;
    ro_driver     drv;
    ro_monitor    mon;
    ro_scoreboard scb;

    function new(virtual irq_if irq, int unsigned irq_ch);
        drv = new();
        mon = new(irq, irq_ch);
        scb = new();
    endfunction

    task run_one(ro_item item);
        drv.run(item);
        mon.run(item);
        scb.run(item);
    endtask
endclass

// =========================================================================
// ro_test — the table load, then the fixtures of the manifest
// =========================================================================
class ro_test;
    ro_env e;
    string data_dir;

    function new(virtual irq_if irq, int unsigned irq_ch, string dir);
        e = new(irq, irq_ch);
        data_dir = dir;
    endfunction

    // the manifest's row -> an item with its images
    function ro_item parse(string line);
        ro_item it;
        int idx, op, n, c1, c2, a_s1, a_s2, b_s1, b_s2, c_s1, c_s2, aux, bq_sh;
        longint eps, win_lo, win_hi;
        string label, pre;
        if ($sscanf(line, "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %s",
                    idx, op, n, c1, c2, a_s1, a_s2, b_s1, b_s2, c_s1, c_s2, eps, aux, bq_sh,
                    win_lo, win_hi, label) != 17)
            return null;
        it = new(label);
        it.idx = idx; it.op = op; it.n = n; it.rows = c1; it.blocks = c2;
        it.a_s1 = a_s1; it.a_s2 = a_s2; it.b_s1 = b_s1; it.b_s2 = b_s2; it.c_s1 = c_s1; it.c_s2 = c_s2;
        it.eps = eps; it.aux = aux; it.bq_sh = bq_sh; it.win_lo = win_lo[31:0]; it.win_hi = win_hi[31:0];
        pre = $sformatf("%s/test_%02d_", data_dir, idx);
        void'(ro_read_hex({pre, "a.hex"}, it.img_a));
        void'(ro_read_hex({pre, "b.hex"}, it.img_b));
        void'(ro_read_hex({pre, "p.hex"}, it.img_p));
        if (!ro_read_hex({pre, "c.hex"}, it.exp_c))
            $error("[RO] missing %sc.hex", pre);
        it.addr_a = it.img_a.size() ? RO_BUF_A : 40'h0;
        it.addr_b = it.img_b.size() ? RO_BUF_B : 40'h0;
        it.addr_p = it.img_p.size() ? RO_BUF_P : 40'h0;
        it.addr_c = RO_BUF_C;
        return it;
    endfunction

    task run();
        ro_item it;
        int fd, ncases;
        string line;

        // the tables (A = the image; no B, no C, no P)
        it = new("table_load");
        it.tload = 1;
        if (!ro_read_hex({data_dir, "/tables.hex"}, it.img_a) || it.img_a.size() != RO_IMG_MAX) begin
            $error("[RO] %s/tables.hex: missing or not %0d bytes (%0d)", data_dir, RO_IMG_MAX, it.img_a.size());
            e.scb.total_tests++; e.scb.fail_cnt++;
            return;
        end
        it.op = RO_TLOAD_OPWORD; it.n = RO_TLOAD_N; it.rows = RO_TLOAD_ROWS; it.blocks = 1;
        it.a_s1 = RO_TLOAD_S1; it.a_s2 = RO_TLOAD_S2;
        it.b_s1 = 0; it.b_s2 = 0; it.c_s1 = 0; it.c_s2 = 0;
        it.eps = 64'h0; it.aux = 0; it.bq_sh = 0; it.win_lo = 0; it.win_hi = 32'hFFFF_FFFF;
        it.addr_a = RO_BUF_T; it.addr_b = 40'h0; it.addr_c = 40'h0; it.addr_p = 40'h0;
        e.run_one(it);          // the scoreboard counts it as a pass: nothing is written

        fd = $fopen({data_dir, "/manifest.txt"}, "r");
        if (fd == 0) begin
            $error("[RO] cannot open %s/manifest.txt (plusarg +ROWOPS_DATA=<dir>)", data_dir);
            e.scb.total_tests++; e.scb.fail_cnt++;
            return;
        end
        ncases = 0;
        while (!$feof(fd)) begin
            if ($fgets(line, fd) == 0) break;
            if (line.len() == 0 || line[0] == "#" || line[0] == "\n") continue;
            it = parse(line);
            if (it == null) continue;
            e.run_one(it);
            ncases++;
        end
        $fclose(fd);
        $display("[%0t][RO_TEST] %0d fixture(s) from %s", $time, ncases, data_dir);
        e.scb.print_summary();
    endtask
endclass
