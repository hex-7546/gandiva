#!/usr/bin/env bash
# build_fpga_hello.sh — assemble the FPGA bring-up demo into firmware.mem
# ($readmemh, one 32-bit word per line) for gandiva_fpga.
set -euo pipefail
cd "$(dirname "$0")"

TC="${RISCV_TC:-../../toolchains/riscv/xpack-riscv-none-elf-gcc-15.2.0-1/bin}"
GCC="${GCC:-$TC/riscv-none-elf-gcc}"
OBJCOPY="${OBJCOPY:-$TC/riscv-none-elf-objcopy}"
OUT="${1:-firmware.mem}"

# Check for GCC availability
if ! command -v "$GCC" &>/dev/null && ! command -v riscv-none-elf-gcc &>/dev/null && ! command -v riscv32-unknown-elf-gcc &>/dev/null; then
  echo "ERROR: RISC-V GCC toolchain not found!" >&2
  echo "Please install a RISC-V GCC toolchain (riscv-none-elf-gcc or riscv32-unknown-elf-gcc)" >&2
  echo "and add it to your PATH, or specify its location via the GCC or RISCV_TC environment variable." >&2
  echo "Example: export GCC=/path/to/riscv-none-elf-gcc" >&2
  exit 1
fi

# Use command from PATH if default $GCC path does not exist directly
if ! command -v "$GCC" &>/dev/null; then
  if command -v riscv-none-elf-gcc &>/dev/null; then
    GCC="riscv-none-elf-gcc"
    OBJCOPY="riscv-none-elf-objcopy"
  elif command -v riscv32-unknown-elf-gcc &>/dev/null; then
    GCC="riscv32-unknown-elf-gcc"
    OBJCOPY="riscv32-unknown-elf-objcopy"
  fi
fi

"$GCC" -march=rv32imc -mabi=ilp32 -nostdlib -nostartfiles -fno-pic \
       -Wl,--no-relax -T fpga_hello.ld fpga_hello.S -o fpga_hello.elf
"$OBJCOPY" -O binary fpga_hello.elf fpga_hello.bin
python3 bin2hex.py fpga_hello.bin "$OUT"
echo "wrote $OUT"
