#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
echo "Building CoreMark for simulation (1000 iterations)..."
./src/build_coremark.sh 10
echo "Running CoreMark on Gandiva simulation..."
../sim/tb_gandiva +IMEM=src/coremark.hex
