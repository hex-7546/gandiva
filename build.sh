#!/usr/bin/env bash
# ============================================================================
# Gandiva build & test driver (Icarus Verilog).
#
#   ./build.sh [sim|cosim|rvfi|debug|trigger|priv|axi|ecc|rtos|fpga|clean]
#
# Gandiva is the clean, golden-co-simulated 5-stage in-order RV32IMAC(+B) core.
# The datapath leaf cells (ALU / muldiv / regfile / CSR / RVC / immgen / branch
# / decoder / PMP) live in rtl/common; the core, SoC, UART, AXI4-Lite wrapper,
# the hardware-trigger unit and the RISC-V Debug Module live in rtl/.
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"
VERILATOR="${VERILATOR:-verilator --binary --timing -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-MULTIDRIVEN -j 4}"
ACTION="${1:-sim}"

R=rtl
C=rtl/common
DBG=rtl/gandiva_debug.sv

# Shared datapath leaf cells, in elaboration order.
CELLS=( \
  "$C/gandiva_pkg.sv" "$C/gandiva_alu.sv" "$C/gandiva_regfile.sv" \
  "$C/gandiva_muldiv.sv" "$C/gandiva_csr.sv" "$C/gandiva_rvc.sv" \
  "$C/gandiva_immgen.sv" "$C/gandiva_branch.sv" "$C/gandiva_decode.sv" \
  "$C/gandiva_pmp.sv" )

# Core RTL used by the SoC-level testbenches (smoke / rvfi / debug / trigger).
CORE=( "$R/gandiva_trigger.sv" "$R/gandiva_core.sv" )
SOC=(  "$DBG" "$R/gandiva_uart.sv" "$R/gandiva_soc.sv" )

if [[ "$ACTION" == "clean" ]]; then
  rm -rf sim programs/build rtos/build *.vcd
  echo "Cleaned"; exit 0
fi
mkdir -p sim programs/build

if [[ "$ACTION" == "priv" ]]; then
  # Directed M/U + PMP + N user-trap tests on a SECURE=1 core. The priv
  # testbench instantiates gandiva_core #(.SECURE(1)) directly (no SoC).
  echo "Building Gandiva SECURE priv/PMP/N sim..."
  python programs/build_priv.py
  python programs/build_ntrap.py
  $VERILATOR -I"$C" -I"$R" --Mdir sim -o tb_gandiva_priv \
    "${CELLS[@]}" "${CORE[@]}" tb/tb_gandiva_priv.sv 2>/dev/null
  fail=0
  for t in ustore_fault ustore_ok ecall_u ecall_m ifetch_fault ifetch_ok ucsr_u ucsr_m \
           udeleg nodel; do
    hex=""
    [[ -f programs/build/priv_$t.hex  ]] && hex=programs/build/priv_$t.hex
    [[ -f programs/build/ntrap_$t.hex ]] && hex=programs/build/ntrap_$t.hex
    r=$(sim/tb_gandiva_priv +IMEM="$hex" 2>&1 | grep RESULT)
    printf "  %-16s %s\n" "$t" "$r"
    [[ "$r" == *PASS* ]] || fail=1
  done
  [[ $fail -eq 0 ]] && echo "priv: ALL PASS" || { echo "priv: FAILURES"; exit 1; }
  exit 0
fi

if [[ "$ACTION" == "rtos" ]]; then
  # Port + run a REAL preemptive RTOS (FreeRTOS) on Gandiva. Builds the kernel
  # + RISC-V port + Gandiva BSP into an IMEM image, runs it on the SoC sim
  # (CLINT tick + UART console) and asserts the transcript plus a negative
  # control (tick disabled -> demo stalls). See rtos/run_rtos.py.
  echo "Building Gandiva FreeRTOS demo (positive + negative-control images)..."
  bash rtos/build_rtos.sh
  bash rtos/build_rtos.sh neg
  echo "Running FreeRTOS demo + assertions..."
  VERILATOR="$VERILATOR" python rtos/run_rtos.py
  exit $?
fi

if [[ "$ACTION" == "debug" ]]; then
  echo "Building Gandiva debug (JTAG DM) sim..."
  $VERILATOR -I"$C" -I"$R" --Mdir sim -o tb_gandiva_debug \
    "${CELLS[@]}" "${CORE[@]}" "${SOC[@]}" tb/tb_gandiva_debug.sv
  sim/tb_gandiva_debug
  exit 0
fi

if [[ "$ACTION" == "trigger" ]]; then
  # Hardware debug triggers (Sdtrig / mcontrol6): PC-match + store-address
  # watchpoints driven over the JTAG TAP, with negative controls.
  echo "Building Gandiva hardware-trigger (Sdtrig/mcontrol6) sim..."
  $VERILATOR -I"$C" -I"$R" --Mdir sim -o tb_gandiva_trigger \
    "${CELLS[@]}" "${CORE[@]}" "${SOC[@]}" tb/tb_gandiva_trigger.sv
  sim/tb_gandiva_trigger
  exit 0
fi

if [[ "$ACTION" == "axi" ]]; then
  # OPTIONAL AXI4-Lite MASTER bridge — standalone leaf cell + slave-mem BFM tb.
  # The default gandiva_soc + compliance path never instantiate it (unchanged).
  echo "Building Gandiva AXI4-Lite MASTER bridge sim..."
  $VERILATOR -I"$C" -I"$R" --Mdir sim -o tb_gandiva_axi \
    "$C/gandiva_pkg.sv" "$R/gandiva_axi_lite.sv" tb/tb_gandiva_axi.sv
  sim/tb_gandiva_axi
  exit 0
fi

if [[ "$ACTION" == "ecc" ]]; then
  # SECDED-protected register file leaf cell: single-bit correct, double detect.
  echo "Building Gandiva regfile ECC (SECDED) unit sim..."
  $VERILATOR -I"$C" --Mdir sim -o tb_regfile_ecc \
    "$C/gandiva_pkg.sv" "$C/gandiva_regfile_ecc.sv" tb/tb_regfile_ecc.sv
  sim/tb_regfile_ecc
  exit 0
fi

if [[ "$ACTION" == "fpga" ]]; then
  echo "Building FPGA SoC sim (UART banner + LED blink)..."
  bash sw/build_fpga_hello.sh
  $VERILATOR -DSIMULATION -I"$C" -I"$R" --Mdir sim -o tb_gandiva_fpga \
    "${CELLS[@]}" "${CORE[@]}" "$R/gandiva_uart.sv" \
    fpga/gandiva_fpga.sv fpga/tb_gandiva_fpga.sv
  sim/tb_gandiva_fpga
  exit 0
fi

# ---- default: smoke (+ optional cosim / rvfi) ------------------------------
python programs/build_smoke.py
echo "Compiling..."
$VERILATOR -I"$C" -I"$R" --Mdir sim -o tb_gandiva \
  "${CELLS[@]}" "${CORE[@]}" "${SOC[@]}" tb/tb_gandiva.sv
echo "Running smoke..."
sim/tb_gandiva +IMEM=programs/build/smoke.hex

if [[ "$ACTION" == "cosim" ]]; then
  echo "Co-simulating against golden model..."
  VVP="" VERILATOR="$VERILATOR" python tools/cosim.py \
      --hex programs/build/smoke.hex --sim sim/tb_gandiva
fi

if [[ "$ACTION" == "rvfi" ]]; then
  echo "Building RVFI (riscv-formal interface) self-check..."
  $VERILATOR -DRISCV_FORMAL -I"$C" -I"$R" --Mdir sim -o tb_gandiva_rvfi \
    "${CELLS[@]}" "${CORE[@]}" "${SOC[@]}" tb/tb_gandiva_rvfi.sv
  sim/tb_gandiva_rvfi +IMEM=programs/build/smoke.hex
fi
