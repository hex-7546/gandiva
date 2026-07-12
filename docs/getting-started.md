# Getting Started

## Prerequisites

- **Icarus Verilog 12+** (`iverilog` / `vvp`) — the simulator.
- **Python 3.10+** — the test-program builders and the golden co-simulation
  driver.
- *(optional)* a **RISC-V GCC** toolchain (`riscv-none-elf-gcc`) to rebuild the
  assembly programs / the FreeRTOS demo; prebuilt `.hex` images are included so
  this is not required to run the core tests.
- *(optional)* **Vivado** for the FPGA flows.

## Build and run the smoke test

=== "Linux / macOS"

    ```bash
    ./build.sh
    ```

=== "Windows (PowerShell)"

    ```powershell
    .\build.ps1
    ```

Expected output:

```
[TB] Loading IMEM from: programs/build/smoke.hex
[TB] Reset released
[TB] tohost write: 0x00000001 ...
[TB] PASS
```

## The other test targets

| Command | What it does |
|---------|--------------|
| `build.sh` (default) | compile the core + SoC, run the self-checking smoke test |
| `build.sh cosim` | run smoke, then lock-step co-simulate against the golden RV32IM ISA model |
| `build.sh rvfi` | build the RVFI (RISC-V Formal Interface) self-check |
| `build.sh debug` | JTAG / Debug-Module self-check (halt / GPR access / resume / single-step) |
| `build.sh trigger` | hardware breakpoint / watchpoint self-check |
| `build.sh axi` | AXI4-Lite master bridge, exercised against a slave-memory BFM |
| `build.sh priv` | `SECURE` config: M/U/N privilege + PMP directed tests |
| `build.sh rtos` | build and run the FreeRTOS preemptive multitasking demo |
| `build.sh clean` | remove build artifacts |

## Next steps

- [Architecture](architecture.md) — the pipeline and datapath.
- [Instruction Set](isa.md) — supported extensions.
- [Verification](verification.md) — how the core is checked.
