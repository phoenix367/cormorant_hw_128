# Cormorant HW

Vivado 2025.2 block design for the **Xilinx KV260 Starter Kit**
(xck26-sfvc784-2LV-c). Instantiates four neural-network accelerator IP
cores (the ConvKernel, the MatmulKernel, the VectorOPKernel and the
PoolingKernel, all in SystemVerilog) connected to the Zynq MPSoC PS via AXI.

This is the hardware sub-project of [Cormorant](https://github.com/GradeBuilderSL/cormorant)
— an FPGA neural-network inference accelerator.

## Prerequisites

- **Vivado 2025.2** (with Zynq MPSoC device support)
- KV260 IP catalog entries for the four accelerator kernels (VectorOPKernel,
  MatmulKernel, ConvKernel, PoolingKernel) built from the parent repo

## Quick Start

```bash
git clone git@github.com:GradeBuilderSL/cormorant_hw_128.git
cd cormorant_hw_128
```

Open the project in Vivado:

```tcl
open_project cormorant_hw_128.xpr
```

### Synthesis and Bitstream

From the command line (sources Vivado when `vivado` is not on `PATH`):

```bash
# Full build — synthesis + implementation + bitstream
./build.sh

# Synthesis only
./build.sh synth

# Implementation + bitstream (requires completed synthesis)
./build.sh impl

# Override parallel job count (default: 8)
./build.sh all -jobs 12
```

The scripts use the `vivado` on `PATH` (the parent repo's
`<Xilinx>/2025.2/Vitis/settings64.sh` puts it there); only without one do
they source `VIVADO_SETTINGS`, whose default
(`/mnt/data/xilinx/2025.2/settings64.sh`) is the maintainer's install — set
it to your `settings64.sh`.

The build modifies tracked files (`design_cormorant.bd`, the `.xci` files,
`cormorant_hw_128.xpr`); do not commit them.  Vivado's warning `File not
found as '…/utils_1/imports/synth_1/design_cormorant_wrapper.dcp'; using
path …` is harmless: the project still lists the maintainer's old
incremental-synthesis checkpoint, and incremental synthesis is off.

From the Vivado Tcl console:

```tcl
source scripts/build.tcl
source scripts/build.tcl synth
source scripts/build.tcl impl -jobs 12
```

The bitstream is written to:
`cormorant_hw_128.runs/impl_1/design_cormorant_wrapper.bit`

### Simulation

From the command line:

```bash
./sim.sh
./sim.sh -ip-repo /path/to/kernels
```

Or from the Vivado Tcl console:

```tcl
source scripts/sim.tcl
```

The run takes ~3 minutes (75 constant-fill cases over the four kernels
through the PS VIP's DDR model) and ends with:

```
##########################################################
##  CORMORANT TESTBENCH — OVERALL RESULTS
##########################################################
##        VectorOPKernel   29 /  29  (0 failed)
##            ConvKernel   17 /  17  (0 failed)
##          MatmulKernel   10 /  10  (0 failed)
##         PoolingKernel   19 /  19  (0 failed)
##########################################################
##  TOTAL: 75 / 75 passed
##  ALL TESTS PASSED
##########################################################
```

`scripts/sim.tcl` exits 1 unless `simulate.log` contains `ALL TESTS PASSED`
(a missing log or an early stop, e.g. an AXI protocol-checker fatal, is a
failure).  The testbench (`cormorant_hw_128.srcs/sim_1/new/`) writes every
buffer the way the kernels read it: whole 16-byte words, VectorOP row
strides of 0 or multiples of 8 elements, ConvKernel weights in the packed
tile-major layout (`tb_functions.svh` `conv_const_weights`, see the parent
repo's `kernels/conv/include/ConvKernel.h`), and the LpPool p=2 reference
mirrors the kernel's fixed-point `poly_sqrt` bit for bit.

## Block Design

| Instance | IP | AXI-Lite base | Data bus |
|----------|----|--------------|----------|
| `VectorOPKernel_0` | Element-wise ops (Add/Sub/Mul/Div/Relu/Relu6, fused Relu / Relu6 `act`) — the parent repo's SystemVerilog kernel (`kernels/vectorop_rtl`, `make package_vectorop_rtl`; same VLNV, widths and m_axi bus parameters as the retired HLS one) | `0xA000_0000` | gmem0–2 → `S_AXI_HPC0_FPD` |
| `MatmulKernel_0` | Tiled matrix multiply, GEMV streaming — the parent repo's SystemVerilog kernel (`kernels/matmul_rtl`, `make package_matmul_rtl`; same VLNV as the retired HLS one) | `0xA001_0000` | gmem0, gmem2 → `S_AXI_HPC0_FPD`; gmem1 → `S_AXI_HPC1_FPD` |
| `ConvKernel_0` | 2-D convolution (NCHW), MatMuls as convs — the parent repo's SystemVerilog kernel (`kernels/conv_rtl`, `make package_conv_rtl`; same VLNV, widths and m_axi bus parameters as the retired HLS one) | `0xA002_0000` | gmem0, gmem3 → `S_AXI_HPC0_FPD`; gmem1, gmem2 → `S_AXI_HPC1_FPD` |
| `PoolingKernel_0` | Max/Avg/Lp/Global pooling — the parent repo's SystemVerilog kernel (`kernels/pool_rtl`, `make package_pool_rtl`; same VLNV, widths and m_axi bus parameters as the retired HLS one) | `0xA003_0000` | gmem0–1 → `S_AXI_HPC0_FPD` |

All data ports are 128-bit AXI4.  Eight of them aggregate through
`axi_interconnect_0` into `S_AXI_HPC0_FPD`, the other four (ConvKernel
gmem1 / gmem2, MatmulKernel gmem1, VectorOPKernel gmem1 — its b operand,
since 2026-10-08: `scripts/bd_vop_b_hpc1.tcl`, the parent repo's
`doc/plans/PS_PORTS_PLAN.md` §5) through `axi_mem_intercon` into
`S_AXI_HPC1_FPD`; both PS-side widths (`PSU__SAXIGP0__DATA_WIDTH`,
`PSU__SAXIGP1__DATA_WIDTH`) are 128 bits.  (`S_AXI_HPC0_FPD` had been left
at 32 until 2026-09-24, which capped all PL↔DDR traffic at 32 bits ×
100 MHz (400 MB/s) and cost 4 cycles per 128-bit kernel word;
`upload_bitstream.py` also writes the AFIFM width registers after the
overlay.)  The AXI-Lite control ports hang off `M_AXI_HPM0_FPD` through
the `axi_smc` SmartConnect.
Each kernel drives an interrupt line back to the PS.

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
+0.061 ns, WHS +0.010 ns (bitstream `6436623029f7`); with its softmax unit
(`doc/plans/SOFTMAX_PLAN.md`) WNS +0.041 ns, WHS +0.010 ns (bitstream
`588d721997cb`); with VectorOPKernel's b read port on HPC1
(`doc/plans/PS_PORTS_PLAN.md` §5) WNS +0.114 ns, WHS +0.010 ns (bitstream
`8599aa7a5f12`, production).

Instance widths follow the IPs: after the IP upgrade, `build.tcl` and
`sim.tcl` put every kernel instance's `C_M_AXI_*_DATA_WIDTH` back to the
default of the IP in the catalogue (`scripts/ip_defaults.tcl`).  The two
MatmulKernel IPs differ there: the HLS export's gmem2 is 32 bits, the RTL
kernel's 128, and `upgrade_ip` keeps the instance's old value.

Element type: **`ap_fixed<16,8>`** — 2 bytes per element, range ≈ [-128, 128),
encoding `1.0 = 0x0100`.

## Repository Structure

```
cormorant_hw_128.xpr                         Vivado project file
cormorant_tb_behav.wcfg                      Waveform config for simulator
build.sh                                     Shell wrapper: synthesis / impl / bitstream
sim.sh                                       Shell wrapper: behavioral simulation
scripts/build.tcl                            Tcl build script (stage + job-count selection)
scripts/sim.tcl                              Tcl simulation script
scripts/ip_defaults.tcl                      Kernel instance m_axi widths := the IP defaults
cormorant_hw_128.srcs/
  sources_1/bd/design_cormorant/
    design_cormorant.bd                      Block diagram
    design_cormorant.bda                     Automation settings
    ui/                                      Block diagram visual layout
    ip/*/                                    IP core configurations (.xci)
  sim_1/new/
    cormorant_tb.sv                          Testbench top module
    cormorant_addr_map.svh                   AXI-Lite base addresses
    {vop,conv,mm,pk}_regmap.svh              Per-kernel register maps
    {vop,conv,mm,pk}_classes.svh             Per-kernel test class hierarchies
    axil_agent.svh                           AXI-Lite read/write base class
    base_scoreboard.svh                      Pass/fail counter base class
    tb_functions.svh                         Fixed-point arithmetic helpers
    tb_infra.svh                             PS VIP DDRC write-commit workaround
    gen_addr_map.tcl                         Regenerates cormorant_addr_map.svh
```

Generated directories (`*.runs/`, `*.gen/`, `*.ip_user_files/`, `*.sim/`,
`*.cache/`, `*.hw/`) are excluded from git and recreated by Vivado on first
open/run.

## Regenerating the Address Map

After any re-export or address-space change, run from the Vivado Tcl console:

```tcl
source cormorant_hw_128.srcs/sim_1/new/gen_addr_map.tcl
```

This reads `design_cormorant.hwh` and overwrites `cormorant_addr_map.svh`.

## Funding

[![dAIEDGE Project](https://img.shields.io/badge/dAIEDGE-Project-6A5ACD?style=for-the-badge)](https://daiedge.eu/)
[![EU Horizon Europe](https://img.shields.io/badge/Funded%20by-EU%20Horizon%20Europe-003399?style=for-the-badge&logo=europeanunion&logoColor=white)](https://research-and-innovation.ec.europa.eu/funding/funding-opportunities/funding-programmes-and-open-calls/horizon-europe_en)

This work was supported by the **[dAIEDGE Open Call Programme](https://daiedge.eu/)**, funded by the **[European Union's Horizon Europe research and innovation programme](https://research-and-innovation.ec.europa.eu/funding/funding-opportunities/funding-programmes-and-open-calls/horizon-europe_en)** under project number **#101120726**.

---

## License

Copyright 2025 GradeBuilder SL. Licensed under the
[Apache License, Version 2.0](LICENSE).
