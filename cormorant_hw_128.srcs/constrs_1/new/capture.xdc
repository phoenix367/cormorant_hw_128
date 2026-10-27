# Copyright 2026 Ivan Gubochkin
# SPDX-License-Identifier: Apache-2.0

# capture.xdc — the camera ports of scripts/bd_mipi_capture.tcl on the KV260
# carrier card (Xilinx/kria-vitis-platforms kv260_ispMipiRx_vcu_DP
# xdc/pin.xdc; the SOM board file's part0_pins.xml agrees).  The MIPI lanes'
# pins and I/O standard come from cap_csi's own constraints (bank 66).

set_property DIFF_TERM_ADV TERM_100 [get_ports {mipi_phy_if_clk_p}]
set_property DIFF_TERM_ADV TERM_100 [get_ports {mipi_phy_if_clk_n}]
set_property DIFF_TERM_ADV TERM_100 [get_ports {mipi_phy_if_data_p[*]}]
set_property DIFF_TERM_ADV TERM_100 [get_ports {mipi_phy_if_data_n[*]}]

# the AP1302's reset (HDA02) and standby (HDA03)
set_property PACKAGE_PIN J11 [get_ports {ap1302_rst_b[*]}]
set_property PACKAGE_PIN J10 [get_ports {ap1302_standby[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports {ap1302_rst_b[*] ap1302_standby[*]}]
set_property SLEW SLOW [get_ports {ap1302_rst_b[*] ap1302_standby[*]}]
set_property DRIVE 4 [get_ports {ap1302_rst_b[*] ap1302_standby[*]}]

# I2C to the PCA9546 switch: channel 0 the AP1302 and the AR1335
set_property PACKAGE_PIN G11 [get_ports iic_scl_io]
set_property PACKAGE_PIN F10 [get_ports iic_sda_io]
set_property IOSTANDARD LVCMOS33 [get_ports {iic_scl_io iic_sda_io}]
set_property SLEW SLOW [get_ports {iic_scl_io iic_sda_io}]
set_property DRIVE 4 [get_ports {iic_scl_io iic_sda_io}]
