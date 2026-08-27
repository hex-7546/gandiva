#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

TC="${RISCV_TC:-/home/yash/toolchains/xpack-riscv-none-elf-gcc-13.2.0-2/bin}"
GCC="${GCC:-$TC/riscv-none-elf-gcc}"
OBJCOPY="${OBJCOPY:-$TC/riscv-none-elf-objcopy}"

# Check for GCC availability
if ! command -v "$GCC" &>/dev/null && ! command -v riscv-none-elf-gcc &>/dev/null && ! command -v riscv32-unknown-elf-gcc &>/dev/null; then
  echo "ERROR: RISC-V GCC toolchain not found!" >&2
  exit 1
fi

if ! command -v "$GCC" &>/dev/null; then
  if command -v riscv-none-elf-gcc &>/dev/null; then
    GCC="riscv-none-elf-gcc"
    OBJCOPY="riscv-none-elf-objcopy"
  elif command -v riscv32-unknown-elf-gcc &>/dev/null; then
    GCC="riscv32-unknown-elf-gcc"
    OBJCOPY="riscv32-unknown-elf-objcopy"
  fi
fi

FLAGS="-O3 -march=rv32imc -mabi=ilp32 -nostartfiles -fno-pic -Wl,--no-relax"
INCLUDES="-I. -Ibarebones"

echo "Compiling CoreMark for Gandiva..."

ITERATIONS="${1:-1}"

"$GCC" $FLAGS $INCLUDES -T link.ld \
    -DITERATIONS=$ITERATIONS -DFLAGS_STR="\"$FLAGS\"" \
    start.S \
    core_portme.c \
    core_list_join.c \
    core_main.c \
    core_matrix.c \
    core_state.c \
    core_util.c \
    barebones/ee_printf.c \
    -o coremark.elf

echo "Generating hex file..."
"$OBJCOPY" -O binary coremark.elf coremark.bin
python3 ../../sw/bin2hex.py coremark.bin coremark.hex
echo "Done. coremark.hex is ready."
