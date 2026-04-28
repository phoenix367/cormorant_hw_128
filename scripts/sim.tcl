# sim.tcl — Cormorant HW behavioral simulation script
#
# Usage (from project root):
#   vivado -mode batch -source scripts/sim.tcl
#   vivado -mode batch -source scripts/sim.tcl -tclargs -ip-repo /path/to/kernels
#
# Options:
#   -ip-repo DIR   override the IP repository path stored in the project file

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
set ip_repo ""

set i 0
while {$i < [llength $argv]} {
    set arg [lindex $argv $i]
    switch -exact -- $arg {
        -ip-repo { incr i; set ip_repo [file normalize [lindex $argv $i]] }
        default  { puts "WARNING: unknown argument '$arg' — ignored" }
    }
    incr i
}

puts "=== Cormorant HW behavioral simulation[expr {$ip_repo ne {} ? "  ip-repo=$ip_repo" : ""}] ==="

# ---------------------------------------------------------------------------
# Locate and open the project
# ---------------------------------------------------------------------------
set script_dir [file normalize [file dirname [info script]]]
set proj_root  [file normalize [file join $script_dir ..]]
set xpr        [file join $proj_root cormorant_hw_128.xpr]

if {![file exists $xpr]} {
    error "sim.tcl: project file not found: $xpr"
}

open_project $xpr

# ---------------------------------------------------------------------------
# Override IP repository if -ip-repo was supplied.
# ---------------------------------------------------------------------------
if {$ip_repo ne ""} {
    if {![file isdirectory $ip_repo]} {
        error "sim.tcl: -ip-repo directory not found: $ip_repo"
    }
    puts "=== Setting IP repository: $ip_repo ==="
    set_property ip_repo_paths [list $ip_repo] [current_project]
    update_ip_catalog -rebuild
    puts "=== IP catalog updated ==="
}

# ---------------------------------------------------------------------------
# Block-design preparation — generates HDL targets and BD wrapper.
# Required on a clean checkout where *.gen/ is absent.
# ---------------------------------------------------------------------------
proc prepare_bd {} {
    set locked [get_ips -quiet -filter {IS_LOCKED == 1}]
    if {[llength $locked] > 0} {
        set names {}
        foreach ip $locked { lappend names [get_property NAME $ip] }
        puts "=== Upgrading [llength $locked] locked IP(s): [join $names {, }] ==="
        upgrade_ip $locked
        puts "=== IP upgrade complete ==="
    } else {
        puts "=== No locked IPs ==="
    }

    set bd_files [get_files -of_objects [get_filesets sources_1] \
                      -filter {FILE_TYPE == "Block Designs"}]
    if {[llength $bd_files] == 0} {
        error "prepare_bd: no block design (.bd) found in sources_1"
    }
    set bd_file [lindex $bd_files 0]
    puts "=== Generating BD targets: [file tail $bd_file] ==="
    generate_target all $bd_file

    puts "=== Creating BD wrapper ==="
    set wrapper [make_wrapper -files $bd_file -top]
    if {[llength [get_files -quiet $wrapper]] == 0} {
        add_files -norecurse $wrapper
        puts "=== Wrapper added: [file tail $wrapper] ==="
    } else {
        puts "=== Wrapper already registered at current path ==="
    }

    set_property top design_cormorant_wrapper [current_fileset]
    update_compile_order -fileset sources_1
    puts "=== BD preparation complete ==="
}

prepare_bd

# ---------------------------------------------------------------------------
# Run behavioral simulation
# ---------------------------------------------------------------------------
puts "=== Launching behavioral simulation ==="
set t0 [clock seconds]

launch_simulation -simset [get_filesets sim_1] -mode behavioral
run all
close_sim

set elapsed [expr {[clock seconds] - $t0}]
puts "=== Simulation done in ${elapsed}s ==="

# ---------------------------------------------------------------------------
# Parse simulate.log for pass/fail
# ---------------------------------------------------------------------------
set sim_log [file join $proj_root \
                 cormorant_hw_128.sim sim_1 behav xsim simulate.log]

if {![file exists $sim_log]} {
    puts "WARNING: simulate.log not found at $sim_log — cannot verify result"
} else {
    set fp [open $sim_log r]
    set content [read $fp]
    close $fp

    if {[regexp {SIMULATION FAILED} $content]} {
        puts "=== SIMULATION FAILED — see [file normalize $sim_log] ==="
        exit 1
    } elseif {[regexp {ALL TESTS PASSED} $content]} {
        puts "=== ALL TESTS PASSED ==="
    } else {
        puts "WARNING: simulation result unclear — check $sim_log manually"
    }
}
