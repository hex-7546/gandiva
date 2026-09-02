#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

ITERATIONS="${1:-1000}"  # 1000 iterations gives ~10+ seconds runtime for a valid score

echo "Building CoreMark for FPGA (${ITERATIONS} iterations)..."
LDSCRIPT="link_fpga.ld" ./src/build_coremark.sh "${ITERATIONS}"

BUILD_DIR="../fpga/arty_a7/build"
echo "Copying to FPGA build directory (${BUILD_DIR})..."
mkdir -p "${BUILD_DIR}"
cp src/coremark.hex "${BUILD_DIR}/firmware.mem"

echo "Running Vivado synthesis for Arty A7..."
cd ../fpga/arty_a7
if ! command -v vivado &> /dev/null; then
    echo "ERROR: vivado not found in PATH."
    echo "Please source your Vivado settings64.sh and try again."
    exit 1
fi

vivado -mode batch -source gandiva_arty_a7.tcl -tclargs build

echo "Done! The bitstream is available at fpga/arty_a7/build/gandiva_arty_a7.bit"

if command -v openFPGALoader &> /dev/null; then
    echo "Loading bitstream to Arty A7 using openFPGALoader..."
    # Digilent adapters typically use ttyUSB1 for UART and ttyUSB0 for JTAG
    SERIAL_PORT="/dev/ttyUSB1"
    if [ ! -e "$SERIAL_PORT" ]; then
        SERIAL_PORT="/dev/ttyUSB0"
    fi

    if [ -e "$SERIAL_PORT" ]; then
        echo "==========================================================="
        echo "Listening to serial output on $SERIAL_PORT (Press Ctrl+C to exit)..."
        echo "==========================================================="
        # Configure baud rate and raw mode before loading so we don't miss bytes
        stty -F $SERIAL_PORT 115200 cs8 -cstopb -parenb -icrnl
        # Start collecting serial output in background before programming
        cat $SERIAL_PORT &
        CAT_PID=$!
        openFPGALoader -b arty_a7_100t build/gandiva_arty_a7.bit
        # Wait for CoreMark to finish (~ITERATIONS/100 seconds at 100MHz + margin)
        wait $CAT_PID
    else
        echo "Could not find a serial port (/dev/ttyUSB0 or /dev/ttyUSB1)."
    fi
else
    echo "openFPGALoader not found. Skipping automatic FPGA programming."
fi
