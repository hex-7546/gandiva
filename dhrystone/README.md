# Dhrystone 2.1 — Gandiva Benchmark Port

This directory contains a bare-metal **Dhrystone 2.1** port for the **Gandiva
RV32IMC** processor. Two run flows are provided:

| Flow | Script | Target |
|------|--------|--------|
| RTL simulation | `run_dhrystone.sh` | Verilator `tb_gandiva` sim |
| FPGA hardware | `run_dhrystone_arty_a7.sh` | Digilent Arty A7-100T |

Both flows default to **2 000 000 iterations** — the industry-standard run
count used by ARM, EEMBC, and CPU vendors to ensure steady-state cache
behaviour and statistically comparable DMIPS figures.

---

## Directory layout

```
dhrystone/
├── run_dhrystone.sh            Simulation run script (Verilator)
├── run_dhrystone_arty_a7.sh    FPGA run script (Arty A7-100T)
└── src/
    ├── dhry.h                  Dhrystone 2.1 header (unmodified)
    ├── dhry_1.c                Dhrystone 2.1 main body (unmodified)
    ├── dhry_2.c                Dhrystone 2.1 procedures (unmodified)
    ├── dhry_port.c             Bare-metal RISC-V port (UART + mtime timer)
    ├── start.S                 CRT0: stack setup, BSS clear, _start → main
    ├── link.ld                 Linker script (IMEM @ 0x0, DRAM @ 0x8000_0000)
    └── build_dhrystone.sh      Low-level compiler driver (called by run scripts)
```

---

## Prerequisites

| Tool | Purpose | Notes |
|------|---------|-------|
| `riscv-none-elf-gcc` | Compile firmware | Set `RISCV_TC` or `GCC` env var if not in `PATH` |
| Verilator `tb_gandiva` | Simulation | Build with `./build.sh` from repo root |
| Vivado | FPGA synthesis | Required for FPGA flow; source `settings64.sh` |
| `openFPGALoader` | Board programming | Preferred; auto-detected over Vivado hw_server |
| `pyserial` | UART capture | `pip install pyserial`; stty fallback if absent |

---

## Simulation flow

The simulation script compiles the firmware and runs it through the Verilator
`tb_gandiva` model in one command. Results are printed to stdout — no physical
hardware required.

### Quick start

```bash
# Industry-standard 2 000 000 iterations (default)
./run_dhrystone.sh

# Custom iteration count
./run_dhrystone.sh 5000000
```

### How it works

1. Calls `src/build_dhrystone.sh <RUNS>` which cross-compiles with
   `-DNUMBER_OF_RUNS=<N> -DCLK_FREQ_HZ=50000000 -O2 -march=rv32imc`.
2. Converts the ELF to a `$readmemh`-compatible hex via `sw/bin2hex.py`.
3. Launches `../sim/tb_gandiva +IMEM=src/dhrystone.hex`.

> **Note:** Make sure `../sim/tb_gandiva` exists. Build it from the repo root
> with `./build.sh` before running the simulation.

### Expected simulation output

```
Dhrystone Benchmark, Version 2.1 (Language: C)
Dhrystone(1,1)
...
Microseconds for one run through Dhrystone:    X.X
Dhrystones per Second:                     XXXXXX
DMIPS:                                       XXX.X
DMIPS/MHz:                                    X.XX
```

---

## FPGA flow — Digilent Arty A7-100T

The FPGA script compiles Dhrystone firmware at **100 MHz** (the Arty A7 board
clock), re-synthesises the bitstream with Vivado, programs the board, and
captures the DMIPS result over UART.

### Board connections

| Signal | Pin | Description |
|--------|-----|-------------|
| `CLK100` | E3 | 100 MHz onboard oscillator |
| `ck_rst` | C2 | Active-low reset (pushbutton) |
| `uart_txd_in` | A9 | UART RX into board |
| `uart_rxd_out` | D10 | UART TX out of board |
| JTAG | USB micro-B | Programming via FTDI FT2232H |

UART settings: **115200-8N1**. On Linux the UART device is typically
`/dev/ttyUSB1` (the FT2232H exposes two virtual COM ports; `ttyUSB0` is JTAG,
`ttyUSB1` is UART).

### Quick start

```bash
# Full run (default — industry standard 2M iterations)
./run_dhrystone_arty_a7.sh

# Already have a bitstream, just re-flash and capture
./run_dhrystone_arty_a7.sh --no-synth

# Custom run count or UART device
./run_dhrystone_arty_a7.sh --runs 5000000 --uart-dev /dev/ttyUSB0

# Build only (no board)
./run_dhrystone_arty_a7.sh --no-program
```

### All options

```
--runs N          Number of Dhrystone iterations  (default: 2000000)
--build-dir DIR   Vivado build output directory   (default: ../fpga/arty_a7/build)
--no-synth        Skip re-synthesis; use existing bitstream
--no-program      Skip board programming (just build firmware + bitstream)
--programmer TOOL openFPGALoader | vivado          (default: auto-detect)
--uart-dev DEV    UART device for result capture  (default: /dev/ttyUSB1)
--baud RATE       UART baud rate                  (default: 115200)
--timeout SECS    Seconds to wait for UART output (default: 300)
```

### How it works

1. **Compile** — cross-compiles Dhrystone with `-DCLK_FREQ_HZ=100000000` so
   the firmware reports correct DMIPS/MHz for the 100 MHz board clock.
2. **Convert** — generates `fpga/arty_a7/build/firmware.mem`
   (`$readmemh`, one 32-bit word per line) via `sw/bin2hex.py`.
3. **Synthesise** — runs `fpga/arty_a7/gandiva_arty_a7.tcl` in Vivado batch
   mode; the TCL picks up the new `firmware.mem` automatically.
4. **Program** — uses `openFPGALoader --board arty_a7_100t` (preferred) or
   Vivado `program_hw_devices` (fallback).
5. **Capture** — opens the UART port with `pyserial`, prints all output, and
   stops automatically when the `DMIPS` result line appears.

### Expected FPGA output

```
Dhrystone Benchmark, Version 2.1 (Language: C)
Dhrystone(1,1)
...
Microseconds for one run through Dhrystone:    X.X
Dhrystones per Second:                     XXXXXX
DMIPS:                                       XXX.X
DMIPS/MHz:                                    X.XX
```

> **Expected figures:** RV32IMC at -O2 and 100 MHz typically achieves
> **~1.0–1.3 DMIPS/MHz**, giving **100–130 DMIPS** total on the Arty A7.

---

## Why 2 000 000 runs?

The Dhrystone standard (and ARM's own methodology) mandates enough iterations
that the working set fits entirely in cache and no cold-start effects inflate
the score. The widely-cited threshold is **2 × 10⁶**:

- Below ~100 k runs the timer resolution dominates and scores are meaningless.
- Between 100 k–500 k runs, cache warm-up skew is still visible.
- At **2 000 000** the benchmark is in steady state and results are directly
  comparable to published ARM Cortex-M / Cortex-A figures.

To override, pass `--runs N` (FPGA) or the first positional argument (sim).

---

## Porting notes

`src/dhry_port.c` provides the three hooks Dhrystone 2.1 requires:

| Symbol | Implementation |
|--------|---------------|
| `uart_putc(char)` | Polls `0x1000_0000` TX-busy bit, then writes |
| `dhr_printf(fmt, …)` | Minimal `%d %u %x %c %s` printf over UART |
| `read_mtime()` | Reads `mtime[31:0]` from CLINT at `0x0200_BFF8` |

The firmware computes elapsed cycles as `mtime_end − mtime_start` (mtime ticks
at `CLK_FREQ_HZ` in the Gandiva SoC) and derives DMIPS/MHz from there.
