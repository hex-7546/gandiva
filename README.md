# Gandiva

**Gandiva** is a clean, feature-complete **5-stage pipelined RV32IMAC** processor
core with the **`B`** bit-manipulation extension. It is designed as a *golden
reference*: every instruction it retires is checked, cycle by cycle, against an
independent RV32IM ISA model, so the RTL is known-correct rather than
merely plausible.

The core suits embedded and control-plane roles that want a well-verified,
mid-range in-order pipeline with a real branch predictor, standard bus
integration, memory protection, and debug — microcontrollers, real-time
controllers, secure elements, and FPGA soft cores.

---

## Highlights

- **ISA:** RV32IMAC — base integer, `M` multiply/divide, `A` atomics, and `C`
  compressed — plus the full **`B` bit-manipulation** set
  (`Zba`, `Zbb`, `Zbc`, `Zbs`), with the `Zicsr` control-and-status extension.
- **Microarchitecture:** classic **5-stage in-order** pipeline
  (**IF → ID → EX → MEM → WB**) with a full forwarding network and a single
  load-use interlock. One instruction retires per cycle in the common case.
- **Branch prediction:** dynamic **gshare + BTB + RAS** (return-address stack)
  front end with a halfword-granular, RVC-safe target buffer.
- **Privilege:** Machine mode always; the **`SECURE`** configuration adds a
  full **M / U / N** privilege split (including `N` user-level traps).
- **Memory protection:** optional **8-region PMP** with TOR / NA4 / NAPOT
  matching, R/W/X permissions, locking, and **ePMP** (`mseccfg`) semantics
  (`SECURE`).
- **Reliability:** register file with **SECDED ECC** (single-error correct,
  double-error detect) available in the `SECURE` configuration.
- **Debug triggers:** hardware **breakpoint / watchpoint** triggers
  (`mcontrol6`: execute PC-match and load/store address-match).
- **Traps & interrupts:** precise exceptions, `ECALL` / `EBREAK` / illegal-
  instruction handling, `MRET` / `URET`, and timer / software / external
  interrupt lines.
- **Misaligned access:** hardware support for misaligned loads and stores
  (handled as a two-beat memory sequence).
- **Debug:** RISC-V External Debug — a JTAG Transport Module plus a Debug
  Module (halt / resume, single-step, GPR & CSR access, system-bus access).
- **Buses:** a minimal native memory interface, plus an **AXI4-Lite** wrapper
  for drop-in integration into standard SoC fabrics.
- **RTOS:** a ready-to-run **FreeRTOS** port (preemptive multitasking driven by
  the SoC timer, with a UART console).
- **Verification:** cycle-accurate **co-simulation against a golden RV32IM ISA
  model**, an **RVFI** (RISC-V Formal Interface) port, a Debug-Module
  self-check, hardware-trigger and AXI self-checks, SECURE privilege/PMP tests,
  and a constrained-random flow.
- **Performance:** ~**2.91 CoreMark/MHz** (measured on RTL, no caches).

---

## Repository layout

```
gandiva/
├── rtl/                 core RTL
│   ├── gandiva_core.sv    5-stage pipeline + predictor + forwarding + Debug Module
│   ├── gandiva_soc.sv     minimal SoC (IMEM/DRAM, CLINT, UART, tohost)
│   ├── gandiva_axi_lite.sv  AXI4-Lite master bridge
│   ├── gandiva_uart.sv    UART console peripheral
│   ├── gandiva_trigger.sv Sdtrig hardware breakpoint/watchpoint triggers
│   └── common/            shared, pre-verified datapath leaf cells
│                          (ALU, multiply/divide, register file (+SECDED ECC),
│                           CSR file, immediate/branch units, decoder, RVC, PMP)
├── tb/                  testbenches (smoke, RVFI, debug, trigger, AXI, priv, RTOS, ECC)
├── tools/              golden ISA model + co-simulation driver
├── programs/           test-program builders
├── sw/                 assembly test programs & bring-up firmware
├── rtos/               FreeRTOS port (kernel, BSP, demo app)
├── fpga/               FPGA SoC + board constraints
├── docs/               documentation site (MkDocs)
├── build.sh            Linux/macOS build & test driver
└── build.ps1           Windows (PowerShell) build & test driver
```

## Requirements

- **Icarus Verilog 12+** (`iverilog` / `vvp`) for simulation
- **Python 3.10+** for the test-program builders and co-simulation
- *(optional)* a RISC-V GCC toolchain to rebuild the assembly programs / RTOS
- *(optional)* Vivado for the FPGA flows

## Build & test

Linux / macOS:

```bash
./build.sh          # compile + self-checking smoke test
./build.sh cosim    # + co-simulate against the golden ISA model
./build.sh rvfi     # RVFI (formal interface) self-check
./build.sh debug    # JTAG / Debug-Module self-check
./build.sh trigger  # hardware breakpoint / watchpoint self-check
./build.sh axi      # AXI4-Lite master bridge test
./build.sh priv     # SECURE config: M/U/N + PMP directed tests
./build.sh rtos     # FreeRTOS preemptive multitasking demo
./build.sh clean
```

Windows (PowerShell):

```powershell
.\build.ps1          # compile + smoke
.\build.ps1 cosim    # + golden co-simulation
.\build.ps1 rvfi
.\build.ps1 debug
```

Expected output for the default build:

```
[TB] PASS
[cosim] MATCH — 142 retires identical. RTL is ISA-correct.
```

## Configurations

Gandiva ships in two build-time configurations, selected by a parameter /
define:

| Configuration | Privilege | Memory protection | Register file | Use case |
|---------------|-----------|-------------------|---------------|----------|
| **Default**   | Machine only | — | plain | smallest footprint |
| **`SECURE`**  | Machine + User + N | 8-region PMP + ePMP | SECDED ECC | isolation & reliability |

Enable the secure configuration with the `SECURE` RTL parameter, or at compile
time with `-DGANDIVA_SECURE`.

## Documentation

Full documentation — architecture, ISA, memory map, CSRs, branch prediction,
security model, debug, bus integration, FPGA bring-up, and verification —
lives in [`docs/`](docs) and builds into a browsable site with
[MkDocs](https://www.mkdocs.org/):

```bash
pip install -r docs/requirements.txt
mkdocs serve      # http://127.0.0.1:8000
```

## License

Released under the [MIT License](LICENSE).
