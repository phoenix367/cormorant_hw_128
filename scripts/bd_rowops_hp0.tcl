# bd_rowops_hp0.tcl — the RowOpsKernel (the parent repo's row-ops unit,
# doc/plans/HOSTOPS_PLAN.md phase 3; kernels/rowops_rtl) on S_AXI_HP0_FPD.
# Idempotent; run on the project with the BD open or pass the .xpr:
#
#   vivado -mode batch -source scripts/bd_rowops_hp0.tcl -tclargs <xpr> [-ip-repo DIR]
#
# Adds, when missing:
#   RowOpsKernel_0        xilinx.com:hls:RowOpsKernel:1.0 (one read + write 128-bit
#                         m_axi_gmem0, s_axi_ctrl, interrupt), clocked and reset
#                         like the four kernels (clk_wiz_0/clk_out1,
#                         rst_ps8_0_99M/peripheral_aresetn)
#   axi_smc M04           its AXI-Lite control port at 0xA004_0000 (64 KiB)
#   ilconcat_0 In4        its interrupt, pl_ps_irq0[4]
#   axi_rowops_intercon   one SI, one MI, 128-bit, register slices on both (the
#                         port reads and writes, as HPC0's crossbar does), into
#                         S_AXI_HP0_FPD (SAXIGP2, 128-bit; FPD switch → DDRC
#                         port 3, past the CCI), clocked from the MMCM
#
# The other kernels and interconnects are untouched.  -ip-repo and the locked-IP
# upgrade as bd_conv_x_hp.tcl (the kernel's IP must be in the repository:
# the parent build's ip_repo_kv260 links rtl_ip/RowOpsKernel_ip).

set ro_cell   RowOpsKernel_0
set ro_vlnv   xilinx.com:hls:RowOpsKernel:1.0
set ro_ic     axi_rowops_intercon
set ro_port   HP0
set ro_ctrl   0xA0040000

proc ro_attach {src pin} {
    set p [get_bd_pins $pin]
    if {[get_bd_nets -quiet -of_objects $p] ne ""} { return }
    set net [get_bd_nets -quiet -of_objects [get_bd_pins $src]]
    if {$net ne ""} { connect_bd_net -net $net $p } else { connect_bd_net [get_bd_pins $src] $p }
}

proc ro_ic_clocks {ic nsi} {
    set pins [list ACLK M00_ACLK]
    set rsts [list ARESETN M00_ARESETN]
    for {set i 0} {$i < $nsi} {incr i} {
        lappend pins [format "S%02d_ACLK" $i]
        lappend rsts [format "S%02d_ARESETN" $i]
    }
    foreach p $pins { ro_attach clk_wiz_0/clk_out1 $ic/$p }
    foreach p $rsts { ro_attach rst_ps8_0_99M/peripheral_aresetn $ic/$p }
}

proc ro_connect {maxi slave} {
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

proc ro_gp {port} { return [expr {[string index $port 2] + 2}] }

proc apply_rowops_hp0 {} {
    global ro_cell ro_vlnv ro_ic ro_port ro_ctrl
    set ps [get_bd_cells zynq_ultra_ps_e_0]

    # the kernel
    set k [get_bd_cells -quiet $ro_cell]
    if {$k eq ""} {
        set k [create_bd_cell -type ip -vlnv $ro_vlnv $ro_cell]
        puts "=== $ro_cell created ==="
    }
    ro_attach clk_wiz_0/clk_out1 $ro_cell/ap_clk
    ro_attach rst_ps8_0_99M/peripheral_aresetn $ro_cell/ap_rst_n

    # its control port: one more SmartConnect master
    set smc [get_bd_cells axi_smc]
    set ctrl [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins $ro_cell/s_axi_ctrl]]
    if {$ctrl eq ""} {
        set nmi [get_property CONFIG.NUM_MI $smc]
        set_property CONFIG.NUM_MI [expr {$nmi + 1}] $smc
        ro_connect [format "axi_smc/M%02d_AXI" $nmi] $ro_cell/s_axi_ctrl
        puts "=== $ro_cell/s_axi_ctrl on axi_smc M[format %02d $nmi] ==="
    }

    # its interrupt: one more concat input
    set cc [get_bd_cells ilconcat_0]
    set irq [get_bd_nets -quiet -of_objects [get_bd_pins $ro_cell/interrupt]]
    if {$irq eq ""} {
        set np [get_property CONFIG.NUM_PORTS $cc]
        set_property CONFIG.NUM_PORTS [expr {$np + 1}] $cc
        connect_bd_net [get_bd_pins $ro_cell/interrupt] [get_bd_pins ilconcat_0/In$np]
        puts "=== $ro_cell/interrupt on ilconcat_0 In$np (pl_ps_irq0\[$np\]) ==="
    }

    # the PS port
    set gp [ro_gp $ro_port]
    set lp [string tolower $ro_port]
    set_property -dict [list CONFIG.PSU__USE__S_AXI_GP$gp {1} CONFIG.PSU__SAXIGP${gp}__DATA_WIDTH {128}] $ps
    ro_attach clk_wiz_0/clk_out1 zynq_ultra_ps_e_0/saxi${lp}_fpd_aclk

    # the interconnect: a slice on the SI and on the MI (read + write, as HPC0's)
    set ic [get_bd_cells -quiet $ro_ic]
    if {$ic eq ""} {
        set ic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 $ro_ic]
        puts "=== $ro_ic created ==="
    }
    set_property -dict [list CONFIG.NUM_SI 1 CONFIG.NUM_MI 1 CONFIG.XBAR_DATA_WIDTH 128 \
                            CONFIG.S00_HAS_REGSLICE 1 CONFIG.M00_HAS_REGSLICE 1] $ic
    ro_connect $ro_ic/M00_AXI zynq_ultra_ps_e_0/S_AXI_${ro_port}_FPD
    ro_ic_clocks $ro_ic 1
    ro_connect $ro_cell/m_axi_gmem0 $ro_ic/S00_AXI

    # addresses: the data port gets HP0's segments, the control block 0xA004_0000
    set sp [get_bd_addr_spaces -quiet $ro_cell/Data_m_axi_gmem0]
    set stale [lsearch -all -inline -not -glob [get_bd_addr_segs -quiet -of_objects $sp] *${ro_port}_*]
    if {[llength $stale]} { delete_bd_objs $stale }
    assign_bd_address
    set seg [get_bd_addr_segs -quiet zynq_ultra_ps_e_0/Data/SEG_${ro_cell}_Reg]
    if {$seg eq ""} { error "no control segment for $ro_cell after assign_bd_address" }
    if {[get_property OFFSET $seg] != $ro_ctrl} {
        set_property offset $ro_ctrl $seg
        set_property range 64K $seg
        puts "=== $ro_cell control block moved to $ro_ctrl ==="
    }
}

proc ro_report {} {
    global ro_cell ro_ic
    foreach sp [get_bd_addr_spaces -quiet $ro_cell/*] {
        set segs [lsort [get_bd_addr_segs -quiet -of_objects $sp]]
        puts "=== [get_property NAME $sp]: [join [lmap s $segs {file tail $s}] { }] ==="
    }
    set seg [get_bd_addr_segs -quiet zynq_ultra_ps_e_0/Data/SEG_${ro_cell}_Reg]
    puts "=== $ro_cell s_axi_ctrl at [get_property OFFSET $seg] range [get_property RANGE $seg] ==="
    set cell [get_bd_cells $ro_ic]
    puts "=== $ro_ic: NUM_SI [get_property CONFIG.NUM_SI $cell], S00 regslice [get_property CONFIG.S00_HAS_REGSLICE $cell], M00 regslice [get_property CONFIG.M00_HAS_REGSLICE $cell] ==="
    puts "=== axi_smc NUM_MI [get_property CONFIG.NUM_MI [get_bd_cells axi_smc]], ilconcat_0 NUM_PORTS [get_property CONFIG.NUM_PORTS [get_bd_cells ilconcat_0]] ==="
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
    set bd [get_files -of_objects [get_filesets sources_1] -filter {FILE_TYPE == "Block Designs"}]
    open_bd_design [lindex $bd 0]
    apply_rowops_hp0
    validate_bd_design
    ro_report
    save_bd_design
    # the testbench's RowOps files, if the project does not list them yet
    set simdir [file normalize [file join [file dirname [lindex $argv 0]] cormorant_hw_128.srcs sim_1 new]]
    foreach f {ro_regmap.svh ro_classes.svh} {
        set p [file join $simdir $f]
        if {[file exists $p] && [llength [get_files -quiet -of_objects [get_filesets sim_1] $p]] == 0} {
            add_files -fileset sim_1 -norecurse $p
            puts "=== sim_1: $f added ==="
        }
    }
    close_project
}
