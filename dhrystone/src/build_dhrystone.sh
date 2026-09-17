#!/usr/bin/env bash
# build_dhrystone.sh — compile Dhrystone 2.1 for Gandiva simulation.
# Usage: ./build_dhrystone.sh [NUMBER_OF_RUNS]
set -euo pipefail
cd "$(dirname "$0")"

TC_PREFIX="${RISCV_TC:+$RISCV_TC/}"
GCC="${GCC:-}"
OBJCOPY="${OBJCOPY:-}"

# Toolchain auto-detect
if [[ -z "$GCC" ]]; then
  if [[ -n "$TC_PREFIX" ]] && command -v "${TC_PREFIX}riscv-none-elf-gcc" &>/dev/null; then
    GCC="${TC_PREFIX}riscv-none-elf-gcc"
    OBJCOPY="${OBJCOPY:-${TC_PREFIX}riscv-none-elf-objcopy}"
  elif [[ -n "$TC_PREFIX" ]] && command -v "${TC_PREFIX}riscv32-unknown-elf-gcc" &>/dev/null; then
    GCC="${TC_PREFIX}riscv32-unknown-elf-gcc"
    OBJCOPY="${OBJCOPY:-${TC_PREFIX}riscv32-unknown-elf-objcopy}"
  elif command -v riscv-none-elf-gcc &>/dev/null; then
    GCC="riscv-none-elf-gcc"
    OBJCOPY="${OBJCOPY:-riscv-none-elf-objcopy}"
  elif command -v riscv32-unknown-elf-gcc &>/dev/null; then
    GCC="riscv32-unknown-elf-gcc"
    OBJCOPY="${OBJCOPY:-riscv32-unknown-elf-objcopy}"
  else
    echo "ERROR: RISC-V GCC toolchain not found." >&2
    echo "Please add riscv-none-elf-gcc or riscv32-unknown-elf-gcc to PATH, or set RISCV_TC or GCC." >&2
    exit 1
  fi
fi

if [[ -z "$OBJCOPY" ]]; then
  OBJCOPY="${GCC%-gcc}-objcopy"
fi

RUNS="${1:-500000}"
LDSCRIPT="${LDSCRIPT:-link.ld}"

FLAGS="-O2 -march=rv32imc -mabi=ilp32 -nostartfiles -fno-pic -Wl,--no-relax"
INCLUDES="-I."

echo "Compiling Dhrystone for Gandiva (${RUNS} runs)..."

"$GCC" $FLAGS $INCLUDES -T "$LDSCRIPT" \
    -DNUMBER_OF_RUNS="${RUNS}" \
    -DCLK_FREQ_HZ=50000000 \
    start.S \
    dhry_1.c \
    dhry_2.c \
    dhry_port.c \
    -o dhrystone.elf

echo "Generating hex..."
"$OBJCOPY" -O binary dhrystone.elf dhrystone.bin
python3 ../../sw/bin2hex.py dhrystone.bin dhrystone.hex
echo "Done. dhrystone.hex is ready."
