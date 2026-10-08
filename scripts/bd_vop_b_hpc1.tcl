# bd_vop_b_hpc1.tcl — VectorOPKernel's second read port (gmem1, operand b) on
# S_AXI_HPC1_FPD.  Idempotent; run on the project with the BD open or pass the .xpr:
#
#   vivado -mode batch -source scripts/bd_vop_b_hpc1.tcl -tclargs <xpr> [-ip-repo DIR]
#
# -ip-repo: the kernels' IP repository (the parent build's
# build_hw128/ip_repo_kv260, as sim.tcl / build.tcl take it); locked IPs are
# upgraded first, as their prepare_bd does — the BD cannot be validated with
# a locked kernel IP.
#
# The parent repo's doc/plans/PS_PORTS_PLAN.md §5.  A binary VectorOP reads a
# and b through HPC0 (axi_interconnect_0) at up to 3.8 GB/s together, near
# the port's 4 GB/s per direction at 250 MHz; with b on HPC1 each operand has
# a port.  axi_mem_intercon (→ the read-only HPC1) gains S03 for it, with a
# register slice like its other SIs; axi_interconnect_0 drops to eight SIs —
# PoolingKernel gmem1 moves from its last slot (S08) into the freed S01, so
# no other connection changes.  VectorOP gmem1's HPC0 address segments are
# deleted before assign_bd_address (they would collide with HPC1's; its
# HPC0_LPS_OCM stays, as with HPC1's other masters — the kernels address DDR
# only).

proc vb_attach {src pin} {
    set p [get_bd_pins $pin]
    if {[get_bd_nets -quiet -of_objects $p] ne ""} { return }
    set net [get_bd_nets -quiet -of_objects [get_bd_pins $src]]
    if {$net ne ""} { connect_bd_net -net $net $p } else { connect_bd_net [get_bd_pins $src] $p }
}

# connect master MAXI to SLAVE, dropping any other connection of either
proc vb_connect {maxi slave} {
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

proc apply_vop_b_hpc1 {} {
    set vb  VectorOPKernel_0/m_axi_gmem1
    set pl  PoolingKernel_0/m_axi_gmem1
    set ic0 [get_bd_cells axi_interconnect_0]
    set ic1 [get_bd_cells axi_mem_intercon]
    set net [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins $vb]]
    if {$net ne "" && [string match *axi_mem_intercon* [get_bd_intf_pins -of_objects $net]]} {
        puts "=== $vb already on axi_mem_intercon ==="
        return 0
    }

    # axi_mem_intercon: S03 for VectorOP b
    set_property CONFIG.NUM_SI 4 $ic1
    set_property CONFIG.S03_HAS_REGSLICE 1 $ic1
    vb_attach clk_wiz_0/clk_out1 axi_mem_intercon/S03_ACLK
    vb_attach rst_ps8_0_99M/peripheral_aresetn axi_mem_intercon/S03_ARESETN

    # VectorOP b's HPC0 segments go (assign_bd_address gives it HPC1's)
    set sp [get_bd_addr_spaces VectorOPKernel_0/Data_m_axi_gmem1]
    set stale [lsearch -all -inline -glob [get_bd_addr_segs -quiet -of_objects $sp] *HPC0_DDR*]
    lappend stale {*}[lsearch -all -inline -glob [get_bd_addr_segs -quiet -of_objects $sp] *HPC0_QSPI*]
    if {[llength $stale]} { delete_bd_objs $stale }

    vb_connect $vb axi_mem_intercon/S03_AXI
    # PoolingKernel y (S08) into the freed S01; axi_interconnect_0 to 8 SIs
    vb_connect $pl axi_interconnect_0/S01_AXI
    set_property CONFIG.NUM_SI 8 $ic0
    assign_bd_address
    puts "=== $vb moved to axi_mem_intercon/S03 (HPC1); $pl on axi_interconnect_0/S01 ==="
    return 1
}

proc vb_report {} {
    foreach sp {VectorOPKernel_0/Data_m_axi_gmem0 VectorOPKernel_0/Data_m_axi_gmem1 PoolingKernel_0/Data_m_axi_gmem1} {
        set segs [lsort [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces $sp]]]
        puts "=== $sp: [join [lmap s $segs {file tail $s}] { }] ==="
    }
    foreach ic {axi_interconnect_0 axi_mem_intercon} {
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
    set bd [get_files -of_objects [get_filesets sources_1] -filter {FILE_TYPE == "Block Designs"}]
    open_bd_design [lindex $bd 0]
    apply_vop_b_hpc1
    validate_bd_design
    vb_report
    save_bd_design
    close_project
}
