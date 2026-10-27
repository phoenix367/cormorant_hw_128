# Copyright 2026 Ivan Gubochkin
# SPDX-License-Identifier: Apache-2.0

# bd_mipi_capture.tcl — the KV260's camera (AR1335 sensor behind the carrier
# card's AP1302 ISP, IAS0 connector) into DDR: the capture path of AMD's
# kv260_ispMipiRx_vcu_DP platform (Xilinx/kria-vitis-platforms, 2022.1–2023.1
# scripts/config_bd.tcl, xdc/pin.xdc), without its VCU and audio.
# Idempotent; run on the project with the BD open or pass the .xpr:
#
#   vivado -mode batch -source scripts/bd_mipi_capture.tcl -tclargs <xpr> [-ip-repo DIR]
#
# Adds, when missing (every cell prefixed cap_):
#   cap_csi        mipi_csi2_rx_subsystem: 4 lanes on bank 66 (clock G1, data
#                  E1 F2 G3 E4), 896 Mb/s, YUV 4:2:0 8-bit, 2 pixels per clock,
#                  video format bridge — what the AP1302 firmware sends
#   cap_fifo       axis_data_fifo, 512 deep
#   cap_subset     axis_subset_converter: 32-bit -> 48-bit TDATA (2 x 24-bit pixels)
#   cap_fb         v_frmbuf_wr: NV12 only, <= 1920 x 1080, 2 pixels per clock,
#                  128-bit m_axi_mm_video into S_AXI_HP3_FPD (SAXIGP5), its line
#                  buffers in four RAMB36 (block RAM is 136 / 144 without the path)
#   cap_iic        axi_iic, 400 kHz: the carrier's PCA9546 switch (0x74), the
#                  AP1302 (0x3c) on its channel 0
#   cap_smc        SmartConnect from M_AXI_HPM0_LPD (100 MHz pl_clk0): cap_csi
#                  at 0x8000_0000 (8 KiB), cap_fb at 0x8001_0000, cap_iic at
#                  0x8003_0000 (the smartcam overlay's addresses, cap_fb moved
#                  from 0xB001_0000)
#   cap_clk        an MMCM of its own from pl_clk0: 200 MHz, the D-PHY reference
#                  and the video clock (cap_csi video, cap_fifo, cap_subset,
#                  cap_fb, saxihp3_fpd_aclk); cap_rst_video / cap_rst_lite
#   cap_irq        pl_ps_irq1: In0 cap_csi (SPI 104), In1 cap_fb (105), In2 0,
#                  In3 cap_iic (107) — the smartcam overlay's numbers
#   EMIO GPIO      2 bits: bit 0 cap_fb's ap_rst_n (GPIO 78), bit 1 the ISP's
#                  reset ap1302_rst_b (GPIO 79, pin J11); ap1302_standby (J10) 0
#   ports          mipi_phy_if, iic (G11 / F10), ap1302_rst_b, ap1302_standby;
#                  their pins in constrs_1/new/capture.xdc
#
# The five kernels, their interconnects, clk_wiz_0 and the 250 MHz domain are
# untouched.  -ip-repo and the locked-IP upgrade as bd_rowops_hp0.tcl.

set cap_ctrl {cap_csi 0x80000000 8K cap_fb 0x80010000 64K cap_iic 0x80030000 64K}

proc cap_cell {name vlnv} {
    set c [get_bd_cells -quiet $name]
    if {$c eq ""} {
        set c [create_bd_cell -type ip -vlnv $vlnv $name]
        puts "=== $name created ==="
    }
    return $c
}

proc cap_attach {src pin} {
    set p [get_bd_pins $pin]
    if {[get_bd_nets -quiet -of_objects $p] ne ""} { return }
    set s [get_bd_pins -quiet $src]
    if {$s eq ""} { set s [get_bd_ports $src] }
    set net [get_bd_nets -quiet -of_objects $s]
    if {$net ne ""} { connect_bd_net -net $net $p } else { connect_bd_net $s $p }
}

proc cap_intf {a b} {
    set pa [get_bd_intf_pins -quiet $a]
    if {$pa eq ""} { set pa [get_bd_intf_ports $a] }
    set pb [get_bd_intf_pins -quiet $b]
    if {$pb eq ""} { set pb [get_bd_intf_ports $b] }
    if {[get_bd_intf_nets -quiet -of_objects $pa] ne ""} { return }
    connect_bd_intf_net $pa $pb
}

proc apply_mipi_capture {} {
    global cap_ctrl
    set ps [get_bd_cells zynq_ultra_ps_e_0]
    set_property -dict [list \
        CONFIG.PSU__USE__M_AXI_GP2 {1} CONFIG.PSU__MAXIGP2__DATA_WIDTH {32} \
        CONFIG.PSU__USE__S_AXI_GP5 {1} CONFIG.PSU__SAXIGP5__DATA_WIDTH {128} \
        CONFIG.PSU__USE__IRQ1 {1} \
        CONFIG.PSU__GPIO_EMIO__PERIPHERAL__ENABLE {1} CONFIG.PSU__GPIO_EMIO__PERIPHERAL__IO {2}] $ps

    # clocks and resets: 100 MHz control (pl_clk0), 200 MHz video (an MMCM of its own)
    set clk [cap_cell cap_clk xilinx.com:ip:clk_wiz]
    # its input frequency propagates from pl_clk0 (99 999 001 Hz)
    set_property -dict [list CONFIG.PRIM_SOURCE {No_buffer} \
        CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {200.000} CONFIG.CLK_OUT1_PORT {clk_200M} \
        CONFIG.USE_LOCKED {true} CONFIG.USE_RESET {true} \
        CONFIG.RESET_TYPE {ACTIVE_LOW} CONFIG.RESET_PORT {resetn}] $clk
    cap_attach zynq_ultra_ps_e_0/pl_clk0 cap_clk/clk_in1
    cap_attach zynq_ultra_ps_e_0/pl_resetn0 cap_clk/resetn
    cap_cell cap_rst_video xilinx.com:ip:proc_sys_reset
    cap_attach cap_clk/clk_200M cap_rst_video/slowest_sync_clk
    cap_attach zynq_ultra_ps_e_0/pl_resetn0 cap_rst_video/ext_reset_in
    cap_attach cap_clk/locked cap_rst_video/dcm_locked
    cap_cell cap_rst_lite xilinx.com:ip:proc_sys_reset
    cap_attach zynq_ultra_ps_e_0/pl_clk0 cap_rst_lite/slowest_sync_clk
    cap_attach zynq_ultra_ps_e_0/pl_resetn0 cap_rst_lite/ext_reset_in
    set vclk cap_clk/clk_200M
    set vrst cap_rst_video/peripheral_aresetn
    set lclk zynq_ultra_ps_e_0/pl_clk0
    set lrst cap_rst_lite/peripheral_aresetn

    # the CSI-2 receiver: the order matters (bank before pins, lanes before data pins)
    set csi [cap_cell cap_csi xilinx.com:ip:mipi_csi2_rx_subsystem]
    set_property -dict [list CONFIG.CMN_NUM_LANES {4} CONFIG.CMN_NUM_PIXELS {2} \
        CONFIG.CMN_PXL_FORMAT {YUV420_8bit} CONFIG.CMN_VC {0} CONFIG.CMN_INC_VFB {true} \
        CONFIG.CSI_BUF_DEPTH {2048} CONFIG.YUV420_BUF_DPTH {2048} \
        CONFIG.C_CSI_FILTER_USERDATATYPE {true} CONFIG.C_CSI_EN_ACTIVELANES {true} \
        CONFIG.C_HS_LINE_RATE {896} CONFIG.DPY_LINE_RATE {896} CONFIG.C_HS_SETTLE_NS {146} \
        CONFIG.SupportLevel {1}] $csi
    set_property CONFIG.HP_IO_BANK_SELECTION {66} $csi
    set_property -dict [list CONFIG.CLK_LANE_IO_LOC {G1} CONFIG.DATA_LANE0_IO_LOC {E1} \
        CONFIG.DATA_LANE1_IO_LOC {F2} CONFIG.DATA_LANE2_IO_LOC {G3} CONFIG.DATA_LANE3_IO_LOC {E4}] $csi
    cap_attach $lclk cap_csi/lite_aclk
    cap_attach $lrst cap_csi/lite_aresetn
    cap_attach $vclk cap_csi/dphy_clk_200M
    cap_attach $vclk cap_csi/video_aclk
    cap_attach $vrst cap_csi/video_aresetn

    # stream to the frame buffer: FIFO, 32 -> 48-bit TDATA
    set fifo [cap_cell cap_fifo xilinx.com:ip:axis_data_fifo]
    set_property CONFIG.FIFO_DEPTH {512} $fifo
    cap_attach $vclk cap_fifo/s_axis_aclk
    cap_attach $vrst cap_fifo/s_axis_aresetn
    set sub [cap_cell cap_subset xilinx.com:ip:axis_subset_converter]
    cap_intf cap_csi/video_out cap_fifo/S_AXIS
    cap_intf cap_fifo/M_AXIS cap_subset/S_AXIS
    # the input side as cap_csi's video_out has it (propagated only on validation)
    set vo [get_bd_intf_pins cap_csi/video_out]
    set_property -dict [list CONFIG.S_TDATA_NUM_BYTES [get_property CONFIG.TDATA_NUM_BYTES $vo] \
        CONFIG.S_TDEST_WIDTH [get_property CONFIG.TDEST_WIDTH $vo]] $sub
    set_property -dict [list CONFIG.M_TDATA_NUM_BYTES {6} CONFIG.M_TDEST_WIDTH {1} \
        CONFIG.TDATA_REMAP {16'b00000000,tdata[31:0]} CONFIG.TDEST_REMAP {tdest[0:0]}] $sub
    cap_attach $vclk cap_subset/aclk
    cap_attach $vrst cap_subset/aresetn

    set fb [cap_cell cap_fb xilinx.com:ip:v_frmbuf_wr]
    set off {}
    foreach p [list_property $fb CONFIG.HAS_*] { lappend off $p 0 }
    set_property -dict $off $fb
    set_property -dict [list CONFIG.HAS_Y_UV8_420 {1} CONFIG.MAX_NR_PLANES {2} \
        CONFIG.MAX_COLS {1920} CONFIG.MAX_ROWS {1080} CONFIG.SAMPLES_PER_CLOCK {2} \
        CONFIG.AXIMM_DATA_WIDTH {128} CONFIG.C_M_AXI_MM_VIDEO_DATA_WIDTH {128}] $fb
    cap_intf cap_subset/M_AXIS cap_fb/s_axis_video
    cap_attach $vclk cap_fb/ap_clk

    # EMIO GPIO: bit 0 the frame buffer's reset, bit 1 the ISP's
    set s0 [cap_cell cap_fb_rst xilinx.com:ip:xlslice]
    set_property -dict [list CONFIG.DIN_WIDTH {2} CONFIG.DIN_FROM {0} CONFIG.DIN_TO {0}] $s0
    set s1 [cap_cell cap_isp_rst xilinx.com:ip:xlslice]
    set_property -dict [list CONFIG.DIN_WIDTH {2} CONFIG.DIN_FROM {1} CONFIG.DIN_TO {1}] $s1
    cap_attach zynq_ultra_ps_e_0/emio_gpio_o cap_fb_rst/Din
    cap_attach zynq_ultra_ps_e_0/emio_gpio_o cap_isp_rst/Din
    cap_attach cap_fb_rst/Dout cap_fb/ap_rst_n
    set z [cap_cell cap_zero xilinx.com:ip:xlconstant]
    set_property -dict [list CONFIG.CONST_VAL {0} CONFIG.CONST_WIDTH {1}] $z
    if {[get_bd_ports -quiet ap1302_rst_b] eq ""} {
        create_bd_port -dir O -from 0 -to 0 ap1302_rst_b
        create_bd_port -dir O -from 0 -to 0 ap1302_standby
    }
    cap_attach cap_isp_rst/Dout ap1302_rst_b
    cap_attach cap_zero/dout ap1302_standby

    # the I2C master and the external interfaces
    set iic [cap_cell cap_iic xilinx.com:ip:axi_iic]
    set_property CONFIG.IIC_FREQ_KHZ {400} $iic
    cap_attach $lclk cap_iic/s_axi_aclk
    cap_attach $lrst cap_iic/s_axi_aresetn
    if {[get_bd_intf_ports -quiet iic] eq ""} {
        create_bd_intf_port -mode Master -vlnv xilinx.com:interface:iic_rtl:1.0 iic
        create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:mipi_phy_rtl:1.0 mipi_phy_if
    }
    cap_intf cap_iic/IIC iic
    cap_intf mipi_phy_if cap_csi/mipi_phy_if

    # control: M_AXI_HPM0_LPD -> cap_smc -> cap_csi, cap_fb, cap_iic
    set smc [cap_cell cap_smc xilinx.com:ip:smartconnect]
    set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {3} CONFIG.NUM_CLKS {2}] $smc
    cap_attach $lclk zynq_ultra_ps_e_0/maxihpm0_lpd_aclk
    cap_attach $lclk cap_smc/aclk
    cap_attach $vclk cap_smc/aclk1
    cap_attach cap_rst_lite/interconnect_aresetn cap_smc/aresetn
    cap_intf zynq_ultra_ps_e_0/M_AXI_HPM0_LPD cap_smc/S00_AXI
    cap_intf cap_smc/M00_AXI cap_csi/csirxss_s_axi
    cap_intf cap_smc/M01_AXI cap_fb/s_axi_CTRL
    cap_intf cap_smc/M02_AXI cap_iic/S_AXI

    # data: the frame buffer straight into S_AXI_HP3_FPD
    cap_attach $vclk zynq_ultra_ps_e_0/saxihp3_fpd_aclk
    cap_intf cap_fb/m_axi_mm_video zynq_ultra_ps_e_0/S_AXI_HP3_FPD

    # interrupts on pl_ps_irq1
    set irq [cap_cell cap_irq xilinx.com:ip:xlconcat]
    set_property CONFIG.NUM_PORTS {4} $irq
    cap_attach cap_csi/csirxss_csi_irq cap_irq/In0
    cap_attach cap_fb/interrupt cap_irq/In1
    cap_attach cap_zero/dout cap_irq/In2
    cap_attach cap_iic/iic2intc_irpt cap_irq/In3
    cap_attach cap_irq/dout zynq_ultra_ps_e_0/pl_ps_irq1

    # addresses: the control blocks where the smartcam overlay has them, the
    # frame buffer's DMA into the low 2 GiB of DDR through HP3
    set data [get_bd_addr_spaces zynq_ultra_ps_e_0/Data]
    foreach {cell off range} $cap_ctrl {
        set intf [get_bd_intf_pins -of_objects [get_bd_cells $cell] -filter {MODE == Slave && VLNV =~ "*aximm*"}]
        foreach seg [get_bd_addr_segs -of_objects $intf] {
            if {[get_bd_addr_segs -quiet -of_objects $data -filter "NAME =~ SEG_${cell}_*"] eq ""} {
                assign_bd_address -offset $off -range $range -target_address_space $data $seg
            }
        }
    }
    set fbsp [get_bd_addr_spaces cap_fb/Data_m_axi_mm_video]
    if {[get_bd_addr_segs -quiet -of_objects $fbsp] eq ""} {
        assign_bd_address -offset 0x00000000 -range 2G -target_address_space $fbsp \
            [get_bd_addr_segs zynq_ultra_ps_e_0/SAXIGP5/HP3_DDR_LOW]
    }
}

proc cap_report {} {
    foreach seg [lsort [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] -filter {NAME =~ SEG_cap_*}]] {
        puts "=== [file tail $seg] at [get_property OFFSET $seg] range [get_property RANGE $seg] ==="
    }
    foreach seg [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces cap_fb/Data_m_axi_mm_video]] {
        puts "=== cap_fb DMA: [file tail $seg] at [get_property OFFSET $seg] range [get_property RANGE $seg] ==="
    }
    set csi [get_bd_cells cap_csi]
    foreach p {CMN_NUM_LANES CMN_NUM_PIXELS CMN_PXL_FORMAT DPY_LINE_RATE C_HS_SETTLE_NS HP_IO_BANK_SELECTION CLK_LANE_IO_LOC DATA_LANE0_IO_LOC DATA_LANE3_IO_LOC} {
        puts "=== cap_csi $p = [get_property CONFIG.$p $csi] ==="
    }
    puts "=== cap_clk clk_200M = [get_property CONFIG.FREQ_HZ [get_bd_pins cap_clk/clk_200M]] Hz ==="
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
    apply_mipi_capture
    validate_bd_design
    cap_report
    save_bd_design
    # the camera pins, if the project does not list them yet
    set xdc [file normalize [file join [file dirname [lindex $argv 0]] cormorant_hw_128.srcs constrs_1 new capture.xdc]]
    if {[file exists $xdc] && [llength [get_files -quiet -of_objects [get_filesets constrs_1] $xdc]] == 0} {
        add_files -fileset constrs_1 -norecurse $xdc
        puts "=== constrs_1: capture.xdc added ==="
    }
    close_project
}
