# Architecture

Gandiva is a **5-stage, in-order, single-issue** pipeline — the classic
fetch / decode / execute / memory / writeback arrangement. One instruction is
fetched, executed, and retired per cycle in the common case; variable-latency
operations (multiply, divide, misaligned access, atomics) extend transparently
through a small set of stall conditions.

## Pipeline

```
   IF            ID              EX               MEM            WB
+--------+   +----------+   +-------------+   +-----------+   +-----------+
| fetch  |   | decode + |   | ALU / B /   |   | data      |   | writeback |
| +      |   | regfile  |   | branch /    |   | memory    |   | + commit  |
| predict|-->| read     |-->| mul/div/AMO |-->| access    |-->| + trap    |
| (BTB/  |   |          |   | (forwarded  |   |           |   |           |
|  gshare|<--+----------+---+  operands)  |   |           |   |           |
+--------+   redirect / flush              +--- forward ---+
```

- **IF — instruction fetch + predict.** Fetches the next instruction (32-bit or
  a 16-bit compressed form expanded by the RVC decoder) and consults the branch
  predictor for the next PC.
- **ID — decode + operand fetch.** Decodes the instruction and reads the
  register file.
- **EX — execute.** Performs the ALU / bit-manipulation / branch operation over
  operands resolved through the forwarding network; issues multiply/divide and
  drives the memory sequencer for atomics and misaligned accesses.
- **MEM — memory access.** Performs the data-memory access and PMP check.
- **WB — writeback + commit.** Writes the result back, handles CSRs, and
  resolves traps precisely.

## Hazard handling

Gandiva has no scoreboard — correctness comes from a compact set of mechanisms:

- **Forwarding network:** results are bypassed from later stages (EX / MEM / WB)
  back to the execute stage, so back-to-back dependent instructions do not
  stall.
- **Load-use interlock:** a single-cycle stall when an instruction consumes the
  result of an immediately preceding load (whose data is not ready until MEM).
- **Multi-cycle freeze:** multiply/divide, the two-beat misaligned access, and
  the atomic read-modify-write hold the pipeline until they complete.
- **Redirect / flush:** a branch misprediction (or a trap) flushes the wrongly
  fetched instructions and redirects the front end.

## Datapath leaf cells

The reusable datapath blocks live in
[`rtl/common/`](https://github.com/OR5-LABS/gandiva/tree/main/rtl/common): the
ALU (with the `B` bit-manipulation ops), the multiply/divide unit, the register
file (plus a SECDED-ECC variant), the CSR file, the immediate generator, the
branch comparator, the instruction decoder, the RVC expander, and the PMP
checker. The core, SoC, UART, AXI4-Lite bridge, and trigger unit live in `rtl/`;
the Debug Module is integrated in `gandiva_core.sv`.

See [Branch Prediction](branch-prediction.md) for the predictor, and
[Instruction Set](isa.md) for the supported ISA.
