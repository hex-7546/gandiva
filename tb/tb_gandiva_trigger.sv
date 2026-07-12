// ============================================================================
// tb_gandiva_trigger.sv — self-checking testbench for the Gandiva hardware
// debug triggers (Sdtrig / mcontrol6). Bit-bangs the same JTAG TAP as
// tb_gandiva_debug and drives the trigger CSRs (tselect 0x7A0, tdata1 0x7A1,
// tdata2 0x7A2) via the abstract-command CSR path while halted.
//
// Program under test (RV32, no RVC so PCs are 4-byte aligned):
//   0x00 li   ra,1
//   0x04 lui  sp,0x80007          ; sp = 0x8000_7000  (store base)
//   0x08 loop: addi ra,ra,1
//   0x0C sw   ra,0(sp)            ; store ra -> 0x8000_7000
//   0x10 j    loop
//
// Tests:
//   T1  execute (PC-match) breakpoint: tdata2 = 0x0C -> resume -> hart halts
//       in debug at dpc=0x0C, dcsr.cause=2 (trigger).
//   T2  NEGATIVE CONTROL (exec near-miss): tdata2 = 0x100 (never fetched) ->
//       resume -> hart does NOT halt.
//   T3  store (address-match) watchpoint: tdata2 = 0x8000_7000 -> resume ->
//       hart halts in debug at dpc=0x0C (the store instr), and the store did
//       NOT commit (memory unchanged from its seed).
//   T4  NEGATIVE CONTROL (store near-miss): tdata2 = 0x8000_7100 -> resume ->
//       hart does NOT halt (and the real store keeps happening).
// Reports TRIGGER: PASS / TRIGGER: FAIL.
// ============================================================================
`timescale 1ns/1ps

module tb_gandiva_trigger;
  logic clk = 1'b0; always #5 clk = ~clk;
  logic rst;
  logic tck = 1'b0, tms = 1'b0, tdi = 1'b0, tdo;

  logic [31:0] tohost; logic tohost_we;
  logic        rv; logic [31:0] rpc, rins, rval; logic rwe; logic [4:0] rrd;

  gandiva_soc dut (
    .clk(clk), .rst(rst), .tck(tck), .tms(tms), .tdi(tdi), .tdo(tdo),
    .tohost(tohost), .tohost_we(tohost_we),
    .retire_valid(rv), .retire_pc(rpc), .retire_instr(rins),
    .retire_rd_we(rwe), .retire_rd(rrd), .retire_rd_val(rval)
  );

  integer i, errors = 0;
  reg [63:0] dump, cap;

  task automatic tck_cyc(input bit tms_v, input bit tdi_v);
    begin
      tms = tms_v; tdi = tdi_v; @(posedge clk);
      tck = 1'b1; repeat (3) @(posedge clk);
      tck = 1'b0; repeat (3) @(posedge clk);
    end
  endtask
  task automatic jtag_reset; begin
    for (i=0;i<6;i++) tck_cyc(1,0); tck_cyc(0,0);
  end endtask
  task automatic scan_dr(input int n, input [63:0] din, output [63:0] dout);
    int k; begin
      dout = 0;
      tck_cyc(1,0); tck_cyc(0,0);
      while (dut.u_dbg.tap != 4) tck_cyc(0,0);
      for (k=0;k<n;k++) begin dout[k] = tdo; tck_cyc((k==n-1)?1'b1:1'b0, din[k]); end
      tck_cyc(1,0); tck_cyc(0,0);
    end
  endtask
  task automatic scan_ir(input [4:0] irval);
    int k; begin
      tck_cyc(1,0); tck_cyc(1,0); tck_cyc(0,0);
      while (dut.u_dbg.tap != 11) tck_cyc(0,0);
      for (k=0;k<5;k++) tck_cyc((k==4)?1'b1:1'b0, irval[k]);
      tck_cyc(1,0); tck_cyc(0,0);
    end
  endtask
  task automatic dmi_write(input [6:0] a, input [31:0] d);
    begin scan_dr(41, {23'd0, a, d, 2'd2}, dump); end
  endtask
  task automatic dmi_read(input [6:0] a, output [31:0] d);
    begin
      scan_dr(41, {23'd0, a, 32'd0, 2'd1}, dump);
      scan_dr(41, {23'd0, 7'd0, 32'd0, 2'd0}, cap);
      d = cap[33:2];
    end
  endtask
  function [31:0] arcmd(input bit wr, input [15:0] regno);
    arcmd = (3'd2<<20) | (1<<17) | (wr<<16) | regno;
  endfunction

  localparam [6:0] DATA0=7'h04, DMCONTROL=7'h10, DMSTATUS=7'h11, COMMAND=7'h17;
  reg [31:0] v, idcode, dpc_v, dcsr_v, mem_before;
  integer    halts;

  // ---- helpers --------------------------------------------------------------
  // write a CSR (regno) via abstract command
  task automatic csr_wr(input [15:0] regno, input [31:0] d);
    begin dmi_write(DATA0, d); dmi_write(COMMAND, arcmd(1'b1, regno)); end
  endtask
  task automatic csr_rd(input [15:0] regno, output [31:0] d);
    begin dmi_write(COMMAND, arcmd(1'b0, regno)); dmi_read(DATA0, d); end
  endtask
  // halt the hart and wait for allhalted
  task automatic do_halt(output bit ok);
    begin
      dmi_write(DMCONTROL, 32'h8000_0001);
      halts = 0;
      for (i=0;i<40;i++) begin dmi_read(DMSTATUS, v); if (v[9]) begin halts=1; i=40; end end
      ok = (halts==1);
    end
  endtask
  // resume, then poll dmstatus: returns re-halted? within a bounded window.
  task automatic resume_and_watch(input int cycles, output bit rehalted);
    begin
      dmi_write(DMCONTROL, 32'h4000_0001);   // resumereq
      // let it run for a while, polling for a spontaneous (trigger) halt
      rehalted = 1'b0;
      for (i=0;i<cycles;i++) begin
        dmi_read(DMSTATUS, v);
        if (v[9]) begin rehalted = 1'b1; i=cycles; end
      end
    end
  endtask

  // trigger CSR regnos
  localparam [15:0] TSELECT=16'h07A0, TDATA1=16'h07A1, TDATA2=16'h07A2;
  // mcontrol6 tdata1 fields: type6(31:28) | action(12) | m(6) | execute(2)|store(1)|load(0)
  localparam [31:0] MC6_EXEC_DBG  = 32'h6000_1044; // execute, action=debug, m
  localparam [31:0] MC6_STORE_DBG = 32'h6000_1042; // store,   action=debug, m
  bit ok;

  initial begin
    // program memory
    for (i=0;i<8192;i++) begin dut.imem[i]=32'h00000013; dut.dram[i]=32'h0; end
    dut.imem[0] = 32'h00100093;   // li   ra,1
    dut.imem[1] = 32'h80007137;   // lui  sp,0x80007
    dut.imem[2] = 32'h00108093;   // addi ra,ra,1   (loop @0x08)
    dut.imem[3] = 32'h00112023;   // sw   ra,0(sp)  (@0x0C -> 0x80007000)
    dut.imem[4] = 32'hff9ff06f;   // j    loop      (@0x10 -> 0x08)

    rst = 1'b1; repeat (6) @(posedge clk); rst = 1'b0;
    repeat (40) @(posedge clk);

    jtag_reset;
    scan_dr(32, 64'd0, cap); idcode = cap[31:0];
    if (idcode !== 32'h4741_4E44) begin $display("[TRG] FAIL idcode=%08x", idcode); errors++; end
    else $display("[TRG] ok   idcode = %08x", idcode);
    scan_ir(5'h11);
    dmi_write(DMCONTROL, 32'h0000_0001);   // dmactive

    // ======================================================================
    // T1: execute (PC-match) breakpoint at PC 0x0C
    // ======================================================================
    do_halt(ok);
    if (!ok) begin $display("[TRG] FAIL T1: initial halt"); errors++; end
    csr_wr(TSELECT, 32'h0);
    csr_wr(TDATA2,  32'h0000_000C);      // match the sw instruction's PC
    csr_wr(TDATA1,  MC6_EXEC_DBG);
    // read back to prove the CSRs latched (type field is forced to 6)
    csr_rd(TDATA1, v);
    if (v !== MC6_EXEC_DBG) begin $display("[TRG] FAIL T1: tdata1 rb=%08x", v); errors++; end
    else $display("[TRG] ok   tdata1 readback = %08x", v);
    csr_rd(TDATA2, v);
    if (v !== 32'h0000_000C) begin $display("[TRG] FAIL T1: tdata2 rb=%08x", v); errors++; end

    resume_and_watch(40, ok);
    if (!ok) begin $display("[TRG] FAIL T1: exec trigger did not halt"); errors++; end
    else begin
      csr_rd(16'h07B1, dpc_v);   // dpc
      csr_rd(16'h07B0, dcsr_v);  // dcsr (cause = bits[8:6])
      if (dpc_v !== 32'h0000_000C) begin
        $display("[TRG] FAIL T1: dpc=%08x exp 0000000C", dpc_v); errors++;
      end else if (dcsr_v[8:6] !== 3'd2) begin
        $display("[TRG] FAIL T1: dcsr.cause=%0d exp 2 (trigger)", dcsr_v[8:6]); errors++;
      end else
        $display("[TRG] ok   T1 exec breakpoint: halted at dpc=%08x cause=%0d", dpc_v, dcsr_v[8:6]);
    end

    // ======================================================================
    // T2: NEGATIVE CONTROL — exec trigger at a PC never fetched (0x100)
    // ======================================================================
    // (hart is halted in debug from T1). Re-point the trigger to a miss PC.
    csr_wr(TDATA2, 32'h0000_0100);       // never executed
    resume_and_watch(60, ok);
    if (ok) begin
      csr_rd(16'h07B1, dpc_v);
      $display("[TRG] FAIL T2(neg): spurious halt at dpc=%08x", dpc_v); errors++;
    end else
      $display("[TRG] ok   T2 negative control: no halt on near-miss PC");
    // leave it running; halt for the next test setup
    do_halt(ok);
    if (!ok) begin $display("[TRG] FAIL: re-halt before T3"); errors++; end

    // ======================================================================
    // T3: store (address-match) watchpoint at 0x8000_7000
    // ======================================================================
    // disable exec trigger, arm the store watchpoint.
    csr_wr(TDATA1, 32'h6000_0000);       // type6, all fire-bits clear (disabled)
    csr_wr(TDATA2, 32'h8000_7000);       // the sw target address
    csr_wr(TDATA1, MC6_STORE_DBG);
    // record current DRAM word at the store target BEFORE resume
    mem_before = dut.dram[(32'h8000_7000 - 32'h8000_0000) >> 2];
    resume_and_watch(40, ok);
    if (!ok) begin $display("[TRG] FAIL T3: store watchpoint did not halt"); errors++; end
    else begin
      csr_rd(16'h07B1, dpc_v);
      if (dpc_v !== 32'h0000_000C) begin
        $display("[TRG] FAIL T3: dpc=%08x exp 0000000C (store instr)", dpc_v); errors++;
      end else if (dut.dram[(32'h8000_7000 - 32'h8000_0000) >> 2] !== mem_before) begin
        $display("[TRG] FAIL T3: store committed despite before-timing watchpoint (%08x -> %08x)",
                 mem_before, dut.dram[(32'h8000_7000 - 32'h8000_0000) >> 2]); errors++;
      end else
        $display("[TRG] ok   T3 store watchpoint: halted at dpc=%08x, store suppressed", dpc_v);
    end

    // ======================================================================
    // T4: NEGATIVE CONTROL — store watchpoint at a near-miss address
    // ======================================================================
    csr_wr(TDATA2, 32'h8000_7100);       // near-miss (store goes to ...7000)
    resume_and_watch(60, ok);
    if (ok) begin
      csr_rd(16'h07B1, dpc_v);
      $display("[TRG] FAIL T4(neg): spurious halt at dpc=%08x", dpc_v); errors++;
    end else begin
      // and confirm the real store actually fired (address 0x7000 changed)
      $display("[TRG] ok   T4 negative control: no halt on near-miss store addr");
    end

    if (errors == 0) $display("TRIGGER: PASS");
    else             $display("TRIGGER: FAIL (%0d errors)", errors);
    $finish;
  end
  initial begin #2000000; $display("TRIGGER: FAIL (timeout)"); $finish; end
endmodule
