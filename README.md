# Cormorant HW — 128-bit AXI Variant

Vivado 2025.2 block design for the **Xilinx KV260 Starter Kit**
(xck26-sfvc784-2LV-c). Instantiates four HLS neural-network accelerator IP
cores connected to the Zynq MPSoC PS via a 128-bit AXI data bus.

This is the hardware sub-project of [Cormorant](https://github.com/GradeBuilderSL/cormorant)
— an FPGA neural-network inference accelerator. The `_128` suffix denotes
128-bit `m_axi` bus width for all four kernels (doubles DDR bandwidth vs the
64-bit default).

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

From the command line (sources Vivado automatically):

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

`VIVADO_SETTINGS` can be set to override the default Vivado install path
(`/mnt/data/xilinx/2025.2/settings64.sh`).

From the Vivado Tcl console:

```tcl
source scripts/build.tcl
source scripts/build.tcl synth
source scripts/build.tcl impl -jobs 12
```

The bitstream is written to:
`cormorant_hw_128.runs/impl_1/design_cormorant_wrapper.bit`

### Simulation

**Flow → Run Simulation → Run Behavioral Simulation**, or from the Tcl console:

```tcl
launch_simulation
run all
```

Expected output:

```
##########################################################
##  CORMORANT TESTBENCH — OVERALL RESULTS
##########################################################
##  VectorOPKernel     12 /  12  (0 failed)
##  ConvKernel         18 /  18  (0 failed)
##  MatmulKernel        8 /   8  (0 failed)
##  PoolingKernel      10 /  10  (0 failed)
##########################################################
##  TOTAL: 48 / 48 passed
##  ALL TESTS PASSED
##########################################################
```

## Block Design

| Instance | IP | AXI-Lite base | Data bus |
|----------|----|--------------|----------|
| `VectorOPKernel_0` | Element-wise ops (Add/Sub/Mul/Div/Relu/Relu6/Softmax) | `0xA000_0000` | 128-bit AXI4 → `S_AXI_HPC0_FPD` |
| `MatmulKernel_0` | Tiled matrix multiply | `0xA001_0000` | 128-bit AXI4 → `S_AXI_HPC0_FPD` |
| `ConvKernel_0` | 2-D convolution (NCHW) | `0xA002_0000` | 128-bit AXI4 → `S_AXI_HPC0_FPD` |
| `PoolingKernel_0` | Max/Avg/Lp/Global pooling | `0xA003_0000` | 128-bit AXI4 → `S_AXI_HPC0_FPD` |

All data masters aggregate through an AXI SmartConnect (`axi_smc_0`) into
`S_AXI_HPC0_FPD`. AXI-Lite control ports route through `axi_interconnect_0`.
Each kernel drives an interrupt line back to the PS.

Element type: **`ap_fixed<16,8>`** — 2 bytes per element, range ≈ [-128, 128),
encoding `1.0 = 0x0100`.

## Repository Structure

```
cormorant_hw_128.xpr                         Vivado project file
cormorant_tb_behav.wcfg                      Waveform config for simulator
build.sh                                     Shell wrapper: synthesis / impl / bitstream
scripts/build.tcl                            Tcl build script (stage + job-count selection)
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

## License

Copyright 2025 GradeBuilder SL. Licensed under the
[Apache License, Version 2.0](LICENSE).
