// mm_regmap.svh — MatmulKernel AXI-Lite register map.
// Source: xmatmulkernel_hw.h  Requires MatmulKernel_0_BASE from cormorant_addr_map.svh.

localparam [39:0] MM_BASE        = MatmulKernel_0_BASE;
localparam [39:0] MM_AP_CTRL     = MM_BASE + 40'h00;
localparam [39:0] MM_GIE         = MM_BASE + 40'h04;
localparam [39:0] MM_IER         = MM_BASE + 40'h08;
localparam [39:0] MM_ISR         = MM_BASE + 40'h0C;
localparam [39:0] MM_A_LO        = MM_BASE + 40'h10;
localparam [39:0] MM_A_HI        = MM_BASE + 40'h14;
localparam [39:0] MM_B_LO        = MM_BASE + 40'h1C;
localparam [39:0] MM_B_HI        = MM_BASE + 40'h20;
localparam [39:0] MM_C_LO        = MM_BASE + 40'h28;
localparam [39:0] MM_C_HI        = MM_BASE + 40'h2C;
localparam [39:0] MM_N           = MM_BASE + 40'h34;
localparam [39:0] MM_K           = MM_BASE + 40'h3C;
localparam [39:0] MM_M           = MM_BASE + 40'h44;
localparam [39:0] MM_BATCH       = MM_BASE + 40'h4C;
localparam [39:0] MM_A_BATCH_STR = MM_BASE + 40'h54;
localparam [39:0] MM_B_BATCH_STR = MM_BASE + 40'h5C;
localparam [39:0] MM_C_BATCH_STR = MM_BASE + 40'h64;
