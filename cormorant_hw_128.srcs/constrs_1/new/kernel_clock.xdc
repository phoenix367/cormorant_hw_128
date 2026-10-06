# kernel_clock.xdc — timing constraints for the 250 MHz kernel clock
# (clk_wiz_0, the parent repo's doc/plans/FMAX_250_PLAN.md).
#
# The register slice on axi_interconnect_0's master side (S_AXI_HPC0_FPD) is
# "Full" on W: its s_ready register selects each of the ~150 payload bits'
# next value, one LUT each, and placed across the slice it was the design's
# worst path (+0.017 ns at 4 ns).  Replicate it in synthesis.
set_property MAX_FANOUT 32 [get_cells -quiet -hierarchical -filter {NAME =~ "*axi_interconnect_0/m00_couplers/m00_regslice/inst/*.?_pipe/s_ready_i_reg"}]
