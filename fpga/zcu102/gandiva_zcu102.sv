// ============================================================================
// gandiva_zcu102.sv — ZCU102 (xczu9eg-ffvb1156-2-e) PL top for Gandiva.
//
// TEMPLATE — verify pins/clocking against your ZCU102 board revision before
// building (see gandiva_zcu102.sv header for the clock/UART board notes).
// Drive `pl_clk` from a Clocking Wizard / PS pl_clk0 (set CLK_HZ to match);
// route uart_tx/uart_rx to a PMOD for a PL-only console.
// ============================================================================
`default_nettype none

module gandiva_zcu102 (
  input  wire       pl_clk,        // from Clocking Wizard / PS pl_clk0 (set CLK_HZ)
  input  wire       rst,           // active-high reset (GPIO push-button)
  output wire [7:0] led,           // 8 PL user LEDs
  input  wire       uart_rx,       // host -> FPGA (PMOD)
  output wire       uart_tx        // FPGA -> host (PMOD), 115200-8N1
);
  wire sys_rst;
  gandiva_reset_sync #(.DEPTH(3), .ACTIVE_HIGH(1'b1)) u_rst (
      .clk(pl_clk), .async_rst_in(rst), .sync_rst_out(sys_rst));

  wire [7:0] soc_leds;
  gandiva_fpga #(.CLK_HZ(100_000_000), .UART_BAUD(115_200),
                  .MEM_WORDS(4096), .MEMFILE("firmware.mem")) u_soc (
      .clk(pl_clk), .rst(sys_rst),
      .leds(soc_leds), .serial_tx(uart_tx), .serial_rx(uart_rx),
      .tohost(), .tohost_we()
  );

  assign led = soc_leds;
endmodule

`default_nettype wire
