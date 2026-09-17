#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

TC_PREFIX="${RISCV_TC:+$RISCV_TC/}"
GCC="${GCC:-}"
OBJCOPY="${OBJCOPY:-}"

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
    echo "ERROR: RISC-V GCC toolchain not found!" >&2
    echo "Please add riscv-none-elf-gcc or riscv32-unknown-elf-gcc to PATH, or set RISCV_TC or GCC." >&2
    exit 1
  fi
fi

if [[ -z "$OBJCOPY" ]]; then
  OBJCOPY="${GCC%-gcc}-objcopy"
fi

FLAGS="-O2 -march=rv32imc -mabi=ilp32 -nostartfiles -fno-pic -Wl,--no-relax"
INCLUDES="-I. -Ibarebones"

echo "Compiling CoreMark for Gandiva..."

ITERATIONS="${1:-1}"

LDSCRIPT="${LDSCRIPT:-link.ld}"

"$GCC" $FLAGS $INCLUDES -T "$LDSCRIPT" \
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
