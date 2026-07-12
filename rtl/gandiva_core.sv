// ============================================================================
// gandiva_core.sv — RV32IM, 5-stage in-order pipeline (IF ID EX MEM WB).
//
//   * Full forwarding (EX/MEM, MEM/WB -> EX), one-cycle load-use stall.
//   * Branches/jumps resolve in EX with a single redirect + 2-stage flush.
//   * Multi-cycle M-extension via gandiva_muldiv (front-end stalls on busy).
//   * Machine-mode traps: ECALL / EBREAK / illegal-instruction -> mtvec; MRET.
//   * Combinational instruction + data memory ports (functional reference;
//     the FPGA SoC wraps registered BRAM around these).
//   * Retire trace port for golden-model co-simulation.
//
// Authored from scratch — this is the clean, independently-verified baseline.
// ============================================================================
`include "gandiva_pkg.sv"

module gandiva_core
  import gandiva_pkg::*;
#(
  parameter logic [XLEN-1:0] RESET_PC = 32'h0000_0000,
  // Dynamic branch prediction (gshare BHT + BTB). Default ON — verified
  // ISA-correct: 51/51 official compliance, golden co-sim MATCH (142 retires),
  // and ~19% fewer cycles on benchmark.c (111,086 -> 89,914). The predictor is
  // halfword-granular (pc[1] in the index) so RVC 4-byte branches at 2-byte-
  // aligned PCs can't alias a neighbouring compressed instruction into a false
  // BTB hit. Set BPRED=0 for the static predict-not-taken baseline. See GAPS.md.
  parameter bit              BPRED     = 1,
  parameter int unsigned     BHT_BITS  = 8,   // 2^8 = 256 2-bit counters
  parameter int unsigned     BTB_BITS  = 6,   // 2^6 = 64 direct-mapped entries
  parameter int unsigned     GHR_BITS  = 8,   // global history length
  // SECURE=1 adds User privilege mode (misa U) + an 8-region PMP (M/U memory
  // isolation on the 5-stage fetch + load/store paths) + RV32 'N' user-level
  // traps (ustatus/uie/utvec/uepc/ucause/utval/uscratch/uip + URET + medeleg
  // delegation to U). Default 0 => the M-mode-only core is byte-identical, so
  // official compliance (run.sh gandiva) is unchanged. See the SECURE overlay
  // blocks in EX for the verified M/U/N + PMP path.
  parameter bit              SECURE    = 1'b0
)(
  input  logic              clk,
  input  logic              rst,

  // Instruction memory (combinational read)
  output logic [XLEN-1:0]   imem_addr,
  input  logic [XLEN-1:0]   imem_rdata,

  // Data memory (combinational read, synchronous write in SoC)
  output logic [XLEN-1:0]   dmem_addr,
  output logic              dmem_re,
  output logic              dmem_we,
  output logic [3:0]        dmem_be,
  output logic [XLEN-1:0]   dmem_wdata,
  input  logic [XLEN-1:0]   dmem_rdata,

  // interrupt pending lines (CLINT/PLIC); tie 0 if unused
  input  logic              irq_timer,
  input  logic              irq_soft,
  input  logic              irq_ext,

  // Retire trace (for co-simulation / debug)
  output logic              retire_valid,
  output logic [XLEN-1:0]   retire_pc,
  output logic [XLEN-1:0]   retire_instr,
  output logic              retire_rd_we,
  output logic [4:0]        retire_rd,
  output logic [XLEN-1:0]   retire_rd_val,
  // ---- RISC-V external debug (tie haltreq / ar_valid = 0 if no DM) ---------
  input  logic              dbg_haltreq,
  input  logic              dbg_resumereq,
  output logic              dbg_halted,
  input  logic              dbg_ar_valid,
  input  logic              dbg_ar_write,
  input  logic              dbg_ar_csr,
  input  logic [11:0]       dbg_ar_regno,
  input  logic [XLEN-1:0]   dbg_ar_wdata,
  output logic [XLEN-1:0]   dbg_ar_rdata,
  output logic              dbg_ar_done
`ifdef RISCV_FORMAL
  ,
  output logic              rvfi_valid,
  output logic [63:0]       rvfi_order,
  output logic [31:0]       rvfi_insn,
  output logic              rvfi_trap,
  output logic              rvfi_halt,
  output logic              rvfi_intr,
  output logic [1:0]        rvfi_mode,
  output logic [1:0]        rvfi_ixl,
  output logic [4:0]        rvfi_rs1_addr,
  output logic [4:0]        rvfi_rs2_addr,
  output logic [XLEN-1:0]   rvfi_rs1_rdata,
  output logic [XLEN-1:0]   rvfi_rs2_rdata,
  output logic [4:0]        rvfi_rd_addr,
  output logic [XLEN-1:0]   rvfi_rd_wdata,
  output logic [XLEN-1:0]   rvfi_pc_rdata,
  output logic [XLEN-1:0]   rvfi_pc_wdata,
  output logic [XLEN-1:0]   rvfi_mem_addr,
  output logic [3:0]        rvfi_mem_rmask,
  output logic [3:0]        rvfi_mem_wmask,
  output logic [XLEN-1:0]   rvfi_mem_rdata,
  output logic [XLEN-1:0]   rvfi_mem_wdata
`endif
);

  // ==========================================================================
  // Pipeline registers
  // ==========================================================================
  // IF/ID
  logic [XLEN-1:0] ifid_pc, ifid_instr;
  logic            ifid_valid;
  logic [2:0]      ifid_len, idex_len;   // RVC: instruction length (2 or 4)
  logic            straddle;             // mid 2-beat fetch of a straddling 32b instr
  logic [15:0]     strad_lo;
  // branch-prediction bits carried IF/ID -> ID/EX (describe the fetched instr)
  logic            ifid_pred_taken, idex_pred_taken;   // predicted taken at IF
  logic [XLEN-1:0] ifid_pred_target, idex_pred_target; // predicted next-PC
  logic [GHR_BITS-1:0] ifid_ghist, idex_ghist;         // GHR snapshot at fetch
  // ID/EX
  logic [XLEN-1:0] idex_pc, idex_instr, idex_imm, idex_rdata1, idex_rdata2;
  logic [4:0]      idex_rs1, idex_rs2, idex_rd;
  logic            idex_valid;
  alu_op_e         idex_alu_op;
  br_op_e          idex_br_op;
  md_op_e          idex_md_op;
  wb_sel_e         idex_wb_sel;
  logic            idex_use_pc, idex_use_imm;
  logic            idex_reg_we, idex_mem_re, idex_mem_we;
  logic [1:0]      idex_mem_width;       // 0=byte 1=half 2=word
  logic            idex_mem_unsigned;
  logic            idex_is_branch, idex_is_jal, idex_is_jalr;
  logic            idex_is_md, idex_is_csr;
  logic [2:0]      idex_csr_op;          // funct3 of SYSTEM
  logic [11:0]     idex_csr_addr;
  logic            idex_csr_imm_mode;
  logic [4:0]      idex_csr_uimm;
  logic            idex_is_ecall, idex_is_ebreak, idex_is_mret, idex_illegal;
  logic            idex_is_amo, idex_is_lr, idex_is_sc, idex_is_amo_rmw;
  logic [4:0]      idex_amo_f5;
  // EX/MEM
  logic [XLEN-1:0] exmem_pc, exmem_instr, exmem_result, exmem_store_data;
  logic [4:0]      exmem_rd;
  logic            exmem_valid, exmem_reg_we, exmem_mem_re, exmem_mem_we;
  logic [1:0]      exmem_mem_width;
  logic            exmem_mem_unsigned;
  logic [3:0]      exmem_be;
  logic [1:0]      exmem_addr_lo;
  logic            exmem_is_amo, exmem_is_lr, exmem_is_sc, exmem_is_amo_rmw;
  logic [4:0]      exmem_amo_f5;
  logic [XLEN-1:0] exmem_amo_addr, exmem_amo_b;   // AMO address (rs1) + operand (rs2)
  // MEM/WB
  logic [XLEN-1:0] memwb_pc, memwb_instr, memwb_result;
  logic [4:0]      memwb_rd;
  logic            memwb_valid, memwb_reg_we;
  // Zihpm: retired-branch-taken flag threaded EX->MEM->WB
  logic            exmem_br_taken, memwb_br_taken;

`ifdef RISCV_FORMAL
  // RVFI payload threaded EX->MEM->WB (describes the instruction retiring in WB)
  logic [4:0]  exmem_rs1, exmem_rs2, memwb_rs1, memwb_rs2;
  logic [31:0] exmem_rs1v, exmem_rs2v, memwb_rs1v, memwb_rs2v;
  logic [31:0] exmem_pcw, memwb_pcw, exmem_memaddr, memwb_memaddr;
  logic        exmem_trap, exmem_entry, memwb_trap, memwb_entry;
  logic        memwb_memre, memwb_memwe;
  logic [3:0]  memwb_wmask;
  logic [1:0]  memwb_mw, memwb_moff;
  logic [31:0] memwb_wdata, memwb_rdata;
  logic [63:0] rvfi_order_r;
  logic        rvfi_intr_r;
`endif

  // ==========================================================================
  // Control: stalls & redirects
  // ==========================================================================
  logic            redirect;
  logic [XLEN-1:0] redirect_target;
  logic            load_use_stall;
  // branch-predictor update (driven from EX; consumed by the predictor always_ff)
  logic                bp_upd_en;      // a branch/jal is resolving in EX
  logic                bp_upd_cond;    // it is a conditional branch (updates BHT)
  logic                bp_upd_taken;   // actual outcome (taken)
  logic [XLEN-1:0]     bp_upd_pc;      // the branch PC
  logic [XLEN-1:0]     bp_upd_target;  // the actual taken target
  logic                bp_upd_isjal;   // unconditional (JAL) — always taken in BTB
  logic [GHR_BITS-1:0] bp_upd_ghist;   // GHR snapshot used for the prediction
  logic            md_stall;
  logic            mem_beat_stall;   // MEM is doing the 1st of two misaligned beats
  logic            beat2;            // registered: MEM is driving the 2nd beat
  logic [31:0]     ld_w0;            // captured first word of a misaligned load

  // Front-end stalls whenever EX/MEM cannot accept a new instruction.
  wire             fe_stall = load_use_stall | md_stall | mem_beat_stall;
  // EX-stage side effects (redirect, csr write, trap, mret, irq) are suppressed
  // while EX is frozen — by a muldiv OR a misaligned-memory 2nd beat downstream.
  wire             ex_freeze = md_stall | mem_beat_stall;

  // ---- RISC-V external debug (drain-to-halt on this 5-stage pipeline) -------
  logic            dbg_mode;        // halted in debug mode
  logic            halt_req;        // halt requested; fetch frozen, pipe draining
  logic            step_active;     // resumed with step; halt after one fetch
  logic [XLEN-1:0] dpc, dscratch0;
  logic            dcsr_ebreakm, dcsr_step;
  logic [2:0]      dcsr_cause;
  logic            dbg_ar_busy, dpc_cap_valid;
  logic            dbg_ebrk_cause;   // captured cause: 1=ebreak else 0=trigger
  logic [XLEN-1:0] dpc_cap;
  assign dbg_halted = dbg_mode;
  wire ebreak_to_debug = idex_valid && idex_is_ebreak && dcsr_ebreakm && !dbg_mode; // in EX
  wire step_halt_now = step_active && ifid_valid && !dbg_mode;   // one instr now in ID
  // trig_to_debug: a hardware trigger (action=1) in EX wants to enter debug.
  // Declared as a net here and assigned near the trigger instance below.
  wire trig_to_debug;
  // any reason to squash the EX instruction and drain into debug entry.
  wire to_debug_now = ebreak_to_debug | trig_to_debug;
  wire dbg_freeze = dbg_mode | halt_req | (dbg_haltreq & ~dbg_mode) |
                    to_debug_now | step_halt_now;
  wire dbg_resume_now = dbg_mode & dbg_resumereq;
  wire pipe_drained = !ifid_valid && !idex_valid && !exmem_valid && !memwb_valid;
  wire        dbg_do     = dbg_mode && dbg_ar_valid && !dbg_ar_busy;
  wire        dbg_gpr_we = dbg_do && dbg_ar_write && !dbg_ar_csr;
  wire        dbg_csr_local = (dbg_ar_regno==12'h7b0)||(dbg_ar_regno==12'h7b1)||(dbg_ar_regno==12'h7b2);
  wire        dbg_csr_we = dbg_do && dbg_ar_write && dbg_ar_csr && !dbg_csr_local;
  wire [XLEN-1:0] dcsr_val = {4'd4, 12'd0, dcsr_ebreakm, 6'd0,
                              dcsr_cause, 3'd0, dcsr_step, 2'b11};

  // ==========================================================================
  // Dynamic branch predictor: gshare BHT (2-bit counters) + direct-mapped BTB.
  // Lookup is combinational at IF on the (RVC-expanded) fetched instruction;
  // update is at EX where the branch/jal already resolves. JALR is left
  // unpredicted (target comes from a register) and always resolves in EX.
  // ==========================================================================
  localparam int unsigned BHT_ENTRIES = (1 << BHT_BITS);
  localparam int unsigned BTB_ENTRIES = (1 << BTB_BITS);
  localparam int unsigned BTB_TAGW     = XLEN - BTB_BITS - 1;   // tag = pc[31:BTB_BITS+1]

  logic [1:0]           bht [0:BHT_ENTRIES-1];   // 2-bit saturating counters
  logic                 btb_valid [0:BTB_ENTRIES-1];
  logic [BTB_TAGW-1:0]  btb_tag   [0:BTB_ENTRIES-1];
  logic [XLEN-1:0]      btb_tgt   [0:BTB_ENTRIES-1];
  logic                 btb_isjal [0:BTB_ENTRIES-1];
  logic [GHR_BITS-1:0]  ghist;                    // global history register

  logic [XLEN-1:0]      pc;   // (defined here so predictor lookup can use it)

  // ---- IF-stage prediction lookup ------------------------------------------
  // gshare index: pc[BHT_BITS:1] XOR ghist (low bits). BTB index/tag on pc.
  // HALFWORD-GRANULAR indexing (bit 1 included): with RVC, a 4-byte branch can
  // sit at a 2-byte-aligned PC, so pc[1] MUST participate in the index — else a
  // neighbouring 2-byte non-branch at the same word aliases onto the branch's
  // BTB entry, gets a false hit, is predicted taken, and (being a non-branch)
  // is never resolved/corrected in EX → the pipeline diverges permanently.
  wire [BHT_BITS-1:0] bht_rd_idx = pc[BHT_BITS:1] ^ ghist[BHT_BITS-1:0];
  wire [BTB_BITS-1:0] btb_rd_idx = pc[BTB_BITS:1];
  wire [BTB_TAGW-1:0] btb_rd_tag = pc[XLEN-1:BTB_BITS+1];
  wire                btb_hit = BPRED && btb_valid[btb_rd_idx] &&
                                (btb_tag[btb_rd_idx] == btb_rd_tag);
  wire                bht_taken = bht[bht_rd_idx][1];   // MSB of 2-bit counter
  // Predict taken when the BTB has a target for this PC and either it's an
  // unconditional (JAL) entry or the BHT counter says taken.
  wire                predict_taken = btb_hit && (btb_isjal[btb_rd_idx] || bht_taken);
  wire [XLEN-1:0]     predict_target = btb_tgt[btb_rd_idx];

  // ==========================================================================
  // IF stage
  // ==========================================================================
  assign imem_addr = straddle ? ({pc[XLEN-1:2], 2'b00} + 32'd4) : pc;

  // RVC: decompress the halfword at PC; 32-bit instr at an odd halfword needs
  // a second fetch beat (straddle).
  wire [15:0] fetch_half = pc[1] ? imem_rdata[31:16] : imem_rdata[15:0];
  wire [31:0] c_instr32;
  wire        c_is_comp, c_illegal;
  gandiva_rvc u_rvc (.instr16(fetch_half), .instr32(c_instr32),
                     .is_compressed(c_is_comp), .decomp_illegal(c_illegal));
  wire        need_straddle = !c_is_comp && pc[1] && !straddle;
  wire [31:0] fetched_instr = straddle  ? {imem_rdata[15:0], strad_lo}
                            : c_is_comp ? (c_illegal ? 32'h0 : c_instr32)
                            : imem_rdata;
  wire [2:0]  fetched_len   = (straddle || !c_is_comp) ? 3'd4 : 3'd2;

  // ---- Return Address Stack (RAS) — predicts function returns (JALR ra) ------
  // The BTB can't predict register-indirect JALR targets, so every return used to
  // eat a full flush. The RAS pushes the return address on a call (rd = x1/x5) and
  // pops it on a return (JALR, rs1 = x1/x5, rd not a link reg), predicting the
  // return target at IF. Correctness-safe: EX always computes the real jalr_target
  // and corrects any misprediction, so a stale RAS only costs accuracy, never
  // correctness (the RAS pointer is intentionally NOT check-pointed on mispredict).
  localparam int unsigned RAS_N = 8, RAS_PW = 3;
  logic [XLEN-1:0]  ras [0:RAS_N-1];
  logic [RAS_PW-1:0] ras_ptr;          // next-free slot; top = ras_ptr-1
  logic [RAS_PW:0]   ras_cnt;          // occupancy (for validity)
  wire  [RAS_PW-1:0] ras_top_idx = ras_ptr - 1'b1;
  wire               ras_valid   = (ras_cnt != 0);
  wire [6:0] f_op  = fetched_instr[6:0];
  wire [4:0] f_rd  = fetched_instr[11:7];
  wire [4:0] f_rs1 = fetched_instr[19:15];
  wire f_rd_link   = (f_rd  == 5'd1) || (f_rd  == 5'd5);
  wire f_rs1_link  = (f_rs1 == 5'd1) || (f_rs1 == 5'd5);
  wire f_is_jalr   = (f_op == 7'b1100111);
  wire f_is_jal    = (f_op == 7'b1101111);
  wire f_is_ret    = BPRED && f_is_jalr && f_rs1_link && !f_rd_link;   // pop
  wire f_is_call   = BPRED && (f_is_jal || f_is_jalr) && f_rd_link;    // push
  // returns predict from the RAS top; everything else keeps the BTB/BHT prediction
  wire               ras_predict    = f_is_ret && ras_valid;
  wire               predict_taken_f  = ras_predict ? 1'b1 : predict_taken;
  wire [XLEN-1:0]    predict_target_f = ras_predict ? ras[ras_top_idx] : predict_target;

  // merged fetch (PC + IF/ID) with RVC straddle handling.
  // On a predicted-taken control-flow instr, the sequential fetch is steered to
  // the predicted target instead of pc+len (the branch itself still advances
  // into IF/ID; only the *next* fetch is speculative).
  always_ff @(posedge clk) begin
    if (rst) begin
      pc <= RESET_PC; ifid_valid <= 1'b0; ifid_pc <= '0; ifid_instr <= '0;
      ifid_len <= 3'd4; straddle <= 1'b0; strad_lo <= 16'h0;
      ifid_pred_taken <= 1'b0; ifid_pred_target <= '0; ifid_ghist <= '0;
      ras_ptr <= '0; ras_cnt <= '0;
    end else if (redirect) begin
      pc <= redirect_target; ifid_valid <= 1'b0; straddle <= 1'b0;
    end else if (dbg_resume_now) begin
      pc <= dpc; ifid_valid <= 1'b0; straddle <= 1'b0;       // resume: refetch at dpc
    end else if (dbg_freeze) begin
      ifid_valid <= 1'b0;                                     // halting/halted: stop fetch
    end else if (fe_stall) begin
      // hold (load-use or muldiv stall): keep pc, IF/ID and straddle state
    end else if (need_straddle) begin
      strad_lo <= imem_rdata[31:16]; straddle <= 1'b1; ifid_valid <= 1'b0;
    end else begin
      ifid_valid       <= 1'b1;
      ifid_pc          <= pc;
      ifid_instr       <= fetched_instr;
      ifid_len         <= fetched_len;
      ifid_pred_taken  <= predict_taken_f;
      ifid_pred_target <= predict_target_f;
      ifid_ghist       <= ghist;
      straddle         <= 1'b0;
      pc               <= predict_taken_f ? predict_target_f
                                          : (pc + {29'd0, fetched_len});
      // RAS maintenance (call pushes return addr, return pops). f_is_call and
      // f_is_ret are mutually exclusive (ret requires rd not a link reg).
      if (f_is_call) begin
        ras[ras_ptr] <= pc + {29'd0, fetched_len};
        ras_ptr <= ras_ptr + 1'b1;
        if (ras_cnt != RAS_N) ras_cnt <= ras_cnt + 1'b1;   // saturate
      end else if (f_is_ret && ras_valid) begin
        ras_ptr <= ras_ptr - 1'b1;
        ras_cnt <= ras_cnt - 1'b1;
      end
    end
  end

  // ==========================================================================
  // ID stage — decode + register read
  // ==========================================================================
  wire [6:0]  opcode = ifid_instr[6:0];
  wire [2:0]  funct3 = ifid_instr[14:12];
  wire [4:0]  rs1    = ifid_instr[19:15];
  wire [4:0]  rs2    = ifid_instr[24:20];
  wire [4:0]  rd     = ifid_instr[11:7];

  // immediate generator (shared leaf cell)
  logic [XLEN-1:0] imm_i, imm_s, imm_b, imm_u, imm_j, id_imm;
  gandiva_immgen u_imm (.instr(ifid_instr),
    .imm_i(imm_i), .imm_s(imm_s), .imm_b(imm_b), .imm_u(imm_u), .imm_j(imm_j));

  wire [11:0] sys_imm12 = ifid_instr[31:20];

  // regfile read
  logic [XLEN-1:0] rf_rdata1, rf_rdata2;
  logic            rf_we;
  logic [4:0]      rf_wa;
  logic [XLEN-1:0] rf_wd;

  // debug GPR access steals the idle read/write ports while halted
  wire [4:0]      rf_ra1_eff = (dbg_mode && dbg_ar_valid && !dbg_ar_csr)
                               ? dbg_ar_regno[4:0] : rs1;
  wire            rf_we_dbg  = dbg_gpr_we | rf_we;
  wire [4:0]      rf_wa_dbg  = dbg_gpr_we ? dbg_ar_regno[4:0] : rf_wa;
  wire [XLEN-1:0] rf_wd_dbg  = dbg_gpr_we ? dbg_ar_wdata      : rf_wd;
  gandiva_regfile u_rf (
    .clk(clk), .ra1(rf_ra1_eff), .ra2(rs2),
    .rd1(rf_rdata1), .rd2(rf_rdata2),
    .we(rf_we_dbg), .wa(rf_wa_dbg), .wd(rf_wd_dbg)
  );

  // ---- decoded control (combinational) ------------------------------------
  alu_op_e   d_alu_op;
  br_op_e    d_br_op;
  md_op_e    d_md_op;
  wb_sel_e   d_wb_sel;
  logic      d_use_pc, d_use_imm;
  logic      d_reg_we, d_mem_re, d_mem_we;
  logic [1:0] d_mem_width;
  logic      d_mem_unsigned;
  logic      d_is_branch, d_is_jal, d_is_jalr, d_is_md, d_is_csr;
  logic      d_is_ecall, d_is_ebreak, d_is_mret, d_illegal;
  logic      d_uses_rs2;

  gandiva_decode u_dec (
    .instr(ifid_instr), .imm_i(imm_i), .imm_s(imm_s), .imm_b(imm_b),
    .imm_u(imm_u), .imm_j(imm_j),
    .alu_op(d_alu_op), .br_op(d_br_op), .md_op(d_md_op), .wb_sel(d_wb_sel),
    .use_pc(d_use_pc), .use_imm(d_use_imm), .reg_we(d_reg_we),
    .mem_re(d_mem_re), .mem_we(d_mem_we), .mem_unsigned(d_mem_unsigned),
    .mem_width(d_mem_width), .is_branch(d_is_branch), .is_jal(d_is_jal),
    .is_jalr(d_is_jalr), .is_md(d_is_md), .is_csr(d_is_csr),
    .is_ecall(d_is_ecall), .is_ebreak(d_is_ebreak), .is_mret(d_is_mret),
    .illegal(d_illegal), .uses_rs2(d_uses_rs2), .id_imm(id_imm)
  );

  // ---- RV32 'A' (atomics) inline decode (gandiva_decode left untouched) -----
  // AMO opcode 0101111, funct3=010 (word). funct5 = instr[31:27] selects the op;
  // LR needs rs2==0. The address is rs1 (no immediate). rd gets the old memory.
  wire        is_amo     = (opcode==7'b0101111) && (funct3==3'b010);
  wire [4:0]  amo_f5     = ifid_instr[31:27];
  wire        is_lr      = is_amo && (amo_f5==5'b00010);   // LR.W
  wire        is_sc      = is_amo && (amo_f5==5'b00011);   // SC.W
  wire        is_amo_rmw = is_amo && !is_lr && !is_sc;      // AMO<op>.W
  wire        amo_valid  = is_amo &&
      ((amo_f5==5'b00010 && rs2==5'd0) ||                   // LR.W (rs2 must be 0)
       (amo_f5==5'b00011) || (amo_f5==5'b00001) ||          // SC / SWAP
       (amo_f5==5'b00000) || (amo_f5==5'b00100) ||          // ADD / XOR
       (amo_f5==5'b01100) || (amo_f5==5'b01000) ||          // AND / OR
       (amo_f5==5'b10000) || (amo_f5==5'b10100) ||          // MIN / MAX
       (amo_f5==5'b11000) || (amo_f5==5'b11100));           // MINU / MAXU
  // ---- RV32 'N' (user-level trap) URET, inline (gandiva_decode untouched) ----
  // URET = 0x00200073 (funct12=0x002, funct3=0). The shared decoder flags it
  // illegal (it only knows MRET); when SECURE the local N overlay in EX owns it,
  // so it must NOT be flagged illegal here. Non-SECURE => stays illegal.
  wire        is_uret_id  = SECURE && (ifid_instr == 32'h00200073);
  // a valid AMO (or, when SECURE, a URET) is not illegal even though the shared
  // base decoder flags it so.
  wire        illegal_eff = d_illegal && !amo_valid && !is_uret_id;

  // ---- load-use hazard ----------------------------------------------------
  // The instruction in EX is a load; the instruction in ID needs its result.
  wire id_needs_rs1 = (opcode != OP_LUI) && (opcode != OP_AUIPC) &&
                      (opcode != OP_JAL);
  // An AMO/LR/SC produces its rd only in MEM (like a load), so a dependent must
  // stall one cycle to forward from MEM/WB instead of the stale EX/MEM result.
  assign load_use_stall = idex_valid && (idex_mem_re || idex_is_amo) && (idex_rd != 5'd0) &&
                          ifid_valid &&
                          (((idex_rd == rs1) && id_needs_rs1) ||
                           ((idex_rd == rs2) && (d_uses_rs2 || is_amo)));

  // ==========================================================================
  // ID/EX register
  // ==========================================================================
  // A bubble is inserted on redirect, load-use stall, or when front-end
  // stalls for muldiv (EX holds, so feed a bubble downstream is handled in EX).
  wire id_bubble = redirect | load_use_stall;

  always_ff @(posedge clk) begin
    if (rst) begin
      idex_valid <= 1'b0;
    end else if (md_stall || mem_beat_stall) begin
      // hold ID/EX while muldiv runs or MEM does its 2nd misaligned beat
      idex_valid <= idex_valid;
    end else if (id_bubble || !ifid_valid) begin
      idex_valid <= 1'b0;
    end else begin
      idex_valid        <= 1'b1;
      idex_pc           <= ifid_pc;
      idex_len          <= ifid_len;
      idex_pred_taken   <= ifid_pred_taken;
      idex_pred_target  <= ifid_pred_target;
      idex_ghist        <= ifid_ghist;
      idex_instr        <= ifid_instr;
      idex_imm          <= id_imm;
      idex_rdata1       <= rf_rdata1;
      idex_rdata2       <= rf_rdata2;
      idex_rs1          <= rs1;
      idex_rs2          <= rs2;
      idex_rd           <= rd;
      idex_alu_op       <= d_alu_op;
      idex_br_op        <= d_br_op;
      idex_md_op        <= d_md_op;
      idex_wb_sel       <= d_wb_sel;
      idex_use_pc       <= d_use_pc;
      idex_use_imm      <= d_use_imm;
      idex_reg_we       <= d_reg_we || amo_valid;  // AMO/LR/SC all write rd
      idex_mem_re       <= d_mem_re;
      idex_mem_we       <= d_mem_we;
      idex_is_amo       <= amo_valid;
      idex_is_lr        <= is_lr;
      idex_is_sc        <= is_sc;
      idex_is_amo_rmw   <= is_amo_rmw;
      idex_amo_f5       <= amo_f5;
      idex_mem_width    <= d_mem_width;
      idex_mem_unsigned <= d_mem_unsigned;
      idex_is_branch    <= d_is_branch;
      idex_is_jal       <= d_is_jal;
      idex_is_jalr      <= d_is_jalr;
      idex_is_md        <= d_is_md;
      idex_is_csr       <= d_is_csr;
      idex_csr_op       <= funct3;
      idex_csr_addr     <= sys_imm12;
      idex_csr_imm_mode <= funct3[2];
      idex_csr_uimm     <= rs1;
      idex_is_ecall     <= d_is_ecall;
      idex_is_ebreak    <= d_is_ebreak;
      idex_is_mret      <= d_is_mret;
      idex_illegal      <= illegal_eff;   // a valid AMO is not illegal
    end
  end

  // ==========================================================================
  // EX stage
  // ==========================================================================
  // Forwarding
  logic [XLEN-1:0] fwd_rs1, fwd_rs2;
  always_comb begin
    // rs1
    if (exmem_valid && exmem_reg_we && (exmem_rd != 5'd0) &&
        (exmem_rd == idex_rs1))
      fwd_rs1 = exmem_result;
    else if (memwb_valid && memwb_reg_we && (memwb_rd != 5'd0) &&
             (memwb_rd == idex_rs1))
      fwd_rs1 = memwb_result;
    else
      fwd_rs1 = idex_rdata1;
    // rs2
    if (exmem_valid && exmem_reg_we && (exmem_rd != 5'd0) &&
        (exmem_rd == idex_rs2))
      fwd_rs2 = exmem_result;
    else if (memwb_valid && memwb_reg_we && (memwb_rd != 5'd0) &&
             (memwb_rd == idex_rs2))
      fwd_rs2 = memwb_result;
    else
      fwd_rs2 = idex_rdata2;
  end

  // ALU
  logic [XLEN-1:0] alu_a, alu_b, alu_y;
  assign alu_a = idex_use_pc  ? idex_pc  : fwd_rs1;
  assign alu_b = idex_use_imm ? idex_imm : fwd_rs2;

  gandiva_alu u_alu (.op(idex_alu_op), .a(alu_a), .b(alu_b), .y(alu_y));

  // Branch comparison (shared leaf cell), on the forwarded EX operands
  logic br_taken;
  gandiva_branch u_br (.br_op(idex_br_op), .a(fwd_rs1), .b(fwd_rs2), .taken(br_taken));

  // muldiv unit
  logic        md_done, md_busy;
  logic [XLEN-1:0] md_result;
  logic        md_inflight;     // a muldiv has been started for current EX instr

  gandiva_muldiv u_md (
    .clk(clk), .rst(rst),
    .start(idex_valid && idex_is_md && !md_inflight && !md_busy),
    .op(idex_md_op), .a(fwd_rs1), .b(fwd_rs2),
    .busy(md_busy), .done(md_done), .result(md_result)
  );

  // md_stall holds the front-end until the muldiv result is ready.
  assign md_stall = idex_valid && idex_is_md && !md_done;

  always_ff @(posedge clk) begin
    if (rst)              md_inflight <= 1'b0;
    else if (md_done)     md_inflight <= 1'b0;
    else if (idex_valid && idex_is_md && !md_busy && !md_inflight)
                          md_inflight <= 1'b1;
  end

  // CSR
  wire  [11:0]     csr_raddr  = idex_csr_addr;
  wire  [XLEN-1:0] csr_file_rdata;         // read data from the shared gandiva_csr
  wire  [XLEN-1:0] trig_csr_rdata;         // read data from the local trigger unit
  logic [XLEN-1:0] csr_rdata;              // muxed: trigger CSRs override the file
  // trigger CSRs are core-local (kept OUT of the gandiva_csr leaf
  // cell): 0x7A0..0x7A2, 0x7A4.
  wire  [11:0]     csr_addr_q = dbg_mode ? dbg_ar_regno : csr_raddr;
  wire             is_trig_csr = (csr_addr_q==12'h7A0)||(csr_addr_q==12'h7A1)||
                                 (csr_addr_q==12'h7A2)||(csr_addr_q==12'h7A4);
  wire  [XLEN-1:0] csr_src    = idex_csr_imm_mode ? {27'b0, idex_csr_uimm}
                                                  : fwd_rs1;
  logic [XLEN-1:0] csr_wval;
  logic            csr_we;
  wire  [1:0]      csr_fn = idex_csr_op[1:0];
  always_comb begin
    unique case (csr_fn)
      2'b01:  csr_wval = csr_src;                 // CSRRW(I)
      2'b10:  csr_wval = csr_rdata |  csr_src;    // CSRRS(I)
      2'b11:  csr_wval = csr_rdata & ~csr_src;    // CSRRC(I)
      default: csr_wval = csr_rdata;
    endcase
    // CSRRS/C with rs1/uimm == 0 must not write.
    csr_we = idex_valid && idex_is_csr &&
             !((csr_fn != 2'b01) &&
               (idex_csr_imm_mode ? (idex_csr_uimm == 5'd0)
                                  : (idex_rs1 == 5'd0)));
  end

  // ==========================================================================
  // SECURE overlay (Block A): M/U privilege + PMP + N-user-trap state.
  // ==========================================================================
  // SECURE-only. The shared gandiva_csr owns the priv/PMP architectural state
  // (U_MODE/PMP_REGIONS options); two combinational gandiva_pmp checkers validate
  // the fetch address (idex_pc) and the load/store address (alu_y) — both known
  // here in EX, exactly where every other synchronous trap resolves. Default
  // (SECURE=0) ties everything off: priv stays M, no PMP logic, byte-identical.
  localparam int NPMP = 8;
  wire [1:0]   cur_priv;                 // 11=M, 00=U (from the shared CSR)
  wire         fetch_m, data_m, mmwp_w;  // fetch/data priv is M; mseccfg.MMWP
  wire [127:0] pmpcfg_w;
  wire [511:0] pmpaddr_w;
  wire acc_fetch_fault, acc_load_fault, acc_store_fault;
  // Privileged-operation faults from U-mode (all illegal-instruction traps):
  //  - access to an M-mode CSR (address bits [9:8]==11 => M-only)
  //  - MRET (a trap-return; only legal in M-mode)
  // Checked here (not in the shared decode/CSR leaf cells) so they stay untouched.
  wire priv_low        = SECURE && (cur_priv != 2'b11);
  wire csr_priv_fault  = priv_low && idex_is_csr && (idex_csr_addr[9:8] == 2'b11);
  wire mret_priv_fault = priv_low && idex_is_mret;
  wire priv_fault      = csr_priv_fault | mret_priv_fault;
  // RV32 'N' URET recognised in EX (the shared decoder doesn't know it).
  wire is_uret         = SECURE && (idex_instr == 32'h00200073);

  generate if (SECURE) begin : g_pmp
    wire pmp_fetch_fault, pmp_data_fault;
    gandiva_pmp #(.NPMP(NPMP)) u_pmp_if (   // instruction-fetch check (idex_pc)
      .cfg(pmpcfg_w[8*NPMP-1:0]), .addrreg(pmpaddr_w[32*NPMP-1:0]),
      .addr(idex_pc), .priv_m(fetch_m), .mmwp(mmwp_w),
      .do_r(1'b0), .do_w(1'b0), .do_x(1'b1), .fault(pmp_fetch_fault)
    );
    gandiva_pmp #(.NPMP(NPMP)) u_pmp_ls (   // load/store check (post-address alu_y)
      .cfg(pmpcfg_w[8*NPMP-1:0]), .addrreg(pmpaddr_w[32*NPMP-1:0]),
      .addr(alu_y), .priv_m(data_m), .mmwp(mmwp_w),
      .do_r(idex_mem_re), .do_w(idex_mem_we), .do_x(1'b0), .fault(pmp_data_fault)
    );
    assign acc_fetch_fault = idex_valid && pmp_fetch_fault;
    assign acc_load_fault  = idex_valid && idex_mem_re && pmp_data_fault;
    assign acc_store_fault = idex_valid && idex_mem_we && pmp_data_fault;
  end else begin : g_nopmp
    assign acc_fetch_fault = 1'b0;
    assign acc_load_fault  = 1'b0;
    assign acc_store_fault = 1'b0;
  end endgenerate
  wire acc_fault = acc_fetch_fault | acc_load_fault | acc_store_fault;

  // ---- N-extension architectural state (SECURE-only) -----------------------
  // The shared gandiva_csr models only M-mode; the N state + delegate-to-U
  // trap/return semantics live entirely here, layered over it. A delegated trap
  // keeps priv=U, so the shared CSR's M-mode trap machinery is simply suppressed
  // (deleg gates its trap_set). See Block B (write/trap/URET) near the CSR.
  localparam bit USERTRAPS = SECURE;
  localparam logic [11:0] CSR_USTATUS  = 12'h000;
  localparam logic [11:0] CSR_UIE      = 12'h004;
  localparam logic [11:0] CSR_UTVEC    = 12'h005;
  localparam logic [11:0] CSR_USCRATCH = 12'h040;
  localparam logic [11:0] CSR_UEPC     = 12'h041;
  localparam logic [11:0] CSR_UCAUSE   = 12'h042;
  localparam logic [11:0] CSR_UTVAL    = 12'h043;
  localparam logic [11:0] CSR_UIP      = 12'h044;
  localparam logic [11:0] CSR_MEDELEG  = 12'h302;

  logic [XLEN-1:0] utvec_r, uepc_r, ucause_r, utval_r, uscratch_r, medeleg_r;
  logic            ustatus_uie, ustatus_upie;   // ustatus.UIE (bit0), UPIE (bit4)
  // uie/uip modelled as storage only (no U-mode IRQ delivery in this embedded
  // core); they read/write-back so software sees architectural CSRs.
  logic [XLEN-1:0] uie_r, uip_r;

  // N user CSRs share the same address mux as the trigger/CSR file (csr_addr_q).
  wire is_ucsr = USERTRAPS &&
       ((csr_addr_q==CSR_USTATUS)||(csr_addr_q==CSR_UIE)||(csr_addr_q==CSR_UTVEC)||
        (csr_addr_q==CSR_USCRATCH)||(csr_addr_q==CSR_UEPC)||(csr_addr_q==CSR_UCAUSE)||
        (csr_addr_q==CSR_UTVAL)||(csr_addr_q==CSR_UIP)||(csr_addr_q==CSR_MEDELEG));
  logic [XLEN-1:0] ucsr_rdata;
  always_comb begin
    unique case (csr_addr_q)
      CSR_USTATUS : ucsr_rdata = {27'b0, ustatus_upie, 3'b0, ustatus_uie};
      CSR_UIE     : ucsr_rdata = uie_r;
      CSR_UTVEC   : ucsr_rdata = utvec_r;
      CSR_USCRATCH: ucsr_rdata = uscratch_r;
      CSR_UEPC    : ucsr_rdata = uepc_r;
      CSR_UCAUSE  : ucsr_rdata = ucause_r;
      CSR_UTVAL   : ucsr_rdata = utval_r;
      CSR_UIP     : ucsr_rdata = uip_r;
      CSR_MEDELEG : ucsr_rdata = medeleg_r;
      default     : ucsr_rdata = '0;
    endcase
  end

  // Architectural trap detection (EX). EBREAK enters debug (not a trap) when
  // dcsr.ebreakm set. Computed independently of triggers to break the
  // combinational loop (the trigger check keys off arch_trap, then ex_trap adds
  // trigger-caused breakpoint exceptions on top).
  // illegal now also covers SECURE U-mode privileged-op faults (M-CSR / MRET).
  wire         illegal_all = idex_illegal | priv_fault;
  logic        arch_trap;
  logic [3:0]  arch_cause;
  // Priority (RISC-V): instruction access-fault > illegal > ecall (priv-aware)
  // > breakpoint(ebreak) > load access-fault > store access-fault.
  always_comb begin
    arch_trap  = 1'b0;
    arch_cause = CAUSE_ILLEGAL;
    if (idex_valid) begin
      if (acc_fetch_fault)      begin arch_trap = 1'b1; arch_cause = 4'd1;            end  // instr access-fault
      else if (illegal_all)     begin arch_trap = 1'b1; arch_cause = CAUSE_ILLEGAL;  end
      else if (idex_is_ecall)   begin arch_trap = 1'b1; arch_cause = (cur_priv==2'b00) ? 4'd8 : CAUSE_ECALL_M; end
      else if (idex_is_ebreak && !dcsr_ebreakm) begin arch_trap = 1'b1; arch_cause = CAUSE_BREAKPOINT; end
      else if (acc_load_fault)  begin arch_trap = 1'b1; arch_cause = 4'd5;            end  // load access-fault
      else if (acc_store_fault) begin arch_trap = 1'b1; arch_cause = 4'd7;            end  // store access-fault
    end
  end
  // ex_trap folds in a trigger-caused breakpoint exception (action=0). A
  // trigger exception uses cause=BREAKPOINT. Architectural traps take priority.
  wire         ex_trap  = arch_trap || trig_to_exc;
  wire [3:0]   ex_cause = arch_trap ? arch_cause : CAUSE_BREAKPOINT;
  // mtval/utval for the trap: fetch fault -> pc; load/store fault -> data addr;
  // illegal -> faulting instruction word; trigger -> trigger addr; else 0.
  wire [XLEN-1:0] ex_tval = acc_fetch_fault                ? idex_pc    :
                            (acc_load_fault|acc_store_fault) ? alu_y      :
                            illegal_all                      ? idex_instr :
                            trig_to_exc                      ? trig_tval_w : 32'b0;

  // debug abstract CSR access steals the CSR file address/data while halted
  wire [11:0] csr_addr_eff = dbg_mode ? dbg_ar_regno : csr_raddr;
  // trigger + N user CSRs override the shared-file read (normal EX and via debug).
  assign csr_rdata = is_trig_csr ? trig_csr_rdata :
                     is_ucsr     ? ucsr_rdata     : csr_file_rdata;
  assign dbg_ar_rdata = !dbg_ar_csr           ? rf_rdata1 :  // GPR (rf_ra1 = regno)
                        (dbg_ar_regno==12'h7b0) ? dcsr_val :
                        (dbg_ar_regno==12'h7b1) ? dpc      :
                        (dbg_ar_regno==12'h7b2) ? dscratch0:
                        is_trig_csr             ? trig_csr_rdata :
                        is_ucsr                 ? ucsr_rdata :
                        csr_rdata;                            // CSR (addr = regno)

  logic [XLEN-1:0] mtvec_w, mepc_w;
  wire             irq_req;
  wire [3:0]       irq_cause;
  // take interrupt on a simple committing EX instruction; mepc = next sequential.
  // Debug takes priority — no new interrupts while halting/halted.
  wire take_irq = idex_valid && !ex_freeze && irq_req && !ex_trap && !dbg_freeze &&
                  !idex_is_mret && !is_uret && !idex_is_csr &&
                  !idex_is_branch && !idex_is_jal && !idex_is_jalr;
  wire [XLEN-1:0] irq_epc = idex_pc + {29'd0, idex_len};

  // ---- Zihpm event strobes: decoded from the instruction retiring in WB.
  // These fire in the same cycle as retire(memwb_valid) so instret and the
  // programmable counters see a consistent view of the retired instruction.
  wire [6:0] rwb_op    = memwb_instr[6:0];
  wire       ev_branch = memwb_valid && (rwb_op == OP_BRANCH);
  wire       ev_load   = memwb_valid && (rwb_op == OP_LOAD);
  wire       ev_store  = memwb_valid && (rwb_op == OP_STORE);
  wire       ev_brtaken= memwb_valid && (rwb_op == OP_BRANCH) && memwb_br_taken;

  // Effective CSR write in normal EX (used by both the shared file and the
  // trigger unit; the trigger unit takes the trigger addresses, the file takes
  // the rest — they are mutually exclusive via is_trig_csr).
  wire csr_we_eff = dbg_mode ? dbg_csr_we : (csr_we && !ex_trap && !ex_freeze);
  wire [XLEN-1:0] csr_wdata_eff = dbg_mode ? dbg_ar_wdata : csr_wval;

  // ---- SECURE overlay (Block B): delegate-to-U decision + effective writes ---
  // A synchronous exception taken in U-mode is delivered to U iff its cause bit
  // is set in medeleg. A delegated trap keeps priv=U, so the shared (M-mode) CSR
  // trap machinery is simply suppressed (deleg gates its trap_set). N user-CSR
  // writes are routed to the local N block (Block C) and kept off the shared CSR.
  wire deleg_trap = USERTRAPS && (cur_priv==2'b00) && ex_trap && !ex_freeze &&
                    medeleg_r[ex_cause];
  wire m_trap_set = (ex_trap && !ex_freeze && !deleg_trap) || take_irq;
  wire ucsr_we    = csr_we_eff && is_ucsr;

  gandiva_csr #(.MISA_VAL((32'b01<<30)|(1<<8)|(1<<12)|(1<<2)|(1<<1)|(1<<0)),  // RV32IMAC + Zbb (B)
                .U_MODE(SECURE), .PMP_REGIONS(SECURE ? NPMP : 0)) u_csr (  // secure opt
    .clk(clk), .rst(rst),
    .csr_addr(csr_addr_eff), .csr_rdata(csr_file_rdata),
    .csr_we(csr_we_eff && !is_trig_csr && !is_ucsr),
    .csr_wdata(csr_wdata_eff),
    // privilege + PMP outputs (meaningful only when SECURE)
    .priv_o(cur_priv), .fetch_m_o(fetch_m), .data_m_o(data_m), .mmwp_o(mmwp_w),
    .pmpcfg_o(pmpcfg_w), .pmpaddr_o(pmpaddr_w),
    // delegated-to-U exceptions are handled by the local N block, not the M CSR
    .trap_set(m_trap_set),
    .trap_cause(ex_trap ? ex_cause : irq_cause),
    .trap_interrupt(take_irq),
    .trap_epc(ex_trap ? idex_pc : irq_epc),
    .trap_tval(ex_tval),
    .mret(idex_valid && idex_is_mret && !mret_priv_fault && !ex_freeze),
    .retire(memwb_valid),
    .ev_branch(ev_branch), .ev_brtaken(ev_brtaken),
    .ev_load(ev_load), .ev_store(ev_store),
    .irq_timer(irq_timer), .irq_soft(irq_soft), .irq_ext(irq_ext),
    .irq_req(irq_req), .irq_cause(irq_cause),
    .mtvec_o(mtvec_w), .mepc_o(mepc_w)
  );

  // ---- SECURE overlay (Block C): N architectural state write/trap/URET -------
  generate if (USERTRAPS) begin : g_ntrap
    always_ff @(posedge clk) begin
      if (rst) begin
        utvec_r<='0; uepc_r<='0; ucause_r<='0; utval_r<='0; uscratch_r<='0;
        medeleg_r<='0; uie_r<='0; uip_r<='0; ustatus_uie<=1'b0; ustatus_upie<=1'b0;
      end else begin
        // priority: a delegated trap / URET this cycle over a software CSR write.
        if (deleg_trap) begin
          uepc_r       <= idex_pc;
          ucause_r     <= {28'b0, ex_cause};
          utval_r      <= ex_tval;
          ustatus_upie <= ustatus_uie;   // save UIE
          ustatus_uie  <= 1'b0;          // disable U interrupts in handler
        end else if (idex_valid && is_uret && !ex_freeze) begin
          ustatus_uie  <= ustatus_upie;  // restore UIE
          ustatus_upie <= 1'b1;
        end else if (ucsr_we) begin
          unique case (csr_addr_q)
            CSR_USTATUS : begin ustatus_uie<=csr_wdata_eff[0]; ustatus_upie<=csr_wdata_eff[4]; end
            CSR_UIE     : uie_r      <= csr_wdata_eff;
            CSR_UTVEC   : utvec_r    <= csr_wdata_eff;
            CSR_USCRATCH: uscratch_r <= csr_wdata_eff;
            CSR_UEPC    : uepc_r     <= csr_wdata_eff;
            CSR_UCAUSE  : ucause_r   <= csr_wdata_eff;
            CSR_UTVAL   : utval_r    <= csr_wdata_eff;
            CSR_UIP     : uip_r      <= csr_wdata_eff;
            CSR_MEDELEG : medeleg_r  <= csr_wdata_eff;
            default     : ;
          endcase
        end
      end
    end
  end else begin : g_no_ntrap
    // tie N state to 0 so reads are clean and delegation never fires
    always_comb begin
      utvec_r='0; uepc_r='0; ucause_r='0; utval_r='0; uscratch_r='0;
      medeleg_r='0; uie_r='0; uip_r='0; ustatus_uie=1'b0; ustatus_upie=1'b0;
    end
  end endgenerate

  // ==========================================================================
  // Debug hardware triggers (Sdtrig / mcontrol6) — gandiva-local unit.
  // Evaluated on the instruction in EX. An execute (PC) trigger checks idex_pc;
  // a load/store (address) trigger checks the EX-computed data address alu_y.
  // A match with action=1 enters Debug Mode (like ebreak-to-debug); action=0
  // raises a breakpoint exception. Either way the matched instruction is
  // squashed BEFORE it commits (never advances to MEM) — "before" timing.
  // ==========================================================================
  localparam int unsigned NTRIG = 2;
  wire             trig_exec, trig_ldst, trig_action;
  wire [XLEN-1:0]  trig_tval_w;
  wire [NTRIG-1:0] trig_fire_mask;
  // only check when EX holds a genuine, non-frozen instruction that isn't already
  // (architecturally) trapping and we're not already in/entering debug.
  wire trig_chk_valid = idex_valid && !ex_freeze && !arch_trap && !dbg_mode;
  wire trig_mem_re = idex_valid && idex_mem_re;
  wire trig_mem_we = idex_valid && idex_mem_we;

  gandiva_trigger #(.NTRIG(NTRIG)) u_trig (
    .clk(clk), .rst(rst),
    .csr_addr(csr_addr_q),
    .csr_rdata(trig_csr_rdata),
    .csr_we(csr_we_eff && is_trig_csr),
    .csr_wdata(dbg_mode ? dbg_ar_wdata : csr_wval),
    .chk_valid(trig_chk_valid),
    .chk_pc(idex_pc),
    .chk_mem_re(trig_mem_re),
    .chk_mem_we(trig_mem_we),
    .chk_mem_addr(alu_y),
    .trig_exec(trig_exec),
    .trig_ldst(trig_ldst),
    .trig_action(trig_action),
    .trig_tval(trig_tval_w),
    .trig_fire_mask(trig_fire_mask),
    .hit_set(trig_fire),
    .hit_mask(trig_fire_mask)
  );

  // A trigger fires this cycle (either execute or load/store match).
  // action=1 => enter debug mode (independent of dcsr.ebreakm, which is
  // EBREAK-specific); action=0 => breakpoint exception.
  wire trig_fire       = trig_exec || trig_ldst;
  assign trig_to_debug = trig_fire &&  trig_action;
  wire trig_to_exc     = trig_fire && !trig_action;

  // Redirect resolution (EX)
  wire [XLEN-1:0] jalr_target = (fwd_rs1 + idex_imm) & ~32'd1;
  wire [XLEN-1:0] br_target   = idex_pc + idex_imm;
  wire [XLEN-1:0] seq_next    = idex_pc + {29'd0, idex_len};

  // Actual next-PC for the branch/jal in EX (unconditional & branch cases).
  wire            br_actual_taken = idex_is_jal || (idex_is_branch && br_taken);
  wire [XLEN-1:0] br_actual_next  = br_actual_taken ? br_target : seq_next;
  // What IF actually fetched next after this instruction (its prediction).
  wire [XLEN-1:0] pred_next        = idex_pred_taken ? idex_pred_target : seq_next;
  // Misprediction: the fetched-next differs from the correct next-PC.
  wire            mispredict = BPRED && (idex_is_branch || idex_is_jal) &&
                               (br_actual_next != pred_next);
  // With BPRED off, fall back to "redirect whenever taken" (original behaviour).
  wire            br_needs_redirect = BPRED ? mispredict
                                            : (idex_is_jal || (idex_is_branch && br_taken));

  always_comb begin
    redirect        = 1'b0;
    redirect_target = '0;
    if (idex_valid && !ex_freeze) begin
      if (ex_trap) begin
        // delegated-to-U exceptions vector to utvec; non-delegated to mtvec.
        redirect = 1'b1; redirect_target = deleg_trap ? utvec_r : mtvec_w;
      end else if (is_uret) begin
        redirect = 1'b1; redirect_target = uepc_r;
      end else if (idex_is_mret) begin
        redirect = 1'b1; redirect_target = mepc_w;
      end else if (idex_is_jalr) begin
        // JALR: RAS-predicted (returns). Flush only on misprediction; the target
        // is always the EX-computed jalr_target (authoritative). Non-return JALRs
        // have pred_taken=0 so pred_next=seq_next != jalr_target -> they flush.
        redirect = BPRED ? (jalr_target != (idex_pred_taken ? idex_pred_target : seq_next))
                         : 1'b1;
        redirect_target = jalr_target;
      end else if (idex_is_jal || idex_is_branch) begin
        // predicted control flow: only flush on misprediction (the win)
        redirect = br_needs_redirect; redirect_target = br_actual_next;
      end else if (take_irq) begin
        redirect = 1'b1; redirect_target = mtvec_w;
      end
    end
  end

  // ---- branch-predictor update signals (consumed by the predictor always_ff) --
  always_comb begin
    bp_upd_en     = idex_valid && !ex_freeze && !ex_trap &&
                    (idex_is_branch || idex_is_jal);
    bp_upd_cond   = idex_is_branch;
    bp_upd_taken  = br_actual_taken;
    bp_upd_pc     = idex_pc;
    bp_upd_target = br_target;              // taken target (branch/jal are PC-rel)
    bp_upd_isjal  = idex_is_jal;
    bp_upd_ghist  = idex_ghist;
  end

  // EX result select (non-memory, non-md)
  logic [XLEN-1:0] ex_result;
  always_comb begin
    unique case (idex_wb_sel)
      WB_PC4 : ex_result = idex_pc + {29'd0, idex_len};   // link = PC + (2 or 4)
      WB_CSR : ex_result = csr_rdata;
      WB_MD  : ex_result = md_result;     // valid the cycle md_done is high
      default: ex_result = alu_y;         // WB_ALU (and WB_MEM uses addr below)
    endcase
  end

  // store byte-enable + data alignment
  wire  [1:0]      st_off = alu_y[1:0];
  wire  [7:0]      st_b   = fwd_rs2[7:0];
  wire  [15:0]     st_h   = fwd_rs2[15:0];
  wire [3:0] ex_be =
      !idex_mem_we            ? 4'b0000 :
      (idex_mem_width == 2'd0) ? (4'b0001 << st_off) :
      (idex_mem_width == 2'd1) ? (st_off[1] ? 4'b1100 : 4'b0011) :
                                 4'b1111;
  wire [XLEN-1:0] ex_store_data =
      (idex_mem_width == 2'd0) ? {4{st_b}} :
      (idex_mem_width == 2'd1) ? {2{st_h}} :
                                 fwd_rs2;

  // EX/MEM register
  // Bubble when EX has no valid instr, is flushed by its own trap/redirect is
  // fine (the instr still commits its side effects), or while md is stalling.
  // EBREAK-to-debug (and a hardware trigger-to-debug) is squashed (converted to
  // a halt, never advances to MEM). A trigger-to-exception path leaves ex_commit
  // asserted but the EX/MEM latch zeroes its mem/reg writes via !ex_trap, so no
  // architectural side effect escapes.
  wire ex_commit = idex_valid && !md_stall && !to_debug_now;

  always_ff @(posedge clk) begin
    if (rst) begin
      exmem_valid <= 1'b0;
    end else if (mem_beat_stall) begin
      // hold the misaligned load/store in MEM for its 2nd beat (no new instr in)
      exmem_valid <= exmem_valid;
    end else begin
      exmem_valid        <= ex_commit;
      exmem_pc           <= idex_pc;
      exmem_instr        <= idex_instr;
      exmem_result       <= ex_result;
      exmem_store_data   <= ex_store_data;
      exmem_be           <= ex_be;
      exmem_addr_lo      <= st_off;
      exmem_rd           <= idex_rd;
      // a trapping instruction writes no register
      exmem_reg_we       <= idex_reg_we && !ex_trap;
      exmem_mem_re       <= idex_mem_re && !ex_trap;
      exmem_mem_we       <= idex_mem_we && !ex_trap;
      exmem_mem_width    <= idex_mem_width;
      exmem_mem_unsigned <= idex_mem_unsigned;
      // AMO: carry the type + operands (address = rs1, data = rs2); suppressed on trap
      exmem_is_amo       <= idex_is_amo && !ex_trap;
      exmem_is_lr        <= idex_is_lr;
      exmem_is_sc        <= idex_is_sc;
      exmem_is_amo_rmw   <= idex_is_amo_rmw;
      exmem_amo_f5       <= idex_amo_f5;
      exmem_amo_addr     <= fwd_rs1;
      exmem_amo_b        <= fwd_rs2;
      // Zihpm: a conditional branch that resolved taken (jal excluded)
      exmem_br_taken     <= idex_is_branch && br_taken;
`ifdef RISCV_FORMAL
      exmem_rs1     <= idex_rs1;   exmem_rs2  <= idex_rs2;
      exmem_rs1v    <= fwd_rs1;    exmem_rs2v <= fwd_rs2;
      // pc_wdata = architectural next-PC: taken target for a taken branch/jal, the
      // computed jalr_target for a JALR (whether or not a RAS hit avoided the flush),
      // else the resolved redirect, else seq.
      exmem_pcw     <= (idex_is_branch || idex_is_jal) ? br_actual_next
                     : idex_is_jalr ? jalr_target
                     : redirect ? redirect_target : (idex_pc + {29'd0, idex_len});
      exmem_trap    <= ex_trap;    exmem_entry<= ex_trap | take_irq;
      exmem_memaddr <= alu_y;
`endif
    end
  end

  // ==========================================================================
  // MEM stage — unified shift path; a misaligned access takes a 2nd beat.
  // ==========================================================================
  // A misaligned data access crosses a word boundary (word at off!=0, or half
  // at off=3). It reads/writes two words over two cycles; the pipeline freezes
  // for the extra beat via mem_beat_stall.
  wire mem_mis = exmem_valid && (exmem_mem_re || exmem_mem_we) &&
                 ((exmem_mem_width==2'd2 && exmem_addr_lo!=2'b00) ||
                  (exmem_mem_width==2'd1 && exmem_addr_lo==2'b11));

  // ---- RV32 'A' atomics in MEM --------------------------------------------
  // AMO address = rs1 (word-aligned). AMO<op> is a 2-beat read-modify-write
  // (beat1 load -> ld_w0, beat2 store op(ld_w0,rs2)); LR is a 1-beat load that
  // arms the reservation; SC stores rs2 iff the reservation matches (rd=0/1).
  logic            resv_valid;
  logic [XLEN-1:0] resv_addr;
  wire             amo_here    = exmem_valid && exmem_is_amo;
  wire [XLEN-1:0]  amo_addr_al = {exmem_amo_addr[XLEN-1:2], 2'b00};
  wire             sc_ok       = resv_valid && (resv_addr == amo_addr_al);
  wire             amo_rmw_b1  = amo_here && exmem_is_amo_rmw && !beat2;  // load beat
  wire             amo_rmw_b2  = amo_here && exmem_is_amo_rmw && beat2;   // store beat
  wire             amo_do_load = amo_here && (exmem_is_lr || amo_rmw_b1);
  wire             amo_do_store= amo_here && ((exmem_is_sc && sc_ok) || amo_rmw_b2);
  logic [XLEN-1:0] amo_res;    // op(ld_w0, rs2) written back on the AMO<op> store beat
  always_comb unique case (exmem_amo_f5)
    5'b00001: amo_res = exmem_amo_b;                                          // SWAP
    5'b00000: amo_res = ld_w0 + exmem_amo_b;                                  // ADD
    5'b00100: amo_res = ld_w0 ^ exmem_amo_b;                                  // XOR
    5'b01100: amo_res = ld_w0 & exmem_amo_b;                                  // AND
    5'b01000: amo_res = ld_w0 | exmem_amo_b;                                  // OR
    5'b10000: amo_res = ($signed(ld_w0) < $signed(exmem_amo_b)) ? ld_w0 : exmem_amo_b; // MIN
    5'b10100: amo_res = ($signed(ld_w0) > $signed(exmem_amo_b)) ? ld_w0 : exmem_amo_b; // MAX
    5'b11000: amo_res = (ld_w0 < exmem_amo_b) ? ld_w0 : exmem_amo_b;          // MINU
    5'b11100: amo_res = (ld_w0 > exmem_amo_b) ? ld_w0 : exmem_amo_b;          // MAXU
    default:  amo_res = exmem_amo_b;
  endcase

  // freeze one extra cycle for a misaligned 2nd beat OR an AMO<op> store beat
  assign mem_beat_stall = (mem_mis && !beat2) || amo_rmw_b1;

  always_ff @(posedge clk) begin
    if (rst) begin beat2 <= 1'b0; ld_w0 <= 32'b0; end
    else begin
      if (mem_beat_stall) ld_w0 <= dmem_rdata;   // capture word0 (misaligned or AMO load)
      beat2 <= mem_beat_stall;                    // next cycle drives the 2nd beat
    end
  end

  // LR/SC reservation (single hart): LR arms it, SC + any plain store clear it.
  always_ff @(posedge clk) begin
    if (rst) resv_valid <= 1'b0;
    else if (amo_here && exmem_is_lr)         begin resv_valid <= 1'b1; resv_addr <= amo_addr_al; end
    else if (amo_here && exmem_is_sc)         resv_valid <= 1'b0;
    else if (exmem_valid && exmem_mem_we)     resv_valid <= 1'b0;
  end

  // raw store value recovered from the (replicated) store data, then placed
  // in an 8-byte window at the byte offset — low word on beat0, high on beat2.
  wire [31:0] st_raw = (exmem_mem_width==2'd0) ? {24'b0, exmem_store_data[7:0]} :
                       (exmem_mem_width==2'd1) ? {16'b0, exmem_store_data[15:0]} :
                                                 exmem_store_data;
  wire [63:0] st_win = {32'b0, st_raw} << {exmem_addr_lo, 3'b000};
  wire [7:0]  be_win = (((exmem_mem_width==2'd0)?8'h01:
                         (exmem_mem_width==2'd1)?8'h03:8'h0F)) << exmem_addr_lo;

  assign dmem_addr  = amo_here ? amo_addr_al
                               : {exmem_result[XLEN-1:2], 2'b00} + (beat2 ? 32'd4 : 32'd0);
  assign dmem_re    = (exmem_valid && exmem_mem_re) || amo_do_load;
  assign dmem_we    = (exmem_valid && exmem_mem_we) || amo_do_store;
  assign dmem_be    = amo_here ? 4'b1111 : (beat2 ? be_win[7:4] : be_win[3:0]);
  assign dmem_wdata = amo_rmw_b2               ? amo_res       // AMO<op>: op(old,rs2)
                    : (amo_here && exmem_is_sc) ? exmem_amo_b   // SC: store rs2
                    : (beat2 ? st_win[63:32] : st_win[31:0]);

  // load assembly: {word1,word0} >> off*8, then width-extract
  wire [63:0] ld_comb = beat2 ? {dmem_rdata, ld_w0} : {32'b0, dmem_rdata};
  wire [63:0] ld_sh   = ld_comb >> {exmem_addr_lo, 3'b000};
  wire [7:0]  lb_byte = ld_sh[7:0];
  wire [15:0] lh_half = ld_sh[15:0];
  wire [XLEN-1:0] load_data =
      (exmem_mem_width == 2'd0)
        ? (exmem_mem_unsigned ? {24'b0, lb_byte} : {{24{lb_byte[7]}}, lb_byte})
      : (exmem_mem_width == 2'd1)
        ? (exmem_mem_unsigned ? {16'b0, lh_half} : {{16{lh_half[15]}}, lh_half})
      : ld_sh[31:0];

  // AMO writeback: LR -> loaded word; SC -> 0 (ok) / 1 (fail); AMO<op> -> old word
  wire [XLEN-1:0] amo_wb = exmem_is_lr ? dmem_rdata
                         : exmem_is_sc ? (sc_ok ? 32'd0 : 32'd1)
                         :               ld_w0;
  wire [XLEN-1:0] mem_result = amo_here     ? amo_wb
                             : exmem_mem_re  ? load_data
                             :                 exmem_result;

  // MEM/WB register
  always_ff @(posedge clk) begin
    if (rst) begin
      memwb_valid <= 1'b0;
    end else if (mem_beat_stall) begin
      memwb_valid <= 1'b0;             // 1st beat cycle: nothing retires yet
    end else begin
      memwb_valid  <= exmem_valid;
      memwb_pc     <= exmem_pc;
      memwb_instr  <= exmem_instr;
      memwb_result <= mem_result;
      memwb_rd     <= exmem_rd;
      memwb_reg_we <= exmem_reg_we;
      memwb_br_taken <= exmem_br_taken;
`ifdef RISCV_FORMAL
      memwb_rs1  <= exmem_rs1;   memwb_rs2  <= exmem_rs2;
      memwb_rs1v <= exmem_rs1v;  memwb_rs2v <= exmem_rs2v;
      memwb_pcw  <= exmem_pcw;   memwb_trap <= exmem_trap;  memwb_entry <= exmem_entry;
      memwb_memaddr <= exmem_memaddr; memwb_memre <= exmem_mem_re; memwb_memwe <= exmem_mem_we;
      memwb_wmask <= exmem_be;   memwb_mw <= exmem_mem_width; memwb_moff <= exmem_addr_lo;
      memwb_wdata <= exmem_store_data; memwb_rdata <= dmem_rdata;
`endif
    end
  end

  // ==========================================================================
  // WB stage
  // ==========================================================================
  assign rf_we = memwb_valid && memwb_reg_we;
  assign rf_wa = memwb_rd;
  assign rf_wd = memwb_result;

  // Retire trace
  assign retire_valid  = memwb_valid;
  assign retire_pc     = memwb_pc;
  assign retire_instr  = memwb_instr;
  assign retire_rd_we  = memwb_valid && memwb_reg_we && (memwb_rd != 5'd0);
  assign retire_rd     = memwb_rd;
  assign retire_rd_val = memwb_result;

  // ---- debug controller: drain-to-halt / resume / single-step --------------
  always_ff @(posedge clk) begin
    if (rst) begin
      dbg_mode<=1'b0; halt_req<=1'b0; step_active<=1'b0;
      dpc<='0; dscratch0<='0; dcsr_ebreakm<=1'b0; dcsr_step<=1'b0; dcsr_cause<=3'd0;
      dbg_ar_busy<=1'b0; dbg_ar_done<=1'b0; dpc_cap_valid<=1'b0; dpc_cap<='0;
      dbg_ebrk_cause<=1'b0;
    end else begin
      dbg_ar_done <= 1'b0;
      if (dbg_do) begin
        dbg_ar_busy <= 1'b1;
        dbg_ar_done <= 1'b1;
        if (dbg_ar_write && dbg_ar_csr) unique case (dbg_ar_regno)
          12'h7b0: begin dcsr_ebreakm<=dbg_ar_wdata[15]; dcsr_step<=dbg_ar_wdata[2]; end
          12'h7b1: dpc       <= dbg_ar_wdata;
          12'h7b2: dscratch0 <= dbg_ar_wdata;
          default: ;
        endcase
      end
      if (!dbg_ar_valid) dbg_ar_busy <= 1'b0;

      if (!dbg_mode) begin
        if (dbg_haltreq)     halt_req <= 1'b1;
        if (ebreak_to_debug) begin halt_req<=1'b1; dpc_cap<=idex_pc; dpc_cap_valid<=1'b1; dbg_ebrk_cause<=1'b1; end
        // hardware trigger (action=1): capture the matched instruction's PC as dpc
        // and record dcsr.cause=2 (trigger). Priority under an EBREAK the same cycle.
        else if (trig_to_debug) begin halt_req<=1'b1; dpc_cap<=idex_pc; dpc_cap_valid<=1'b1; dbg_ebrk_cause<=1'b0; end
        if (step_halt_now)   halt_req <= 1'b1;
      end
      if (halt_req && !dbg_mode && pipe_drained) begin
        dbg_mode      <= 1'b1;
        halt_req      <= 1'b0;
        dpc           <= dpc_cap_valid ? dpc_cap : pc;
        // dcsr.cause: 1=ebreak, 2=trigger, 3=haltreq, 4=step
        dcsr_cause    <= dpc_cap_valid ? (dbg_ebrk_cause ? 3'd1 : 3'd2)
                                       : (step_active ? 3'd4 : 3'd3);
        step_active   <= 1'b0;
        dpc_cap_valid <= 1'b0;
      end
      if (dbg_mode && dbg_resumereq) begin
        dbg_mode    <= 1'b0;
        step_active <= dcsr_step;
      end
    end
  end

  // ==========================================================================
  // Branch-predictor state update (BHT gshare counters + BTB + GHR)
  // ==========================================================================
  generate if (BPRED) begin : g_bpred
    // update indices use the GHR snapshot captured when THIS branch was fetched.
    // Halfword-granular (bit 1 included) to match the IF-stage lookup — see the
    // aliasing note there; the read and write indexing MUST agree.
    wire [BHT_BITS-1:0] bht_wr_idx = bp_upd_pc[BHT_BITS:1] ^ bp_upd_ghist[BHT_BITS-1:0];
    wire [BTB_BITS-1:0] btb_wr_idx = bp_upd_pc[BTB_BITS:1];
    wire [BTB_TAGW-1:0] btb_wr_tag = bp_upd_pc[XLEN-1:BTB_BITS+1];
    integer bi;
    always_ff @(posedge clk) begin
      if (rst) begin
        ghist <= '0;
        for (bi = 0; bi < BHT_ENTRIES; bi = bi + 1) bht[bi] <= 2'b01; // weakly N-T
        for (bi = 0; bi < BTB_ENTRIES; bi = bi + 1) btb_valid[bi] <= 1'b0;
      end else if (bp_upd_en) begin
        // BHT: 2-bit saturating counter toward the actual direction (cond only)
        if (bp_upd_cond) begin
          if (bp_upd_taken) bht[bht_wr_idx] <= (bht[bht_wr_idx]==2'b11) ? 2'b11 : bht[bht_wr_idx]+2'b01;
          else              bht[bht_wr_idx] <= (bht[bht_wr_idx]==2'b00) ? 2'b00 : bht[bht_wr_idx]-2'b01;
          ghist <= {ghist[GHR_BITS-2:0], bp_upd_taken};   // shift in outcome
        end
        // BTB: install/refresh the target on a TAKEN control-flow instr
        if (bp_upd_taken || bp_upd_isjal) begin
          btb_valid[btb_wr_idx] <= 1'b1;
          btb_tag  [btb_wr_idx] <= btb_wr_tag;
          btb_tgt  [btb_wr_idx] <= bp_upd_target;
          btb_isjal[btb_wr_idx] <= bp_upd_isjal;
        end
      end
    end
  end endgenerate

`ifdef RISCV_FORMAL
  always_ff @(posedge clk) begin
    if (rst) begin rvfi_order_r <= 64'd0; rvfi_intr_r <= 1'b0; end
    else if (memwb_valid) begin
      rvfi_order_r <= rvfi_order_r + 64'd1;
      rvfi_intr_r  <= memwb_entry;
    end
  end
  wire [3:0] rvfi_rmask = (memwb_mw==2'd0) ? (4'b0001 << memwb_moff) :
                          (memwb_mw==2'd1) ? (memwb_moff[1]?4'b1100:4'b0011) : 4'b1111;
  wire memwb_rdwe = memwb_valid && memwb_reg_we && (memwb_rd != 5'd0);
  assign rvfi_valid     = memwb_valid;
  assign rvfi_order     = rvfi_order_r;
  assign rvfi_insn      = memwb_instr;
  assign rvfi_trap      = memwb_trap;
  assign rvfi_halt      = 1'b0;
  assign rvfi_intr      = rvfi_intr_r;
  assign rvfi_mode      = 2'b11;
  assign rvfi_ixl       = 2'b01;
  assign rvfi_rs1_addr  = memwb_rs1;
  assign rvfi_rs2_addr  = memwb_rs2;
  assign rvfi_rs1_rdata = memwb_rs1v;
  assign rvfi_rs2_rdata = memwb_rs2v;
  assign rvfi_rd_addr   = memwb_rdwe ? memwb_rd     : 5'd0;
  assign rvfi_rd_wdata  = memwb_rdwe ? memwb_result : 32'd0;
  assign rvfi_pc_rdata  = memwb_pc;
  assign rvfi_pc_wdata  = memwb_pcw;
  assign rvfi_mem_addr  = {memwb_memaddr[XLEN-1:2], 2'b00};
  assign rvfi_mem_rmask = memwb_memre ? rvfi_rmask  : 4'd0;
  assign rvfi_mem_wmask = memwb_memwe ? memwb_wmask : 4'd0;
  assign rvfi_mem_rdata = memwb_rdata;
  assign rvfi_mem_wdata = memwb_wdata;
`endif
endmodule
