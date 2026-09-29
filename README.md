# Cormorant HW

Vivado 2025.2 block design for the **Xilinx KV260 Starter Kit**
(xck26-sfvc784-2LV-c). Instantiates four HLS neural-network accelerator IP
cores connected to the Zynq MPSoC PS via AXI.

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

**Known issue: the testbench is stale and the simulation fails.**
VectorOPKernel passes 19 / 25 (`bcast_relu6` and the five `sm_*` tests,
which use `op=6`, a Softmax op the kernel no longer has, fail); ConvKernel
test 1 of 17 then stops the run with the AXI protocol checker's
`AXI4_ERRS_RDATA_X` fatal on `S_AXI_HPC1_FPD` (the weight port reads bytes
the testbench never wrote), so MatmulKernel and PoolingKernel never run.
`scripts/sim.tcl` exits 1 unless `simulate.log` contains `ALL TESTS PASSED`
(a missing log or an early stop is a failure).  Verify the kernels with the
parent repo's per-kernel RTL behaviour tests (`make behavior_test`,
`hw/cormorant_test_stand`), which pass.

A passing run ends with one line per kernel scoreboard:

```
##########################################################
##  CORMORANT TESTBENCH — OVERALL RESULTS
##########################################################
##  VectorOPKernel         N /   N  (0 failed)
##  ConvKernel             N /   N  (0 failed)
##  MatmulKernel           N /   N  (0 failed)
##  PoolingKernel          N /   N  (0 failed)
##########################################################
##  TOTAL: N / N passed
##  ALL TESTS PASSED
##########################################################
```

## Block Design

| Instance | IP | AXI-Lite base | Data bus |
|----------|----|--------------|----------|
| `VectorOPKernel_0` | Element-wise ops (Add/Sub/Mul/Div/Relu/Relu6, fused Relu / Relu6 `act`) | `0xA000_0000` | gmem0–2 → `S_AXI_HPC0_FPD` |
| `MatmulKernel_0` | Tiled matrix multiply, GEMV streaming | `0xA001_0000` | gmem0, gmem2 → `S_AXI_HPC0_FPD`; gmem1 → `S_AXI_HPC1_FPD` |
| `ConvKernel_0` | 2-D convolution (NCHW) | `0xA002_0000` | gmem0, gmem3 → `S_AXI_HPC0_FPD`; gmem1, gmem2 → `S_AXI_HPC1_FPD` |
| `PoolingKernel_0` | Max/Avg/Lp/Global pooling | `0xA003_0000` | gmem0–1 → `S_AXI_HPC0_FPD` |

All data ports are 128-bit AXI4.  Nine of them aggregate through
`axi_interconnect_0` into `S_AXI_HPC0_FPD`, the other three (ConvKernel
gmem1 / gmem2, MatmulKernel gmem1) through `axi_mem_intercon` into
`S_AXI_HPC1_FPD`; both PS-side widths (`PSU__SAXIGP0__DATA_WIDTH`,
`PSU__SAXIGP1__DATA_WIDTH`) are 128 bits.  (`S_AXI_HPC0_FPD` had been left
at 32 until 2026-09-24, which capped all PL↔DDR traffic at 32 bits ×
100 MHz (400 MB/s) and cost 4 cycles per 128-bit kernel word;
`upload_bitstream.py` also writes the AFIFM width registers after the
overlay.)  The AXI-Lite control ports hang off `M_AXI_HPM0_FPD` through
the `axi_smc` SmartConnect.
Each kernel drives an interrupt line back to the PS.

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
