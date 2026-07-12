# Verification

Gandiva is built as a *golden reference*, so verification is central: from quick
self-checking smoke tests to lock-step co-simulation against an independent
golden model and a formal interface.

## Golden co-simulation

`build.sh cosim` runs the smoke program on the RTL **and** on an independent
golden **RV32IM ISA model** (`tools/golden_rv32im.py`), comparing the committed
instruction stream retire-by-retire (PC, instruction, register writes). Any
divergence is reported at the first mismatching instruction.

```
[cosim] MATCH — 142 retires identical. RTL is ISA-correct.
```

## Self-checking tests

Every testbench is self-checking: it loads a program, runs it, and asserts an
expected result, signalling PASS/FAIL through the `tohost` handshake. The
directed programs (privilege, PMP, triggers, atomics, misaligned, bit-manip)
each pair a positive test with a **load-bearing negative control**, so a check
that silently stops working is caught.

## RVFI (RISC-V Formal Interface)

`build.sh rvfi` exposes an RVFI retirement port and checks the standard formal
invariants over a real run — instruction-order monotonicity, `x0` always zero,
PC continuity, and that the retired instruction matches memory. A corrupted-field
negative control confirms the checker actually fires.

## Debug, trigger, AXI, and SECURE self-checks

- `build.sh debug` — halt / GPR access / resume / single-step over the Debug
  Module.
- `build.sh trigger` — execute breakpoint + load/store watchpoint, with
  near-miss negative controls.
- `build.sh axi` — AXI4-Lite bridge integrity + `SLVERR` handling.
- `build.sh priv` — SECURE M/U/N privilege + PMP directed tests.

## Constrained-random testing

Beyond the directed suite, Gandiva is exercised by a constrained-random flow that
generates thousands of legal RV32IMAC programs and lock-steps each against the
golden model, catching corner cases the directed tests do not reach.

## RTOS integration test

`build.sh rtos` boots a real **FreeRTOS** image on the SoC and asserts a
multi-task transcript (queue + semaphore + preemptive timer tick), with a
negative control that disables the tick and confirms preemption is required.

## Performance

CoreMark, built for RV32IMAC and run on the RTL (no caches), measures
~**2.91 CoreMark/MHz**.
