// vop_regmap.svh — VectorOPKernel AXI-Lite register map, op codes, DDR buffers.
// Requires VectorOPKernel_0_BASE from cormorant_addr_map.svh.

localparam [39:0] CTRL_BASE   = VectorOPKernel_0_BASE;
localparam [39:0] REG_AP_CTRL = CTRL_BASE + 40'h00;
localparam [39:0] REG_GIE     = CTRL_BASE + 40'h04;
localparam [39:0] REG_IER     = CTRL_BASE + 40'h08;
localparam [39:0] REG_ISR     = CTRL_BASE + 40'h0c;
localparam [39:0] REG_A_LO    = CTRL_BASE + 40'h10;
localparam [39:0] REG_A_HI    = CTRL_BASE + 40'h14;
localparam [39:0] REG_B_LO    = CTRL_BASE + 40'h1c;
localparam [39:0] REG_B_HI    = CTRL_BASE + 40'h20;
localparam [39:0] REG_C_LO    = CTRL_BASE + 40'h28;
localparam [39:0] REG_C_HI    = CTRL_BASE + 40'h2c;
localparam [39:0] REG_SIZE    = CTRL_BASE + 40'h34;
localparam [39:0] REG_OP      = CTRL_BASE + 40'h3c;
localparam [39:0] REG_OUTER   = CTRL_BASE + 40'h44;
localparam [39:0] REG_A_INC   = CTRL_BASE + 40'h4c;
localparam [39:0] REG_B_INC   = CTRL_BASE + 40'h54;

// Op codes — must match VectorOP.h
localparam [31:0] OP_ADD     = 32'd0;
localparam [31:0] OP_SUB     = 32'd1;
localparam [31:0] OP_MUL     = 32'd2;
localparam [31:0] OP_DIV     = 32'd3;
localparam [31:0] OP_RELU    = 32'd4;
localparam [31:0] OP_RELU6   = 32'd5;
localparam [31:0] OP_SOFTMAX = 32'd6;   // unary, axis=-1; b[] not read

// DDR buffer layout for VectorOP tests (40-bit PS address space)
localparam [39:0] DDR_BASE   = 40'h1000_0000;
localparam [39:0] BUF_STRIDE = 40'h0001_0000;   // 64 KB guard gap
localparam [39:0] BUF_A      = DDR_BASE + 40'(0) * BUF_STRIDE;
localparam [39:0] BUF_B      = DDR_BASE + 40'(1) * BUF_STRIDE;
localparam [39:0] BUF_C      = DDR_BASE + 40'(2) * BUF_STRIDE;
