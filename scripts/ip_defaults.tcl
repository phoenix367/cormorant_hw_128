# ip_defaults.tcl — kernel instances' m_axi data widths = their IP's defaults.
#
# Sourced by build.tcl and sim.tcl, called after the IP upgrade.  The
# instance widths of a kernel's m_axi ports must equal the IP's own defaults
# (CLAUDE.md "Block Design"), and two IPs share the MatmulKernel VLNV: the
# Vitis HLS export has a 32-bit gmem2, the RTL kernel (kernels/matmul_rtl) a
# 128-bit one.  An upgrade from one to the other keeps the instance's old
# value, so every C_M_AXI_*_DATA_WIDTH of every xilinx.com:hls:* cell is put
# back to the default of the IP now in the catalog — a no-op when they agree.
# Vivado has no reset to default (reset_property refuses CONFIG.*, VALUE_SRC
# DEFAULT keeps the value): the defaults are read from a temporary instance.
#
#   apply_ip_default_widths <bd file>

proc ip_default_widths {vlnv} {
    set probe [create_bd_cell -type ip -vlnv $vlnv ip_default_probe]
    set widths {}
    foreach p [list_property $probe -regexp {^CONFIG\.C_M_AXI_\w+_DATA_WIDTH$}] {
        dict set widths $p [get_property $p $probe]
    }
    delete_bd_objs $probe
    return $widths
}

proc apply_ip_default_widths {bd_file} {
    open_bd_design $bd_file
    set defaults {}
    set changed 0
    foreach cell [get_bd_cells -quiet -filter {VLNV =~ "xilinx.com:hls:*"}] {
        set vlnv [get_property VLNV $cell]
        if {![dict exists $defaults $vlnv]} {
            dict set defaults $vlnv [ip_default_widths $vlnv]
        }
        dict for {p want} [dict get $defaults $vlnv] {
            set have [get_property $p $cell]
            if {$have eq $want} {
                continue
            }
            set_property $p $want $cell
            set have [get_property $p $cell]
            if {$have ne $want} {
                error "apply_ip_default_widths: $cell $p stays $have, the IP default is $want"
            }
            puts "=== $cell: [string range $p 7 end] -> $want (the IP default) ==="
            incr changed
        }
    }
    puts "=== m_axi widths: [dict size $defaults] kernel IP(s) checked, $changed instance parameter(s) reset ==="
    if {$changed > 0} {
        validate_bd_design
    }
    save_bd_design
}
