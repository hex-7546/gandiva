# ============================================================================
# gandiva_zcu102.xdc — ZCU102 (xczu9eg-ffvb1156-2-e) PL constraints.
#
# !!! TEMPLATE — PLACEHOLDER PINS. Verify EVERY line against the ZCU102 master
# !!! XDC for YOUR board revision before build. See kavacha_zcu102.xdc notes.
# ============================================================================

create_clock -period 10.000 -name pl_clk [get_ports pl_clk]
# set_property PACKAGE_PIN <PIN> [get_ports pl_clk]    ;# if driving a direct pin

set_property -dict {PACKAGE_PIN AG13 IOSTANDARD LVCMOS33} [get_ports rst]      ;# VERIFY

set_property -dict {PACKAGE_PIN AG14 IOSTANDARD LVCMOS33} [get_ports {led[0]}] ;# VERIFY
set_property -dict {PACKAGE_PIN AF13 IOSTANDARD LVCMOS33} [get_ports {led[1]}] ;# VERIFY
set_property -dict {PACKAGE_PIN AE13 IOSTANDARD LVCMOS33} [get_ports {led[2]}] ;# VERIFY
set_property -dict {PACKAGE_PIN AJ14 IOSTANDARD LVCMOS33} [get_ports {led[3]}] ;# VERIFY
set_property -dict {PACKAGE_PIN AJ15 IOSTANDARD LVCMOS33} [get_ports {led[4]}] ;# VERIFY
set_property -dict {PACKAGE_PIN AH13 IOSTANDARD LVCMOS33} [get_ports {led[5]}] ;# VERIFY
set_property -dict {PACKAGE_PIN AH14 IOSTANDARD LVCMOS33} [get_ports {led[6]}] ;# VERIFY
set_property -dict {PACKAGE_PIN AL12 IOSTANDARD LVCMOS33} [get_ports {led[7]}] ;# VERIFY

set_property -dict {PACKAGE_PIN A20 IOSTANDARD LVCMOS33} [get_ports uart_rx]   ;# VERIFY (PMOD0)
set_property -dict {PACKAGE_PIN B20 IOSTANDARD LVCMOS33} [get_ports uart_tx]   ;# VERIFY (PMOD0)
