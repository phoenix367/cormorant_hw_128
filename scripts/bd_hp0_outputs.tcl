# bd_hp0_outputs.tcl — the kernels' outputs on S_AXI_HP0_FPD.  Idempotent;
# run on the project with the BD open or pass the .xpr:
#
#   vivado -mode batch -source scripts/bd_hp0_outputs.tcl -tclargs <xpr> [-ip-repo DIR] [-port HP0|HP1|HP2|HP3]
#
# -ip-repo: the kernels' IP repository (the parent build's
# build_hw128/ip_repo_kv260, as sim.tcl / build.tcl take it); locked kernel
# IPs are upgraded first — the BD cannot be validated with one locked.
# -port: the PS high-performance port the outputs go to (default HP0;
# PS_PORTS_PLAN §7 moves them to HP2 — FPD switch → DDRC port 4, HP0's is
# port 3 shared with DisplayPort).  Switching ports on a design that already
# has axi_out_intercon re-targets its M00, enables the new port (128-bit),
# clocks it, disables the old one and swaps the writers' address segments.
#
# The parent repo's doc/plans/PS_PORTS_PLAN.md §1–§4 (experiment 1 on the
# 588d721997cb design: bit-exact, performance-neutral, bitstream 4a820240ba9c)
# and §6 (the same move on top of experiment 2's design, VectorOP b on HPC1).
# Every kernel port is read-only or write-only; the four write masters (the
# outputs: VectorOPKernel gmem2 c, MatmulKernel gmem2 C, ConvKernel gmem3 y,
# PoolingKernel gmem1 y) go through axi_out_intercon to S_AXI_HP0_FPD
# (SAXIGP2, 128-bit; FPD switch → DDRC port 3, past the CCI), and
# axi_interconnect_0 keeps the four readers on HPC0 (VectorOP a, Matmul A,
# Conv x, Pool x; axi_mem_intercon → HPC1 with Conv w / b, Matmul B and
# VectorOP b is unchanged).  Clocks and resets as the other two interconnects
# (clk_wiz_0/clk_out1, rst_ps8_0_99M/peripheral_aresetn), register slices on
# every SI, none on the MIs (all three ports are one-way now; the
# kernel_clock.xdc MAX_FANOUT on axi_interconnect_0's MI slice goes with it).
# The moved masters' HPC0 address segments are deleted before
# assign_bd_address (they would collide with the HP0 ones).  LPS_OCM: every
# port maps it at 0xFF00_0000, and a master that once had HPC0's keeps it
# (BD 41-1359 for the HP0 / HPC1 one) — the kernels address DDR only.

set hp0_writers {VectorOPKernel_0/m_axi_gmem2 MatmulKernel_0/m_axi_gmem2 \
                 ConvKernel_0/m_axi_gmem3 PoolingKernel_0/m_axi_gmem1}
set hpc0_readers {VectorOPKernel_0/m_axi_gmem0 MatmulKernel_0/m_axi_gmem0 \
                  ConvKernel_0/m_axi_gmem0 PoolingKernel_0/m_axi_gmem0}

# connect PIN to the net that SRC drives (unless it is connected already)
proc hp0_attach {src pin} {
    set p [get_bd_pins $pin]
    if {[get_bd_nets -quiet -of_objects $p] ne ""} { return }
    set net [get_bd_nets -quiet -of_objects [get_bd_pins $src]]
    if {$net ne ""} { connect_bd_net -net $net $p } else { connect_bd_net [get_bd_pins $src] $p }
}

# clock and reset pins of an axi_interconnect with NSI slave interfaces
proc hp0_ic_clocks {ic nsi} {
    set pins [list ACLK M00_ACLK]
    set rsts [list ARESETN M00_ARESETN]
    for {set i 0} {$i < $nsi} {incr i} {
        lappend pins [format "S%02d_ACLK" $i]
        lappend rsts [format "S%02d_ARESETN" $i]
    }
    foreach p $pins { hp0_attach clk_wiz_0/clk_out1 $ic/$p }
    foreach p $rsts { hp0_attach rst_ps8_0_99M/peripheral_aresetn $ic/$p }
}

# connect master MAXI to SLAVE, dropping any other connection of either
proc hp0_connect {maxi slave} {
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

# HPn is the PS's S_AXI_GP(n+2) (SAXIGP2..5)
proc hp0_gp {port} { return [expr {[string index $port 2] + 2}] }

proc apply_hp0_outputs {{port HP0}} {
    global hp0_writers hpc0_readers
    set ps  [get_bd_cells zynq_ultra_ps_e_0]
    set gp  [hp0_gp $port]
    set lp  [string tolower $port]
    set_property -dict [list CONFIG.PSU__USE__S_AXI_GP$gp {1} CONFIG.PSU__SAXIGP${gp}__DATA_WIDTH {128}] $ps
    hp0_attach clk_wiz_0/clk_out1 zynq_ultra_ps_e_0/saxi${lp}_fpd_aclk

    set out [get_bd_cells -quiet axi_out_intercon]
    if {$out eq ""} {
        set out [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_out_intercon]
        puts "=== axi_out_intercon created ==="
    }
    set nw [llength $hp0_writers]
    set_property -dict [list CONFIG.NUM_SI $nw CONFIG.NUM_MI 1 CONFIG.XBAR_DATA_WIDTH 128] $out
    # the port the outputs used before (another HPn): disconnect and disable it
    set old [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins axi_out_intercon/M00_AXI]]
    foreach p [get_bd_intf_pins -quiet -of_objects $old] {
        if {[regexp {zynq_ultra_ps_e_0/S_AXI_(HP[0-3])_FPD$} $p -> oldport] && $oldport ne $port} {
            delete_bd_objs $old
            set oclk [get_bd_pins zynq_ultra_ps_e_0/saxi[string tolower $oldport]_fpd_aclk]
            set onet [get_bd_nets -quiet -of_objects $oclk]
            if {$onet ne ""} { disconnect_bd_net $onet $oclk }
            set_property CONFIG.PSU__USE__S_AXI_GP[hp0_gp $oldport] {0} $ps
            puts "=== $oldport released ==="
        }
    }
    hp0_connect axi_out_intercon/M00_AXI zynq_ultra_ps_e_0/S_AXI_${port}_FPD
    hp0_ic_clocks axi_out_intercon $nw

    # the writers' other address segments go (assign_bd_address gives them $port's)
    set moved 0
    foreach w $hp0_writers {
        set sp [get_bd_addr_spaces -quiet [string map {/m_axi_ /Data_m_axi_} $w]]
        set segs [get_bd_addr_segs -quiet -of_objects $sp]
        set stale [lsearch -all -inline -not -glob $segs *${port}_*]
        if {[llength $stale]} { delete_bd_objs $stale }
    }

    # axi_interconnect_0: drop every master, shrink to the readers, reconnect
    set ic [get_bd_cells axi_interconnect_0]
    set nr [llength $hpc0_readers]
    foreach m [concat $hpc0_readers $hp0_writers] {
        set net [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins $m]]
        if {$net ne "" && [string match *axi_interconnect_0* [get_bd_intf_pins -of_objects $net]]} {
            delete_bd_objs $net
        }
    }
    set_property CONFIG.NUM_SI $nr $ic
    set i 0
    foreach r $hpc0_readers {
        hp0_connect $r [format "axi_interconnect_0/S%02d_AXI" $i]
        incr i
    }
    hp0_ic_clocks axi_interconnect_0 $nr
    set i 0
    foreach w $hp0_writers {
        incr moved [hp0_connect $w [format "axi_out_intercon/S%02d_AXI" $i]]
        incr i
    }
    puts "=== HP0: $moved writer(s) moved to axi_out_intercon; axi_interconnect_0 has $nr SIs ==="

    # register slices on every SI (as the other two interconnects); none on
    # the MIs: a one-way crossbar (READ_ONLY / WRITE_ONLY) disagrees with a
    # slice's READ_WRITE mode (BD 41-237), and axi_interconnect_0 is read-only now
    set props {}
    for {set i 0} {$i < $nw} {incr i} { lappend props [format "CONFIG.S%02d_HAS_REGSLICE" $i] 1 }
    set_property -dict $props $out
    set_property CONFIG.M00_HAS_REGSLICE 0 $out
    set_property CONFIG.M00_HAS_REGSLICE 0 $ic

    assign_bd_address
}

proc hp0_report {} {
    foreach c {VectorOPKernel_0 MatmulKernel_0 ConvKernel_0 PoolingKernel_0} {
        foreach sp [get_bd_addr_spaces -quiet $c/*] {
            set segs [lsort [get_bd_addr_segs -quiet -of_objects $sp]]
            puts "=== [get_property NAME $sp]: [join [lmap s $segs {file tail $s}] { }] ==="
        }
    }
    foreach ic {axi_interconnect_0 axi_out_intercon axi_mem_intercon} {
        set cell [get_bd_cells $ic]
        puts "=== $ic: NUM_SI [get_property CONFIG.NUM_SI $cell], M00 regslice [get_property CONFIG.M00_HAS_REGSLICE $cell] ==="
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
    set port HP0
    set pi [lsearch -exact $argv -port]
    if {$pi >= 0} { set port [string toupper [lindex $argv [expr {$pi + 1}]]] }
    if {![regexp {^HP[0-3]$} $port]} { error "-port takes HP0..HP3, not '$port'" }
    set bd [get_files -of_objects [get_filesets sources_1] -filter {FILE_TYPE == "Block Designs"}]
    open_bd_design [lindex $bd 0]
    apply_hp0_outputs $port
    validate_bd_design
    hp0_report
    save_bd_design
    close_project
}
