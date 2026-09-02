# =============================================================================
# gandiva_arty_a7_bench.tcl — Per-benchmark fast bitstream for Embench IoT.
#
# Re-synthesizes with a new firmware.mem (only BRAM INIT values change), then
# uses Vivado incremental implementation from the saved route.dcp checkpoint.
# This avoids full placement+routing (~1-2 min vs ~8 min full flow).
#
# Usage (called by run_embench_fpga.sh):
#   vivado -mode batch -source gandiva_arty_a7_bench.tcl \
#          -tclargs <BUILD_DIR> <BENCH_NAME>
#
# Expects:
#   <BUILD_DIR>/route.dcp               — routed checkpoint from initial synth
#   <BUILD_DIR>/bench_<BENCH_NAME>/firmware.mem — benchmark hex
#
# Produces:
#   <BUILD_DIR>/bench_<BENCH_NAME>/gandiva_arty_a7.bit
# =============================================================================
set fpga_dir  [file normalize [file dirname [info script]]]
set build_dir [file normalize [expr {[llength $argv] >= 1 ? [lindex $argv 0] : "$fpga_dir/build"}]]
set bench     [expr {[llength $argv] >= 2 ? [lindex $argv 1] : "bench"}]
set part      xc7a100tcsg324-1

set bench_dir "$build_dir/bench_$bench"
file mkdir $bench_dir

# ── Read design sources ───────────────────────────────────────────────────────
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

add_files -norecurse $bench_dir/firmware.mem
set_property file_type {Memory Initialization Files} [get_files firmware.mem]

# ── Re-synthesize (fast: only BRAM INIT values differ from prior run) ─────────
# Work in bench_dir so synthesis intermediate files don't collide across runs.
cd $bench_dir
synth_design -top gandiva_arty_a7 -part $part

# ── Incremental implementation from the routed checkpoint ─────────────────────
# Vivado recognises that only BRAM INIT attributes changed and skips full P&R.
read_checkpoint -incremental $build_dir/route.dcp

opt_design
place_design
route_design

# ── Write bitstream ───────────────────────────────────────────────────────────
write_bitstream -force $bench_dir/gandiva_arty_a7.bit
puts "DONE: $bench_dir/gandiva_arty_a7.bit"
