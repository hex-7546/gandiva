# ============================================================================
# Gandiva build & test driver (Icarus Verilog) — Windows / PowerShell.
#
#   .\build.ps1 [sim|cosim|rvfi|debug|trigger|clean]
#
# Gandiva is the clean, golden-co-simulated 5-stage in-order RV32IMAC(+B) core.
# The datapath leaf cells live in rtl/common; the core, SoC, UART, AXI4-Lite
# wrapper, the hardware-trigger unit and the RISC-V Debug Module live in rtl/.
# ============================================================================
param([string]$Action = "sim")
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$IVL = if ($env:IVERILOG) { $env:IVERILOG } else { "iverilog" }
$VVP = if ($env:VVP) { $env:VVP } else { "vvp" }
$R = "rtl"; $C = "rtl/common"; $DBG = "rtl/gandiva_debug.sv"

$CELLS = @(
  "$C/gandiva_pkg.sv","$C/gandiva_alu.sv","$C/gandiva_regfile.sv",
  "$C/gandiva_muldiv.sv","$C/gandiva_csr.sv","$C/gandiva_rvc.sv",
  "$C/gandiva_immgen.sv","$C/gandiva_branch.sv","$C/gandiva_decode.sv",
  "$C/gandiva_pmp.sv"
)
$CORE = @("$R/gandiva_trigger.sv","$R/gandiva_core.sv")
$SOC  = @($DBG,"$R/gandiva_uart.sv","$R/gandiva_soc.sv")

if ($Action -eq "clean") {
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue sim, programs/build, rtos/build, *.vcd
  Write-Host "Cleaned"; exit 0
}
New-Item -ItemType Directory -Force -Path sim, programs/build | Out-Null

if ($Action -eq "axi") {
  Write-Host "Building Gandiva AXI4-Lite MASTER bridge sim..."
  & $IVL -g2012 -I $C -I $R -o sim/tb_gandiva_axi "$C/gandiva_pkg.sv" "$R/gandiva_axi_lite.sv" tb/tb_gandiva_axi.sv
  & $VVP sim/tb_gandiva_axi; exit 0
}

if ($Action -eq "debug") {
  Write-Host "Building Gandiva debug (JTAG DM) sim..."
  & $IVL -g2012 -I $C -I $R -o sim/tb_gandiva_debug @CELLS @CORE @SOC tb/tb_gandiva_debug.sv
  & $VVP sim/tb_gandiva_debug; exit 0
}

if ($Action -eq "trigger") {
  Write-Host "Building Gandiva hardware-trigger (Sdtrig/mcontrol6) sim..."
  & $IVL -g2012 -I $C -I $R -o sim/tb_gandiva_trigger @CELLS @CORE @SOC tb/tb_gandiva_trigger.sv
  & $VVP sim/tb_gandiva_trigger; exit 0
}

# ---- default: smoke (+ optional cosim / rvfi) ------------------------------
python programs/build_smoke.py
Write-Host "Compiling..."
& $IVL -g2012 -I $C -I $R -o sim/tb_gandiva @CELLS @CORE @SOC tb/tb_gandiva.sv
Write-Host "Running smoke..."
& $VVP sim/tb_gandiva +IMEM=programs/build/smoke.hex

if ($Action -eq "cosim") {
  Write-Host "Co-simulating against golden model..."
  $env:VVP = $VVP
  python tools/cosim.py --hex programs/build/smoke.hex --sim sim/tb_gandiva
}
if ($Action -eq "rvfi") {
  Write-Host "Building RVFI (riscv-formal interface) self-check..."
  & $IVL -g2012 -DRISCV_FORMAL -I $C -I $R -o sim/tb_gandiva_rvfi @CELLS @CORE @SOC tb/tb_gandiva_rvfi.sv
  & $VVP sim/tb_gandiva_rvfi +IMEM=programs/build/smoke.hex
}
