# build.tcl — Cormorant HW batch build script
#
# Usage (from project root):
#   vivado -mode batch -source scripts/build.tcl
#   vivado -mode batch -source scripts/build.tcl -tclargs synth
#   vivado -mode batch -source scripts/build.tcl -tclargs impl
#   vivado -mode batch -source scripts/build.tcl -tclargs all -jobs 12
#
# Stages:
#   synth  — synthesis only
#   impl   — implementation + bitstream (requires completed synthesis)
#   all    — synthesis + implementation + bitstream  (default)
#
# Options:
#   -jobs N   parallel jobs (default: 8)

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
set stage "all"
set jobs  8

set i 0
while {$i < [llength $argv]} {
    set arg [lindex $argv $i]
    switch -exact -- $arg {
        synth   { set stage synth }
        impl    { set stage impl  }
        all     { set stage all   }
        -jobs   { incr i; set jobs [lindex $argv $i] }
        default {
            puts "WARNING: unknown argument '$arg' — ignored"
        }
    }
    incr i
}

puts "=== Cormorant HW build  stage=$stage  jobs=$jobs ==="

# ---------------------------------------------------------------------------
# Locate and open the project
# ---------------------------------------------------------------------------
set script_dir [file normalize [file dirname [info script]]]
set proj_root  [file normalize [file join $script_dir ..]]
set xpr        [file join $proj_root cormorant_hw_128.xpr]

if {![file exists $xpr]} {
    error "build.tcl: project file not found: $xpr"
}

open_project $xpr

# ---------------------------------------------------------------------------
# Block-design preparation: generate HDL targets and create the top wrapper.
# Must run before synthesis on a clean checkout where *.gen/ is absent.
# ---------------------------------------------------------------------------
proc prepare_bd {} {
    # Upgrade locked IPs first — a locked BD cannot generate targets or a wrapper.
    # IPs become locked when the catalog version differs from the stored XCI
    # (common on a clean checkout if the IP was built with a different revision).
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

    # Create the wrapper only if it is not already tracked in the fileset.
    set existing [get_files -quiet -of_objects [get_filesets sources_1] \
                      -filter {FILE_TYPE == "Verilog" && NAME =~ "*wrapper*"}]
    if {[llength $existing] == 0} {
        puts "=== Creating BD wrapper ==="
        set wrapper [make_wrapper -files $bd_file -top]
        add_files -norecurse $wrapper
    } else {
        puts "=== BD wrapper already present — skipping make_wrapper ==="
    }

    set_property top design_cormorant_wrapper [current_fileset]
    update_compile_order -fileset sources_1
    puts "=== BD preparation complete ==="
}

# ---------------------------------------------------------------------------
# Synthesis
# ---------------------------------------------------------------------------
proc run_synth {jobs} {
    set run synth_1
    set state [get_property STATUS [get_runs $run]]
    puts "=== Synthesis: current status = $state ==="

    if {[get_property NEEDS_REFRESH [get_runs $run]] ||
        $state eq "Not started"} {
        reset_run $run
    }

    if {[get_property PROGRESS [get_runs $run]] ne "100%"} {
        puts "=== Launching synthesis ($jobs jobs) ==="
        set t0 [clock seconds]
        launch_runs $run -jobs $jobs
        wait_on_run $run
        set elapsed [expr {[clock seconds] - $t0}]
        puts "=== Synthesis done in ${elapsed}s ==="
    } else {
        puts "=== Synthesis already complete — skipping ==="
    }

    set status [get_property STATUS [get_runs $run]]
    if {[string match {*ERROR*} $status] || [string match {*Failed*} $status]} {
        error "Synthesis FAILED: $status"
    }
}

# ---------------------------------------------------------------------------
# Implementation + bitstream
# ---------------------------------------------------------------------------
proc run_impl {jobs} {
    set run impl_1
    set state [get_property STATUS [get_runs $run]]
    puts "=== Implementation: current status = $state ==="

    if {[get_property NEEDS_REFRESH [get_runs $run]] ||
        $state eq "Not started"} {
        reset_run $run
    }

    if {[get_property PROGRESS [get_runs $run]] ne "100%"} {
        puts "=== Launching implementation + bitstream ($jobs jobs) ==="
        set t0 [clock seconds]
        launch_runs $run -to_step write_bitstream -jobs $jobs
        wait_on_run $run
        set elapsed [expr {[clock seconds] - $t0}]
        puts "=== Implementation done in ${elapsed}s ==="
    } else {
        puts "=== Implementation already complete — skipping ==="
    }

    set status [get_property STATUS [get_runs $run]]
    if {[string match {*ERROR*} $status] || [string match {*Failed*} $status]} {
        error "Implementation FAILED: $status"
    }

    # Print timing summary
    open_run $run
    set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
    set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
    puts "=== Timing summary: WNS=${wns}ns  WHS=${whs}ns ==="
    if {$wns < 0} {
        puts "WARNING: setup timing not met (WNS=$wns)"
    }

    set bit [file join [get_property DIRECTORY [get_runs $run]] \
                       design_cormorant_wrapper.bit]
    if {[file exists $bit]} {
        puts "=== Bitstream: $bit ==="
    } else {
        puts "WARNING: bitstream file not found at expected path"
    }
}

# ---------------------------------------------------------------------------
# Execute requested stages
# ---------------------------------------------------------------------------
set t_total [clock seconds]

# BD preparation is always needed before synthesis on a clean tree.
if {$stage eq "synth" || $stage eq "all"} {
    prepare_bd
    run_synth $jobs
}
if {$stage eq "impl" || $stage eq "all"} {
    run_impl $jobs
}

set total_elapsed [expr {[clock seconds] - $t_total}]
puts "=== Build complete in ${total_elapsed}s ==="
