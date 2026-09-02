# =============================================================================
# gandiva_arty_a7_synth.tcl — One-time full synthesis + route, saves routed
#   checkpoint (.dcp) so subsequent firmware swaps only need write_bitstream.
#
#   vivado -mode batch -source gandiva_arty_a7_synth.tcl -tclargs <BUILD_DIR>
#
# Produces:
#   <BUILD_DIR>/route.dcp        — routed checkpoint (reused for re-bitstreams)
#   <BUILD_DIR>/gandiva_arty_a7.bit — initial bitstream
#   <BUILD_DIR>/util.rpt / timing.rpt
# =============================================================================
set fpga_dir  [file normalize [file dirname [info script]]]
set build_dir [file normalize [expr {[llength $argv] >= 1 ? [lindex $argv 0] : "$fpga_dir/build"}]]
set part      xc7a100tcsg324-1

file mkdir $build_dir
cd $build_dir

set fp [open $fpga_dir/gandiva_arty_a7.f r]
while {[gets $fp line] >= 0} {
  set line [string trim $line]
  if {$line eq "" || [string match "#*" $line] || [string match "//*" $line]} { continue }
  if {[string match "+incdir+*" $line]} {
    set incdir [string range $line 8 end]
    set_property include_dirs [list [file normalize $fpga_dir/$incdir]] [current_fileset]
    continue
  }
  read_verilog -sv [file normalize $fpga_dir/$line]
}
close $fp

read_xdc $fpga_dir/gandiva_arty_a7.xdc
set_property part $part [current_project]
set_property top gandiva_arty_a7 [current_fileset]

add_files -norecurse $build_dir/firmware.mem
set_property file_type {Memory Initialization Files} [get_files firmware.mem]

synth_design -top gandiva_arty_a7 -part $part
opt_design
place_design
route_design
report_utilization    -file $build_dir/util.rpt
report_timing_summary -file $build_dir/timing.rpt

# Save routed checkpoint — reused as incremental reference for per-benchmark runs.
write_checkpoint -force $build_dir/route.dcp
puts "Checkpoint saved: $build_dir/route.dcp"

# Write base bitstream.
write_bitstream -force $build_dir/gandiva_arty_a7.bit
puts "DONE: $build_dir/gandiva_arty_a7.bit"

