// ============================================================================
// gandiva_trigger.sv — RISC-V Debug hardware trigger unit (Sdtrig / mcontrol6).
//
// A gandiva-owned leaf cell implementing a small trigger register file exposed
// through the standard debug CSRs:
//   tselect (0x7A0) — selects which trigger tdata1/tdata2 address.
//   tdata1  (0x7A1) — per-trigger control; here type=6 (mcontrol6).
//   tdata2  (0x7A2) — the match value (a PC for execute, an address for l/s).
//   tinfo   (0x7A4) — read-only: bitmask of supported trigger types (bit 6).
//
// Two trigger kinds are supported (Ibex/SiFive class), selectable per-trigger:
//   * EXECUTE (PC-match) breakpoint  — mcontrol6.execute=1, matches instr PC.
//   * LOAD/STORE (address-match) watchpoint — mcontrol6.load/store=1, matches
//     the data-access address.
// A match with action=1 requests entry to Debug Mode (like an ebreak-to-debug);
// with action=0 it raises a breakpoint exception. This cell only produces the
// match signals + holds the CSR state; the core turns a match into debug entry
// or a trap. State is entirely local to this module — the gandiva_csr leaf
// cell is never extended for it.
//
// mcontrol6 (tdata1) layout we model (RV32, type in [31:28]):
//   [31:28] type   = 4'h6  (mcontrol6)
//   [27]    dmode  (only writable from debug mode — modeled as freely writable)
//   [21]    hit0   (sticky: set when this trigger has fired)
//   [19]    select (0 = match on address/PC value; 1 = data — unsupported here)
//   [18:16] size   (0 = any)
//   [15:12] action (0 = raise breakpoint exception, 1 = enter debug mode)
//   [11]    chain  (unsupported; 0)
//   [10:7]  match  (0 = equal — the only mode we implement)
//   [6]     m      (match in machine mode)
//   [2]     execute (fire on instruction fetch/execute of tdata2)
//   [1]     store   (fire on store to tdata2)
//   [0]     load    (fire on load from tdata2)
// ============================================================================
`include "gandiva_pkg.sv"

module gandiva_trigger
  import gandiva_pkg::*;
#(
  parameter int unsigned NTRIG = 2   // number of trigger slots
)(
  input  logic              clk,
  input  logic              rst,

  // ---- CSR access (from the core's EX/debug CSR path) ----------------------
  input  logic [11:0]       csr_addr,     // 0x7A0..0x7A4 when is_trig_csr
  output logic [XLEN-1:0]   csr_rdata,    // trigger CSR read data
  input  logic              csr_we,       // write-enable (already qualified valid)
  input  logic [XLEN-1:0]   csr_wdata,

  // ---- live match query (combinational) ------------------------------------
  input  logic              chk_valid,    // an instruction is present to check
  input  logic [XLEN-1:0]   chk_pc,       // its PC (for execute match)
  input  logic              chk_mem_re,   // it is a load  (for load match)
  input  logic              chk_mem_we,   // it is a store (for store match)
  input  logic [XLEN-1:0]   chk_mem_addr, // its data address (for l/s match)

  output logic              trig_exec,    // an execute (PC) trigger matched
  output logic              trig_ldst,    // a load/store (addr) trigger matched
  output logic              trig_action,  // matched trigger's action (1=debug,0=exc)
  output logic [XLEN-1:0]   trig_tval,    // faulting PC/address (for mtval / dpc note)
  output logic [NTRIG-1:0]  trig_fire_mask, // which slots matched this cycle

  // hit strobe: pulse the slot index that fired so its sticky hit bit is set
  input  logic              hit_set,      // core asserts when a match is acted on
  input  logic [NTRIG-1:0]  hit_mask      // which slots fired this cycle
);
  localparam logic [3:0] TTYPE_MCONTROL6 = 4'h6;
  localparam logic [3:0] TTYPE_DISABLED  = 4'h0;

  // ---- register file --------------------------------------------------------
  logic [$clog2(NTRIG)-1:0] tselect;
  logic [XLEN-1:0]          tdata1 [0:NTRIG-1];
  logic [XLEN-1:0]          tdata2 [0:NTRIG-1];
  integer ti;

  // per-slot decoded control (from tdata1)
  // (kept as functions of the array so the match logic below is readable)
  function automatic logic slot_enabled(input [XLEN-1:0] d1);
    slot_enabled = (d1[31:28] == TTYPE_MCONTROL6) && d1[6]; // type match + M-mode
  endfunction
  function automatic logic slot_exec (input [XLEN-1:0] d1); slot_exec = d1[2]; endfunction
  function automatic logic slot_store(input [XLEN-1:0] d1); slot_store= d1[1]; endfunction
  function automatic logic slot_load (input [XLEN-1:0] d1); slot_load = d1[0]; endfunction
  function automatic logic slot_action(input [XLEN-1:0] d1); slot_action = d1[12]; endfunction

  // ---- CSR read -------------------------------------------------------------
  localparam logic [11:0] CSR_TSELECT = 12'h7A0;
  localparam logic [11:0] CSR_TDATA1  = 12'h7A1;
  localparam logic [11:0] CSR_TDATA2  = 12'h7A2;
  localparam logic [11:0] CSR_TINFO   = 12'h7A4;

  always_comb begin
    unique case (csr_addr)
      CSR_TSELECT: csr_rdata = {{(XLEN-$clog2(NTRIG)){1'b0}}, tselect};
      CSR_TDATA1 : csr_rdata = tdata1[tselect];
      CSR_TDATA2 : csr_rdata = tdata2[tselect];
      CSR_TINFO  : csr_rdata = 32'h0000_0040 | 32'h0000_0001; // type6 supported + "info valid"
      default    : csr_rdata = '0;
    endcase
  end

  // ---- combinational match over all slots ----------------------------------
  // Equal-match only. Execute matches the fetched instruction PC; load/store
  // matches the (word) data address. Priority: lowest slot index wins.
  logic exec_hit, ldst_hit, act_hit;
  logic [XLEN-1:0] tval_hit;
  logic [NTRIG-1:0] fire_mask;
  always_comb begin
    exec_hit = 1'b0; ldst_hit = 1'b0; act_hit = 1'b0; tval_hit = '0;
    fire_mask = '0;
    for (ti = 0; ti < NTRIG; ti = ti + 1) begin
      if (chk_valid && slot_enabled(tdata1[ti])) begin
        // execute (PC) match
        if (slot_exec(tdata1[ti]) && (chk_pc == tdata2[ti])) begin
          if (!exec_hit && !ldst_hit) begin
            exec_hit = 1'b1; act_hit = slot_action(tdata1[ti]); tval_hit = chk_pc;
          end
          fire_mask[ti] = 1'b1;
        end
        // load/store (address) match
        if (((slot_load(tdata1[ti]) && chk_mem_re) ||
             (slot_store(tdata1[ti]) && chk_mem_we)) &&
            (chk_mem_addr == tdata2[ti])) begin
          if (!exec_hit && !ldst_hit) begin
            ldst_hit = 1'b1; act_hit = slot_action(tdata1[ti]); tval_hit = chk_mem_addr;
          end
          fire_mask[ti] = 1'b1;
        end
      end
    end
  end

  assign trig_exec      = exec_hit;
  assign trig_ldst      = ldst_hit;
  assign trig_action    = act_hit;
  assign trig_tval      = tval_hit;
  assign trig_fire_mask = fire_mask;

  // ---- write / sticky-hit ---------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst) begin
      tselect <= '0;
      for (ti = 0; ti < NTRIG; ti = ti + 1) begin
        tdata1[ti] <= {TTYPE_MCONTROL6, 28'd0}; // type=6, all disabled
        tdata2[ti] <= '0;
      end
    end else begin
      if (csr_we) begin
        unique case (csr_addr)
          CSR_TSELECT: if (csr_wdata < NTRIG) tselect <= csr_wdata[$clog2(NTRIG)-1:0];
          CSR_TDATA1 : begin
            // force type field to mcontrol6; keep control bits; clear reserved.
            tdata1[tselect] <= {TTYPE_MCONTROL6, csr_wdata[27:0]};
          end
          CSR_TDATA2 : tdata2[tselect] <= csr_wdata;
          default    : ;
        endcase
      end
      // sticky hit0 bit (bit 21) set when a slot fires
      if (hit_set) begin
        for (ti = 0; ti < NTRIG; ti = ti + 1)
          if (hit_mask[ti]) tdata1[ti][21] <= 1'b1;
      end
    end
  end
endmodule
