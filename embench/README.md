# Embench IoT on Gandiva

This directory contains the integration scripts to run the official [Embench IoT](https://embench.org/) benchmark suite on the Gandiva RV32IMC processor. Embench is a modern, free, and open-source benchmark suite designed specifically for IoT-class embedded processors.

## Toolchain & Environment

The benchmark suite is compiled for a 32-bit RISC-V target with the `IMC` and `Zicsr` extensions (Integer, Multiply/Divide, Compressed, and CSR instructions).

- **Compiler**: RISC-V GCC Toolchain (xPack `riscv-none-elf-gcc` v13.2.0)
- **Simulator**: Verilator `v5.050`
- **Architecture**: `RV32IMC_Zicsr`
- **Compiler Flags**:
  
  ```bash
  -O2 -ffunction-sections -fdata-sections -march=rv32imc_zicsr -mabi=ilp32 -Wl,--gc-sections -static
  ```

  - `-O2`: Standard optimization level for performance without excessive code size bloat.
  - `-ffunction-sections` & `-fdata-sections`: Places each function and data item into its own section, allowing the linker to perform dead code elimination.
  - `-Wl,--gc-sections`: Instructs the linker to garbage collect unused sections, reducing final binary size.
  - `-march=rv32imc_zicsr`: Enables the base 32-bit integer instruction set, hardware multiply/divide (`M`), compressed 16-bit instructions (`C`), and CSR instructions (`Zicsr`).
  - `-mabi=ilp32`: Uses the standard 32-bit application binary interface.
  - `-static`: statically links the executables.

## Performance Results

Gandiva achieves a geometric mean score of **0.96 Embench Speed/MHz** across all 19 benchmarks. 

*Note: Embench Speed scores are relative to a baseline ARM Cortex-M4 execution.*

### Benchmark Breakdown

| Benchmark | Speed | Speed/MHz |
| --------- | ----- | --------- |
| aha-mont64 | 28.95 | 0.58 |
| crc32 | 44.23 | 0.88 |
| depthconv | 32.25 | 0.65 |
| edn | 35.09 | 0.70 |
| huffbench | 64.11 | 1.28 |
| matmult-int | 53.86 | 1.08 |
| md5sum | 63.93 | 1.28 |
| nettle-aes | 33.63 | 0.67 |
| nettle-sha256 | 31.68 | 0.63 |
| nsichneu | 49.74 | 0.99 |
| picojpeg | 42.15 | 0.84 |
| qrduino | 44.62 | 0.89 |
| sglib-combined | 50.99 | 1.02 |
| slre | 61.03 | 1.22 |
| statemate | 88.69 | 1.77 |
| tarfind | 78.91 | 1.58 |
| ud | 38.69 | 0.77 |
| wikisort | 97.91 | 1.96 |
| xgboost | 35.23 | 0.70 |
| **Geometric mean** | **48.14** | **0.96** |

### Simulation
- **Environment**: Verilator testbench (`tb_gandiva`)
- **Execution**: Embench standard Python test harness (`benchmark_speed.py`)
- **Geometric Mean (Relative Speed)**: 48.14
- **Geometric Mean (Speed/MHz)**: 0.96

### FPGA (Arty A7-100T)
- **Environment**: Bare-metal execution on the Arty A7 FPGA running at 25 MHz.
- **Execution**: Embench standard Python test harness (`benchmark_speed.py`)
- **Geometric Mean (Speed/MHz)**: 0.96
- **Note**: The core is identical on FPGA and simulation, meaning the IPC (Instructions Per Cycle) and resulting normalized Speed/MHz score are exactly identical. 

## Directory Layout

```
embench/
├── run_embench.sh                Main script to run the suite in simulation
├── run_embench_fpga.sh           Main script to run the suite on FPGA (via Embench framework)
├── run_embench_fpga_simple.sh    Fast, custom script to execute existing bitstreams sequentially
├── run_gandiva.py                Embench board-support target module for Simulation
├── run_gandiva_fpga.py           Embench board-support target module for FPGA
├── embench-iot/                  Git submodule containing the official Embench source
└── config/gandiva/               
    ├── boardsupport.c            Minimal implementations of UART putc and cycle counting
    ├── start.S                   CRT0 startup code (stack initialization, BSS clearing)
    └── link.ld                   Linker script mapping memory for Gandiva
```

## Usage

- To run the full benchmark suite in the Verilator simulation:
  ```bash
  ./run_embench.sh
  ```
- To run the full benchmark suite on the FPGA, compiling a Vivado bitstream for each benchmark on the fly:
  ```bash
  ./run_embench_fpga.sh
  ```
- To rapidly execute already-built bitstreams on the FPGA (if you just ran the command above and want to re-run the tests):
  ```bash
  ./run_embench_fpga_simple.sh
  ```
