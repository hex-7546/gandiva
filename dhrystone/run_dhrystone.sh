#!/usr/bin/env bash
# run_dhrystone.sh — build Dhrystone and run it on Gandiva simulation.
# Usage: ./run_dhrystone.sh [NUMBER_OF_RUNS]
set -euo pipefail
cd "$(dirname "$0")"

RUNS="${1:-2000000}"

echo "Building Dhrystone for simulation (${RUNS} runs)..."
./src/build_dhrystone.sh "${RUNS}"

echo "Running Dhrystone on Gandiva simulation..."
../sim/tb_gandiva +IMEM=src/dhrystone.hex
