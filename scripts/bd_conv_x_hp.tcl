# bd_conv_x_hp.tcl — ConvKernel's x read port (gmem0) on an HP port, past the
# CCI.  Idempotent; run on the project with the BD open or pass the .xpr:
#
#   vivado -mode batch -source scripts/bd_conv_x_hp.tcl -tclargs <xpr> [-ip-repo DIR] [-port HP0|HP1|HP2|HP3]
#
# The parent repo's doc/plans/DEPTHWISE_PLAN.md §8.2: the ConvKernel's x
# path reads 144-byte runs, which the CCI path returns at ~0.4 beats per
# cycle whatever the issuing depth; this experiment moves that one master
# to S_AXI_HP<n>_FPD (default HP2: SAXIGP4, FPD switch → DDRC port 4)
# through its own one-slave interconnect, axi_x_intercon (a register slice
# on the SI, none on the MI: a one-way port), and shrinks axi_interconnect_0
# (HPC0) by that slot, re-seating its other masters in order.  Clocks and
# resets as the other interconnects; the moved master's HPC0 address
# segments are deleted before assign_bd_address.  -ip-repo and the locked-IP
# upgrade as bd_vop_b_hpc1.tcl.

set cx_master ConvKernel_0/m_axi_gmem0

proc cx_attach {src pin} {
    set p [get_bd_pins $pin]
    if {[get_bd_nets -quiet -of_objects $p] ne ""} { return }
    set net [get_bd_nets -quiet -of_objects [get_bd_pins $src]]
    if {$net ne ""} { connect_bd_net -net $net $p } else { connect_bd_net [get_bd_pins $src] $p }
}

proc cx_ic_clocks {ic nsi} {
    set pins [list ACLK M00_ACLK]
    set rsts [list ARESETN M00_ARESETN]
    for {set i 0} {$i < $nsi} {incr i} {
        lappend pins [format "S%02d_ACLK" $i]
        lappend rsts [format "S%02d_ARESETN" $i]
    }
    foreach p $pins { cx_attach clk_wiz_0/clk_out1 $ic/$p }
    foreach p $rsts { cx_attach rst_ps8_0_99M/peripheral_aresetn $ic/$p }
}

proc cx_connect {maxi slave} {
    set m [get_bd_intf_pins $maxi]
    set s [get_bd_intf_pins $slave]
    set net [get_bd_intf_nets -quiet -of_objects $m]
    if {$net ne "" && [lsearch -exact [get_bd_intf_pins -of_objects $net] $s] >= 0} { return 0 }
    if {$net ne ""} { delete_bd_objs $net }
    set snet [get_bd_intf_nets -quiet -of_objects $s]
    if {$snet ne ""} { delete_bd_objs $snet }
    connect_bd_intf_net $m $s
    return 1
}

proc cx_gp {port} { return [expr {[string index $port 2] + 2}] }

proc apply_conv_x_hp {{port HP2}} {
    global cx_master
    set ps [get_bd_cells zynq_ultra_ps_e_0]
    set gp [cx_gp $port]
    set lp [string tolower $port]
    set_property -dict [list CONFIG.PSU__USE__S_AXI_GP$gp {1} CONFIG.PSU__SAXIGP${gp}__DATA_WIDTH {128}] $ps
    cx_attach clk_wiz_0/clk_out1 zynq_ultra_ps_e_0/saxi${lp}_fpd_aclk

    set out [get_bd_cells -quiet axi_x_intercon]
    if {$out eq ""} {
        set out [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_x_intercon]
        puts "=== axi_x_intercon created ==="
    }
    set_property -dict [list CONFIG.NUM_SI 1 CONFIG.NUM_MI 1 CONFIG.XBAR_DATA_WIDTH 128 \
                            CONFIG.S00_HAS_REGSLICE 1 CONFIG.M00_HAS_REGSLICE 0] $out
    cx_connect axi_x_intercon/M00_AXI zynq_ultra_ps_e_0/S_AXI_${port}_FPD
    cx_ic_clocks axi_x_intercon 1

    # the master's HPC0 segments go (assign_bd_address gives it the port's)
    set sp [get_bd_addr_spaces -quiet [string map {/m_axi_ /Data_m_axi_} $cx_master]]
    set stale [lsearch -all -inline -not -glob [get_bd_addr_segs -quiet -of_objects $sp] *${port}_*]
    if {[llength $stale]} { delete_bd_objs $stale }

    # axi_interconnect_0: the other masters in their order, one slot fewer
    set ic [get_bd_cells axi_interconnect_0]
    set nsi [get_property CONFIG.NUM_SI $ic]
    set keep {}
    set moved 0
    for {set i 0} {$i < $nsi} {incr i} {
        set p [get_bd_intf_pins [format "axi_interconnect_0/S%02d_AXI" $i]]
        set n [get_bd_intf_nets -quiet -of_objects $p]
        if {$n eq ""} { continue }
        foreach q [get_bd_intf_pins -of_objects $n] {
            if {$q eq $p} { continue }
            set name [string trimleft $q /]
            if {$name eq $cx_master} { set moved 1 } else { lappend keep $name }
        }
    }
    if {$moved} {
        foreach m [concat $keep [list $cx_master]] {
            set net [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins $m]]
            if {$net ne ""} { delete_bd_objs $net }
        }
        set_property CONFIG.NUM_SI [llength $keep] $ic
        set i 0
        foreach m $keep {
            cx_connect $m [format "axi_interconnect_0/S%02d_AXI" $i]
            incr i
        }
        cx_ic_clocks axi_interconnect_0 [llength $keep]
        puts "=== $cx_master left axi_interconnect_0; [llength $keep] SIs re-seated ==="
    }
    cx_connect $cx_master axi_x_intercon/S00_AXI
    assign_bd_address
}

proc cx_report {} {
    foreach sp [get_bd_addr_spaces -quiet ConvKernel_0/*] {
        set segs [lsort [get_bd_addr_segs -quiet -of_objects $sp]]
        puts "=== [get_property NAME $sp]: [join [lmap s $segs {file tail $s}] { }] ==="
    }
    foreach ic {axi_interconnect_0 axi_mem_intercon axi_x_intercon} {
        set cell [get_bd_cells $ic]
        set sis {}
        for {set i 0} {$i < [get_property CONFIG.NUM_SI $cell]} {incr i} {
            set p [get_bd_intf_pins [format "%s/S%02d_AXI" $ic $i]]
            set n [get_bd_intf_nets -quiet -of_objects $p]
            set peer [lmap q [get_bd_intf_pins -quiet -of_objects $n] {
                if {$q eq $p} continue
                string trimleft $q /
            }]
            lappend sis [format "S%02d=%s" $i [join $peer]]
        }
        puts "=== $ic: [join $sis {, }]; M00 regslice [get_property CONFIG.M00_HAS_REGSLICE $cell] ==="
    }
}

if {[info exists argv] && [llength $argv] >= 1 && [string match *.xpr [lindex $argv 0]]} {
    open_project [lindex $argv 0]
    set ri [lsearch -exact $argv -ip-repo]
    if {$ri >= 0} {
        set_property ip_repo_paths [list [file normalize [lindex $argv [expr {$ri + 1}]]]] [current_project]
        update_ip_catalog -rebuild
    }
    set locked [get_ips -quiet -filter {IS_LOCKED == 1}]
    if {[llength $locked]} { upgrade_ip $locked }
    set port HP2
    set pi [lsearch -exact $argv -port]
    if {$pi >= 0} { set port [string toupper [lindex $argv [expr {$pi + 1}]]] }
    if {![regexp {^HP[0-3]$} $port]} { error "-port takes HP0..HP3, not '$port'" }
    set bd [get_files -of_objects [get_filesets sources_1] -filter {FILE_TYPE == "Block Designs"}]
    open_bd_design [lindex $bd 0]
    apply_conv_x_hp $port
    validate_bd_design
    cx_report
    save_bd_design
    close_project
}
