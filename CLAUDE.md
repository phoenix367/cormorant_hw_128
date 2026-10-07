# CLAUDE.md — cormorant_hw_128

Vivado 2025.2 block design project for the **Xilinx KV260 Starter Kit**
(xck26-sfvc784-2LV-c). Instantiates four accelerator IP cores (the
ConvKernel, the MatmulKernel, the VectorOPKernel and the PoolingKernel, all
in SystemVerilog since 2026-10-06; the VLNVs of the retired Vitis HLS
exports) connected to the Zynq MPSoC PS via a 128-bit AXI bus.

## What Lives Here

| Path | Purpose |
|------|---------|
| `cormorant_hw_128.xpr` | Vivado project file — open this in Vivado |
| `cormorant_hw_128.srcs/sources_1/bd/design_cormorant/design_cormorant.bd` | Block diagram JSON |
| `cormorant_hw_128.srcs/sources_1/bd/design_cormorant/ip/*/` | IP core configurations (`.xci`) |
| `cormorant_hw_128.srcs/sim_1/new/` | Simulation testbench (SystemVerilog) |
| `cormorant_tb_behav.wcfg` | Waveform configuration for Vivado simulator |
| `build.sh`, `sim.sh`, `scripts/` | Batch build / simulation wrappers and their Tcl (`build.tcl`, `sim.tcl`, `ip_defaults.tcl`, `bd_kernel_clock.tcl`) |
| `cormorant_hw_128.srcs/constrs_1/new/kernel_clock.xdc` | Timing constraints of the 250 MHz kernel clock |

Generated directories (`*.runs/`, `*.gen/`, `*.ip_user_files/`, `*.sim/`,
`*.cache/`, `*.hw/`) are excluded from git — regenerate them by opening the
project and running synthesis/implementation.

## Block Design (`design_cormorant`)

The block design instantiates:

| Instance | IP | AXI-Lite base | Data bus |
|----------|----|--------------|----------|
| `VectorOPKernel_0` | VectorOPKernel | `0xA000_0000` | 128-bit AXI4 on `S_AXI_HPC0_FPD` |
| `MatmulKernel_0` | MatmulKernel | `0xA001_0000` | 128-bit AXI4: A/C on `S_AXI_HPC0_FPD`, B on `S_AXI_HPC1_FPD` |
| `ConvKernel_0` | ConvKernel | `0xA002_0000` | 128-bit AXI4: x/y on `S_AXI_HPC0_FPD`, w/b on `S_AXI_HPC1_FPD` |
| `PoolingKernel_0` | PoolingKernel | `0xA003_0000` | 128-bit AXI4 on `S_AXI_HPC0_FPD` |
| `zynq_ultra_ps_e_0` | Zynq MPSoC PS | — | AXI master + DDR controller |

The kernel data masters are aggregated through `axi_interconnect_0` (into
`S_AXI_HPC0_FPD`) and `axi_mem_intercon` (into `S_AXI_HPC1_FPD`) on the PS.
AXI-Lite control ports go from `M_AXI_HPM0_FPD` through the `axi_smc`
SmartConnect. Each kernel drives an interrupt line back to the PS.

**Clock (since 2026-10-06, the parent repo's `doc/plans/FMAX_250_PLAN.md`).**
Everything in the PL — the four kernels, both interconnects, the SmartConnect,
the PS-PL AXI port clocks (`maxihpm0_fpd_aclk`, `saxihpc0/1_fpd_aclk`) and the
reset block — runs on `clk_wiz_0/clk_out1`, **250 MHz** (249.9975: an MMCM
fed by `pl_clk0`, which stays at the boot firmware's 100 MHz).  The bitstream
thus defines its own kernel clock; PL0 only feeds the MMCM, and the parent
repo's loader checks it against the HWH's 100 MHz before programming (and
sets it when it differs), so a stale PL0 setting can neither change the
kernel clock nor overclock an older 100 MHz bitstream.
`pl_resetn0` resets the MMCM; its `locked` holds `rst_ps8_0_99M`
(`dcm_locked`).  The two data interconnects carry register slices ("Outer")
on every SI and on `axi_interconnect_0`'s MI (the read-only HPC1 MI has
none); `cormorant_hw_128.srcs/constrs_1/new/kernel_clock.xdc` replicates the
HPC0 slice's ready.  `scripts/bd_kernel_clock.tcl` makes all of it from the
100 MHz design (idempotent), and `scripts/build.tcl` runs impl_1 with
`place_design ExtraTimingOpt`, `phys_opt_design` / `route_design`
`AggressiveExplore` and post-route `phys_opt_design` — with the project's
default strategy the same netlist missed 4 ns by tens of ps.  Routed:
WNS +0.105 ns, WHS +0.010 ns (bitstream `986cef4866a0`); with VectorOPKernel's
activation unit (the parent repo's `doc/plans/ACTIVATIONS_PLAN.md`) WNS
+0.061 ns, WHS +0.010 ns (bitstream `6436623029f7`, production).

Since 2026-09-26 (RESNET18_15FPS_PLAN.md step 6) a second 128-bit PS port
`S_AXI_HPC1_FPD` is fed by `axi_mem_intercon` (ConvKernel w/b, MatmulKernel
B); `axi_interconnect_0` → HPC0 keeps the other nine data masters.  It was
neutral at 100 MHz (all layers compute-bound) and is kept for the 250 MHz
clock.  When moving a master between ports in Tcl, delete its stale
`SEG_*` address segments first or `assign_bd_address` collides.

Until 2026-09-24 every kernel instance and `S_AXI_HPC0_FPD` were in fact
32-bit (`C_M_AXI_*_DATA_WIDTH = 32`, `PSU__SAXIGP0__DATA_WIDTH = 32`,
interconnect crossbar 32) — the conv kernel's native 128-bit weight port
was narrowed 4:1 by its own adapter.  Now the kernels are exported with
`-m_axi_min_bitwidth 128` (CMake `AXI_BUS_WIDTH=128`), the instance
parameters are 128 and HPC0 is 128.  Do not widen the instance
parameters beyond the IP's own default: the HLS wrapper's
`C_M_AXI_*_WSTRB_WIDTH` literal does not follow, and WSTRB ends up
4 bits wide.  `build.tcl` / `sim.tcl` enforce it: after the IP upgrade,
`scripts/ip_defaults.tcl` resets every kernel instance's
`C_M_AXI_*_DATA_WIDTH` to the default of the IP in the catalogue (read from
a temporary instance; Vivado has no reset to default).  Two IPs share the
MatmulKernel VLNV — the HLS export (gmem2 32 bits) and the parent repo's
SystemVerilog kernel (`kernels/matmul_rtl`, gmem2 128, the one the parent
build packages, `make package_matmul_rtl`) — and `upgrade_ip` keeps the
instance's old value.

**Incremental synthesis is OFF on `synth_1` (2026-09-25).**  The run had
`AutoIncrementalCheckpoint` with a reference checkpoint from the old
`~/vivado_projects` copy; a rebuild reused 93 % of that stale netlist and
dropped a register that had just been added to MatmulKernel's AXI-Lite
block (`b_packed`, 0x6C) although the HWH, drivers and generated HDL all
had it — the board then silently ran the old control block.  Keep
`INCREMENTAL_CHECKPOINT` empty; after any kernel IP change verify a new
register on the board with a write-then-read before trusting results.

The `_128` suffix indicates the 128-bit (`m_axi` DATA_WIDTH=128) data ports of
all four kernels (once a Vitis HLS synthesis option, now the RTL IPs' fixed
width), which doubles DDR bandwidth versus the 64-bit default.

## Synthesis and Implementation

Open in Vivado 2025.2:

```tcl
# In Vivado Tcl console — or File → Open Project
open_project cormorant_hw_128.xpr
```

From the Vivado GUI or Tcl:

```tcl
launch_runs synth_1 -jobs 8
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
```

The final bitstream is written to:
`cormorant_hw_128.runs/impl_1/design_cormorant_wrapper.bit`

## Simulation Testbench

The testbench in `cormorant_hw_128.srcs/sim_1/new/` uses a UVM-style OOP
pattern in plain SystemVerilog (no UVM library dependency). All files are
`\`include`-d into the single top-level module `cormorant_tb.sv`.

### File Inventory

| File | Role |
|------|------|
| `cormorant_tb.sv` | Top module: DUT instantiation, PS VIP reset, test sequencing, overall report |
| `cormorant_addr_map.svh` | AXI-Lite base addresses (auto-generated by `gen_addr_map.tcl`) |
| `vop_regmap.svh` | VectorOPKernel register offsets, op codes, DDR buffer addresses |
| `conv_regmap.svh` | ConvKernel register offsets and DDR layout |
| `mm_regmap.svh` | MatmulKernel register offsets and DDR layout |
| `pk_regmap.svh` | PoolingKernel register offsets and DDR layout |
| `axil_agent.svh` | Virtual base class: `axil_write` / `axil_read` via PS VIP |
| `base_scoreboard.svh` | Abstract base: pass/fail counters, `check()`, `report()` |
| `tb_functions.svh` | Fixed-point reference helpers: `ref_add` … `ref_relu6`, `compute_*_const`, `ref_poly_sqrt`, `conv_const_weights`, DDR fills |
| `tb_infra.svh` | PS VIP DDRC write-commit workaround (inactive-region race fix) |
| `vop_classes.svh` | `vop_item`, `vop_driver`, `vop_monitor`, `vop_scoreboard`, `vop_env`, `vop_test` |
| `conv_classes.svh` | `conv_item`, `conv_driver`, `conv_monitor`, `conv_scoreboard`, `conv_env`, `conv_test` |
| `mm_classes.svh` | `mm_item`, `mm_driver`, `mm_monitor`, `mm_scoreboard`, `mm_env`, `mm_test` |
| `pk_classes.svh` | `pk_item`, `pk_driver`, `pk_monitor`, `pk_scoreboard`, `pk_env`, `pk_test` |
| `gen_addr_map.tcl` | Vivado Tcl script that reads the `.hwh` and writes `cormorant_addr_map.svh` |

### Class Hierarchy

Each kernel follows the same six-class pattern:

```
axil_agent  (axil_agent.svh)
    └── <k>_driver        writes AXI-Lite registers, enables the interrupt, triggers kernel
    └── <k>_monitor       waits for the interrupt, reads ap_ctrl / ISR, clears it

base_scoreboard  (base_scoreboard.svh)
    └── <k>_scoreboard    computes reference result, reads DDR output, checks element-wise

<k>_item     — transaction descriptor (addresses, operands, expected result)
<k>_env      — aggregates driver + monitor/scoreboard, exposes run_one()
<k>_test     — constructs env, defines test cases, calls env.run_one()
```

DUT interrupt signals are wired through a thin `irq_if` interface in
`cormorant_tb.sv` so the class files contain no direct DUT hierarchy paths.

### Running Simulation

From the Vivado GUI: **Flow → Run Simulation → Run Behavioral Simulation**

From Tcl:

```tcl
launch_simulation
run all
```

The testbench prints a per-kernel pass/fail table and a combined summary
(~3 min):

```
##########################################################
##  CORMORANT TESTBENCH — OVERALL RESULTS
##########################################################
##        VectorOPKernel   27 /  27  (0 failed)
##            ConvKernel   17 /  17  (0 failed)
##          MatmulKernel   10 /  10  (0 failed)
##         PoolingKernel   19 /  19  (0 failed)
##########################################################
##  TOTAL: 73 / 73 passed
##  ALL TESTS PASSED
##########################################################
```

`scripts/sim.tcl` exits 1 unless `ALL TESTS PASSED` is logged.  When a
kernel's interface changes, update the testbench with it: buffers are
written as the kernels read them (whole 16-byte words; VectorOP strides 0
or multiples of 8 elements; ConvKernel weights packed tile-major,
`conv_const_weights`; the new registers — VectorOP `act`, MatMul
`b_packed` / `gemv_kw` / `a_to_b` — reset to 0 = off).

### Regenerating the Address Map

After any Vivado re-export or address-space change, regenerate
`cormorant_addr_map.svh` from the Vivado Tcl console:

```tcl
source cormorant_hw_128.srcs/sim_1/new/gen_addr_map.tcl
```

This reads `design_cormorant.hwh` and overwrites `cormorant_addr_map.svh`.

## AXI-Lite Register Maps

### VectorOPKernel (`0xA000_0000`)

| Register | Offset | Description |
|----------|--------|-------------|
| `ap_ctrl` | `+0x00` | Bit 0 = ap_start, bit 1 = ap_done, bit 2 = ap_idle |
| `GIE` | `+0x04` | Global interrupt enable |
| `IER` | `+0x08` | Interrupt enable |
| `ISR` | `+0x0C` | Interrupt status (write 1 to clear) |
| `a_lo/hi` | `+0x10/14` | 64-bit DDR address of input A |
| `b_lo/hi` | `+0x1C/20` | 64-bit DDR address of input B (ignored for unary) |
| `c_lo/hi` | `+0x28/2C` | 64-bit DDR address of output C |
| `size` | `+0x34` | Elements per inner iteration |
| `op` | `+0x3C` | Operation code (0=Add … 5=Relu6, 6=LeakyRelu, 7=SiLU, 8=GELU, 9=GELU tanh) |
| `outer` | `+0x44` | Number of broadcast outer iterations |
| `a_inc` | `+0x4C` | Element stride between A rows |
| `b_inc` | `+0x54` | Element stride between B rows (0 = broadcast) |
| `act` | `+0x5C` | Fused activation after the op (0=none, 1=Relu, 2=Relu6, 3=LeakyRelu, 4=SiLU, 5=GELU, 6=GELU tanh) |
| `alpha` | `+0x64` | LeakyRelu slope, bits 15:0 / 65536 (IPs with the activation unit: the parent repo's `doc/plans/ACTIVATIONS_PLAN.md`) |

### Other Kernels

See the corresponding `*_regmap.svh` file for MatmulKernel (`0xA001_0000`),
ConvKernel (`0xA002_0000`), and PoolingKernel (`0xA003_0000`).

## Element Type

All four kernels are synthesised for **`ap_fixed<16,8>`** (2 bytes per element,
integer bits = 8, range ≈ [-128, 128)). Encoding: `1.0` → `0x0100`.

The testbench `ELEM_BYTES` localparam and the fixed-point helpers in
`tb_functions.svh` are calibrated to this type.

## Key Simulation Notes

- **Reset release with the MMCM** (since the 250 MHz clock): the PL is held
  in reset until `clk_wiz_0` locks, so `cormorant_tb.sv` waits for the BD's
  Verilog net `rst_ps8_0_99M_peripheral_aresetn` (an index into the VHDL
  reset block's port never wakes a `wait` in xsim) with a 200 µs timeout;
  the MMCM locks within 10 µs.  The PS VIPs' 16-cycle ARESETN check is a
  warning: their port clocks come from the MMCM, which `pl_resetn0` holds in
  reset, so they do not toggle during the reset pulse.
- **PS VIP slave profile**: set to `BEST_CASE` (fixed 21-cycle write-response
  latency) on `S_AXI_HPC0_FPD` for deterministic simulation timing.
- **DDRC write-commit workaround** (`tb_infra.svh`): the PS VIP `arb_wr_6`
  module races between active/inactive regions on `wr_req`. The fix intercepts
  every `wr_req` rising edge at +1 ns and commits bytes directly into
  `ddr_mem0`/`ddr_mem1`.
- **WSTRB X**: HLS-generated 128-bit AXI masters leave `WSTRB` uninitialized
  before the first write beat. This triggers a false-positive AXI protocol
  checker error in simulation; the `$assertoff` line in `cormorant_tb.sv` can
  be uncommented to suppress it if needed.
