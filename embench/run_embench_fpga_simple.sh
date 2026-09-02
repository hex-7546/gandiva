#!/usr/bin/env bash
# run_embench_fpga_simple.sh — Program pre-built bitstreams and capture UART results.
#
# Usage:  ./run_embench_fpga_simple.sh
#
# Prerequisites: bitstreams must already exist in fpga/arty_a7/build/bench_*/
set -euo pipefail
cd "$(dirname "$0")"

if [ -f "venv/bin/activate" ]; then
    source venv/bin/activate
    if ! python3 -c "import serial" &>/dev/null; then
        pip install pyserial
    fi
fi

SERIAL_PORT="${SERIAL_PORT:-/dev/ttyUSB1}"
FPGA_BUILD="$(realpath ../fpga/arty_a7/build)"

echo "Serial port: $SERIAL_PORT"
echo ""

CYCLE_COUNTS=()
BENCH_NAMES=()
FAILED=()

for bench_dir in "${FPGA_BUILD}"/bench_*/; do
    bench=$(basename "$bench_dir" | sed 's/^bench_//')
    bitstream="${bench_dir}/gandiva_arty_a7.bit"

    if [ ! -f "$bitstream" ]; then
        echo "--- ${bench} --- SKIP (no bitstream)"
        FAILED+=("$bench")
        continue
    fi

    echo "--- ${bench} ---"

    # Start pyserial listener BEFORE programming
    tmpout=$(mktemp)
    done_flag=$(mktemp)
    rm -f "$done_flag"

    python3 - "$SERIAL_PORT" "115200" "30" "$tmpout" "$done_flag" <<'PYEOF' &
import serial, sys, time
dev, baud, tmax = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
log_path, done_flag = sys.argv[4], sys.argv[5]
t0 = time.time()
buf = b""
found = False
with open(log_path, "wb") as fout:
    while time.time() - t0 < tmax:
        try:
            with serial.Serial(dev, baud, timeout=1) as ser:
                while time.time() - t0 < tmax:
                    chunk = ser.read(256)
                    if chunk:
                        fout.write(chunk); fout.flush()
                        buf += chunk
                        if b"RET=" in buf and b"CYCLES=" in buf:
                            found = True
                            time.sleep(0.2)
                            remainder = ser.read(1024)
                            if remainder:
                                fout.write(remainder)
                            break
            if found:
                break
        except Exception:
            time.sleep(0.5)
if found:
    open(done_flag, "w").close()
PYEOF
    PY_PID=$!
    sleep 0.5

    # Program FPGA
    openFPGALoader -b arty_a7_100t "$bitstream" 2>/dev/null \
        || { echo "  openFPGALoader failed, skipping."; kill $PY_PID 2>/dev/null; wait $PY_PID 2>/dev/null || true; rm -f "$tmpout" "$done_flag"; FAILED+=("$bench"); continue; }

    # Wait for listener
    wait $PY_PID 2>/dev/null || true

    serial_output=$(cat "$tmpout" 2>/dev/null || true)
    rm -f "$tmpout"

    if [ -f "$done_flag" ]; then
        rm -f "$done_flag"
        ret=$(echo "$serial_output" | grep -oP 'RET=\K\d+' | tail -1 || true)
        cycles=$(echo "$serial_output" | grep -oP 'CYCLES=\K\d+' | tail -1 || true)
        if [ -n "$ret" ] && [ -n "$cycles" ]; then
            printf "  %-24s | ret=%-3s | cycles=%s\n" "$bench" "$ret" "$cycles"
            CYCLE_COUNTS+=("$cycles")
            BENCH_NAMES+=("$bench")
            continue
        fi
    fi

    rm -f "$done_flag"
    echo "  WARNING: No valid output (timeout)."
    FAILED+=("$bench")
done

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  Embench IoT — FPGA Results (Gandiva @ 25 MHz)"
echo "============================================================"
printf "  %-24s | %15s\n" "Benchmark" "Cycles"
printf "  %-24s | %15s\n" "------------------------" "---------------"
for i in "${!BENCH_NAMES[@]}"; do
    printf "  %-24s | %15s\n" "${BENCH_NAMES[$i]}" "${CYCLE_COUNTS[$i]}"
done

if [ ${#CYCLE_COUNTS[@]} -gt 0 ]; then
    geomean=$(printf '%s\n' "${CYCLE_COUNTS[@]}" | \
        awk 'BEGIN{s=0;n=0} {s+=log($1);n++} END{printf "%d", exp(s/n)}')
    printf "  %-24s | %15s\n" "------------------------" "---------------"
    printf "  %-24s | %15d\n" "Geometric mean" "$geomean"
fi

if [ ${#FAILED[@]} -gt 0 ]; then
    echo ""
    echo "  Failed benchmarks: ${FAILED[*]}"
fi
echo "============================================================"
