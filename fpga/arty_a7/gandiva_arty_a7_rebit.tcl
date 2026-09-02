# =============================================================================
# gandiva_arty_a7_rebit.tcl — Fast re-bitstream from routed checkpoint.
#   Opens route.dcp, updates BRAM init from firmware.mem, writes new bitstream.
#   Much faster than full re-synthesis (~30-60 s vs ~5-10 min).
#
#   vivado -mode batch -source gandiva_arty_a7_rebit.tcl \
#          -tclargs <BUILD_DIR> <BENCH_NAME>
#
# Produces:
#   <BUILD_DIR>/bench_<BENCH_NAME>/gandiva_arty_a7.bit
# =============================================================================
set fpga_dir  [file normalize [file dirname [info script]]]
set build_dir [file normalize [expr {[llength $argv] >= 1 ? [lindex $argv 0] : "$fpga_dir/build"}]]
set bench     [expr {[llength $argv] >= 2 ? [lindex $argv 1] : "bench"}]

set bench_dir "$build_dir/bench_$bench"
file mkdir $bench_dir

# Copy firmware.mem for this benchmark into the bench dir and also back to
# build_dir (so Vivado picks it up from the checkpoint's file reference).
file copy -force "$bench_dir/firmware.mem" "$build_dir/firmware.mem"

open_checkpoint "$build_dir/route.dcp"

# Refresh the memory initialisation files so BRAM content is updated.
add_files -norecurse "$build_dir/firmware.mem"
set_property file_type {Memory Initialization Files} [get_files firmware.mem]

# Re-write bitstream with updated BRAM content.
write_bitstream -force "$bench_dir/gandiva_arty_a7.bit"
puts "DONE: $bench_dir/gandiva_arty_a7.bit"
