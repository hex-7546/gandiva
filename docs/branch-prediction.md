# Branch Prediction

Gandiva has a **dynamic branch predictor** in the fetch stage. In a 5-stage
pipeline a taken branch otherwise costs a multi-cycle bubble, so prediction is a
major contributor to the core's throughput.

## Components

- **BTB — Branch Target Buffer.** A direct-mapped table that remembers the
  targets of previously-taken control-flow instructions, so the target is known
  in the fetch stage. The index is **halfword-granular** (it includes `pc[1]`)
  so compressed (16-bit) instructions do not alias in the BTB.
- **gshare direction predictor.** A table of 2-bit saturating counters indexed
  by the fetch PC XOR-ed with a global branch-history register, predicting
  taken / not-taken for conditional branches.
- **RAS — Return Address Stack.** A small stack pushed on calls
  (`jal`/`jalr` writing `x1`/`x5`) and popped on returns, so function returns
  are predicted accurately without polluting the BTB.

## Operation

On each fetch, the predictor produces a next-PC. A predicted-taken branch
redirects the front end. When the branch actually resolves in the execute stage:

- a **correct** prediction costs nothing — the pipeline flows;
- a **misprediction** flushes the wrongly-fetched instructions, redirects the
  front end to the correct PC, and updates the predictor tables and global
  history.

Prediction is a pure performance optimisation: mispredicts are always corrected,
so architectural results are identical with or without the predictor.

## Verification

The predictor is exercised by the smoke and CoreMark workloads and is covered by
the golden-model co-simulation and the RVFI self-check — the committed
instruction stream is identical to the golden model regardless of prediction
outcomes. See [Verification](verification.md).
