# bd_kernel_clock.tcl — the PL design's clock from an MMCM, register slices
# in the data interconnects.  Idempotent; run on the project with the BD open
# or pass the .bd file:
#
#   vivado -mode batch -source scripts/bd_kernel_clock.tcl -tclargs <xpr> [mhz]
#
# The kernels, the interconnects, the SmartConnect, the PS-PL AXI port clocks
# (maxihpm0_fpd_aclk, saxihpc0/1_fpd_aclk) and the reset block all move from
# pl_clk0 to clk_wiz_0/clk_out1 (default 250 MHz).  pl_clk0 stays at the
# boot firmware's 100 MHz and only feeds the MMCM, so the bitstream defines
# its own clock: a bitstream built for 100 MHz can never run at 250 because
# of a stale PL0 setting, and the bitstream id implies the clock.  The MMCM's
# locked output holds rst_ps8_0_99M (dcm_locked) until the clock is stable;
# pl_resetn0 resets the MMCM.
#
# Register slices ("Outer", value 1) on every SI of the two data
# interconnects and the MI of axi_interconnect_0 (→ S_AXI_HPC0_FPD;
# axi_mem_intercon → the read-only S_AXI_HPC1_FPD keeps none on its MI): the PS port and kernel-side paths through the crossbars
# are 4.5–5.8 ns at 10 ns otherwise (doc/plans/FMAX_250_PLAN.md).

proc apply_kernel_clock {mhz} {
    set ps  [get_bd_cells zynq_ultra_ps_e_0]
    set rst [get_bd_cells rst_ps8_0_99M]
    set pl_clk  [get_bd_pins zynq_ultra_ps_e_0/pl_clk0]
    set pl_rstn [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0]

    set wiz [get_bd_cells -quiet clk_wiz_0]
    if {$wiz eq ""} {
        set wiz [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0]
        puts "=== clk_wiz_0 created ==="
    }
    # pl_clk0 already passes a BUFG_PS (PSU__PL_CLK0_BUF TRUE): no input
    # buffer.  The input frequency propagates from pl_clk0 (99.999 MHz).
    set clk_in [get_bd_pins clk_wiz_0/clk_in1]
    if {[get_bd_nets -quiet -of_objects $clk_in] eq ""} {
        set net0 [get_bd_nets -quiet -of_objects $pl_clk]
        if {$net0 ne ""} { connect_bd_net -net $net0 $clk_in } else { connect_bd_net $pl_clk $clk_in }
    }
    set_property -dict [list \
        CONFIG.PRIM_SOURCE {No_buffer} \
        CONFIG.CLKOUT1_REQUESTED_OUT_FREQ $mhz \
        CONFIG.USE_LOCKED {true} \
        CONFIG.USE_RESET {true} \
        CONFIG.RESET_TYPE {ACTIVE_LOW} \
        CONFIG.RESET_PORT {resetn} \
    ] $wiz

    set clk_out [get_bd_pins clk_wiz_0/clk_out1]

    # move every sink of pl_clk0 except the MMCM's input to clk_out1
    set net [get_bd_nets -quiet -of_objects $pl_clk]
    set moved 0
    if {$net ne ""} {
        foreach pin [get_bd_pins -quiet -of_objects $net] {
            if {$pin eq $pl_clk || $pin eq $clk_in} { continue }
            disconnect_bd_net $net $pin
            connect_bd_net $clk_out $pin
            incr moved
        }
    }
    puts "=== kernel clock: $moved sink(s) moved from pl_clk0 to clk_wiz_0/clk_out1 ==="

    # reset: pl_resetn0 resets the MMCM, its locked output gates the reset block
    set rstn_pin [get_bd_pins clk_wiz_0/resetn]
    if {[get_bd_nets -quiet -of_objects $rstn_pin] eq ""} {
        connect_bd_net $pl_rstn $rstn_pin
    }
    set dcm [get_bd_pins rst_ps8_0_99M/dcm_locked]
    set dnet [get_bd_nets -quiet -of_objects $dcm]
    if {$dnet ne ""} { disconnect_bd_net $dnet $dcm }
    connect_bd_net [get_bd_pins clk_wiz_0/locked] $dcm
}

proc apply_interconnect_regslices {} {
    set n 0
    # axi_mem_intercon's master side is read-only (S_AXI_HPC1_FPD): a slice
    # there disagrees with the crossbar's READ_WRITE_MODE; its SIs have the
    # axi_mmu AR slices on the kernel side anyway, so only the SIs get one
    foreach {ic mi} {axi_interconnect_0 1 axi_mem_intercon 0} {
        set cell [get_bd_cells $ic]
        set nsi [get_property CONFIG.NUM_SI $cell]
        set props [list CONFIG.M00_HAS_REGSLICE $mi]
        for {set i 0} {$i < $nsi} {incr i} {
            lappend props [format "CONFIG.S%02d_HAS_REGSLICE" $i] 1
        }
        set_property -dict $props $cell
        incr n [expr {$nsi + 1}]
        puts "=== $ic: register slices on S00..S[format %02d [expr {$nsi - 1}]][expr {$mi ? { and M00} : {}}] ==="
    }
    return $n
}

# The constraints of the kernel clock (constrs_1/new/kernel_clock.xdc): added
# to the project's constrs_1 once.
proc add_kernel_clock_xdc {} {
    set xdc [file normalize [file join [get_property DIRECTORY [current_project]] \
                 cormorant_hw_128.srcs constrs_1 new kernel_clock.xdc]]
    if {![file exists $xdc]} {
        error "add_kernel_clock_xdc: $xdc missing"
    }
    if {[llength [get_files -quiet -of_objects [get_filesets constrs_1] $xdc]] == 0} {
        add_files -fileset constrs_1 -norecurse $xdc
        puts "=== constrs_1: [file tail $xdc] added ==="
    }
}

if {[info exists argv] && [llength $argv] >= 1 && [string match *.xpr [lindex $argv 0]]} {
    set mhz [expr {[llength $argv] >= 2 ? [lindex $argv 1] : 250}]
    open_project [lindex $argv 0]
    set bd [get_files -of_objects [get_filesets sources_1] -filter {FILE_TYPE == "Block Designs"}]
    open_bd_design [lindex $bd 0]
    apply_kernel_clock $mhz
    apply_interconnect_regslices
    add_kernel_clock_xdc
    validate_bd_design
    foreach c {VectorOPKernel_0 MatmulKernel_0 ConvKernel_0 PoolingKernel_0} {
        puts "=== $c ap_clk FREQ_HZ = [get_property CONFIG.FREQ_HZ [get_bd_pins $c/ap_clk]] ==="
    }
    puts "=== clk_wiz_0 clk_out1 actual: [get_property CONFIG.CLKOUT1_JITTER [get_bd_cells clk_wiz_0]] ps jitter, [get_property CONFIG.FREQ_HZ [get_bd_pins clk_wiz_0/clk_out1]] Hz ==="
    save_bd_design
    close_project
}
