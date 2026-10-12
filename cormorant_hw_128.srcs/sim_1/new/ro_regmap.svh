// ro_regmap.svh — RowOpsKernel AXI-Lite register map (the parent repo's
// kernels/rowops_rtl/scripts/gen_driver.py, checked against rtl/ro_ctrl_s_axi.sv),
// the op word's fields and the DDR buffers of the testbench.
// Requires RowOpsKernel_0_BASE from cormorant_addr_map.svh.

localparam [39:0] RO_BASE        = RowOpsKernel_0_BASE;
localparam [39:0] RO_REG_AP_CTRL = RO_BASE + 40'h00;
localparam [39:0] RO_REG_GIE     = RO_BASE + 40'h04;
localparam [39:0] RO_REG_IER     = RO_BASE + 40'h08;
localparam [39:0] RO_REG_ISR     = RO_BASE + 40'h0c;
localparam [39:0] RO_REG_OP      = RO_BASE + 40'h10;   // op word (below)
localparam [39:0] RO_REG_N       = RO_BASE + 40'h14;   // columns per row (<= 4096)
localparam [39:0] RO_REG_ROWS    = RO_BASE + 40'h18;   // rows per block
localparam [39:0] RO_REG_BLOCKS  = RO_BASE + 40'h1c;   // blocks
localparam [39:0] RO_REG_A_LO    = RO_BASE + 40'h20;   // stream A base (64-bit)
localparam [39:0] RO_REG_A_HI    = RO_BASE + 40'h24;
localparam [39:0] RO_REG_A_S1    = RO_BASE + 40'h28;   // A row stride (bytes)
localparam [39:0] RO_REG_A_S2    = RO_BASE + 40'h2c;   // A block stride (bytes)
localparam [39:0] RO_REG_B_LO    = RO_BASE + 40'h30;   // stream B base (B_EN)
localparam [39:0] RO_REG_B_HI    = RO_BASE + 40'h34;
localparam [39:0] RO_REG_B_S1    = RO_BASE + 40'h38;
localparam [39:0] RO_REG_B_S2    = RO_BASE + 40'h3c;
localparam [39:0] RO_REG_C_LO    = RO_BASE + 40'h40;   // output base
localparam [39:0] RO_REG_C_HI    = RO_BASE + 40'h44;
localparam [39:0] RO_REG_C_S1    = RO_BASE + 40'h48;
localparam [39:0] RO_REG_C_S2    = RO_BASE + 40'h4c;
localparam [39:0] RO_REG_P_LO    = RO_BASE + 40'h50;   // parameter block (16 B per column, or one: P_BCAST)
localparam [39:0] RO_REG_P_HI    = RO_BASE + 40'h54;
localparam [39:0] RO_REG_EPS_LO  = RO_BASE + 40'h58;   // NORM's epsilon term (64-bit)
localparam [39:0] RO_REG_EPS_HI  = RO_BASE + 40'h5c;
localparam [39:0] RO_REG_AUX     = RO_BASE + 40'h60;   // ROPE head dim / TRANSPOSE rows
localparam [39:0] RO_REG_BQ_SH   = RO_BASE + 40'h64;   // beta shift
localparam [39:0] RO_REG_WIN_LO  = RO_BASE + 40'h68;   // window (ADDX / NORM rows kept)
localparam [39:0] RO_REG_WIN_HI  = RO_BASE + 40'h6c;

// op word: [3:0] op, [5:4] A kind, [7:6] B kind, [9:8] C kind (0 i16, 1 i32,
// 2 f32), bit 12 B_EN, 13 P_BCAST, 14 P_KEEP, 15 RELU, 16 NORM_LN
localparam [31:0] RO_OP_COPY    = 32'd1;
localparam [31:0] RO_OP_ADDX    = 32'd2;
localparam [31:0] RO_OP_DEQUANT = 32'd3;
localparam [31:0] RO_OP_MULACT  = 32'd4;
localparam [31:0] RO_OP_NORM    = 32'd5;
localparam [31:0] RO_OP_ROPE    = 32'd6;
localparam [31:0] RO_OP_XPOSE   = 32'd7;
localparam [31:0] RO_OP_TLOAD   = 32'd8;
// the table load (the scheduler's inference_init: A i32 rows of 4096 words,
// 4 rows at 16 KiB = the 64 KiB image; B / C kinds i32, no B)
localparam [31:0] RO_TLOAD_OPWORD = 32'h0000_0158;
localparam int unsigned RO_TLOAD_N    = 4096;
localparam int unsigned RO_TLOAD_ROWS = 4;
localparam int unsigned RO_TLOAD_S1   = 16384;
localparam int unsigned RO_TLOAD_S2   = 65536;

// DDR buffers of the RowOps tests (40-bit PS address space), 1 MiB apart:
// the table image, then the fixtures' A / B / P regions and the C region
localparam [39:0] RO_DDR_BASE = 40'h3000_0000;
localparam [39:0] RO_BUF_T    = RO_DDR_BASE + 40'h0000_0000;
localparam [39:0] RO_BUF_A    = RO_DDR_BASE + 40'h0010_0000;
localparam [39:0] RO_BUF_B    = RO_DDR_BASE + 40'h0020_0000;
localparam [39:0] RO_BUF_P    = RO_DDR_BASE + 40'h0030_0000;
localparam [39:0] RO_BUF_C    = RO_DDR_BASE + 40'h0040_0000;
localparam int unsigned RO_IMG_MAX = 65536;              // the largest region (the table image)
localparam [7:0]        RO_POISON  = 8'hDE;              // gen_fixtures.py: the C region's fill
