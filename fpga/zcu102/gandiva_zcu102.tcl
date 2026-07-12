# =============================================================================
# gandiva_zcu102.tcl — Vivado batch flow to a BITSTREAM for the ZCU102.
#   vivado -mode batch -source gandiva_zcu102.tcl -tclargs <BUILD_DIR>
# Confirm the clock source + placeholder pins in gandiva_zcu102.xdc first.
# Build firmware: cd sw && ./build_fpga_hello.sh && cp firmware.mem <BUILD_DIR>/
# =============================================================================
set fpga_dir  [file normalize [file dirname [info script]]]
set build_dir [expr {[llength $argv] >= 1 ? [lindex $argv 0] : "$fpga_dir/build"}]
set part      xczu9eg-ffvb1156-2-e

file mkdir $build_dir
cd $build_dir

set fp [open $fpga_dir/gandiva_zcu102.f r]
while {[gets $fp line] >= 0} {
  set line [string trim $line]
  if {$line eq "" || [string match "#*" $line]} { continue }
  read_verilog -sv [file normalize $fpga_dir/$line]
}
close $fp

read_xdc $fpga_dir/gandiva_zcu102.xdc
set_property part $part [current_project]
set_property top gandiva_zcu102 [current_fileset]

add_files -norecurse $build_dir/firmware.mem
set_property file_type {Memory Initialization Files} [get_files firmware.mem]

synth_design -top gandiva_zcu102 -part $part
opt_design
place_design
route_design
report_utilization    -file $build_dir/util.rpt
report_timing_summary -file $build_dir/timing.rpt
write_bitstream -force $build_dir/gandiva_zcu102.bit
puts "DONE: $build_dir/gandiva_zcu102.bit"
