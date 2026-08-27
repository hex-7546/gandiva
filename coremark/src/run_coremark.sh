#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Ensure the hex file exists before running
if [ ! -f coremark/coremark.hex ]; then
    echo "ERROR: coremark.hex not found. Please run coremark/build_coremark.sh first."
    exit 1
fi

echo "Running CoreMark on Gandiva simulation..."
vvp sim/tb_gandiva +IMEM=coremark/coremark.hex
