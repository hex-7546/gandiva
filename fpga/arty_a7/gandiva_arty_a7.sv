// ============================================================================
// gandiva_arty_a7.sv — Digilent Arty A7-100T top for the Gandiva SoC.
// Device: xc7a100tcsg324-1.  Runs directly at the board 100 MHz oscillator.
//
//   CLK100        E3    ck_rst  C2 (active-low)
//   led[3:0]      H5 J5 T9 T10   (firmware walking-1 pattern)
//   uart_txd_in   A9 (RX)        uart_rxd_out D10 (TX), 115200-8N1
//
// Provide sw/firmware.mem to the Vivado project as "firmware.mem".
// ============================================================================
`default_nettype none

module gandiva_arty_a7 (
  input  wire       CLK100,
  input  wire       ck_rst,        // active-low
  output wire [3:0] led,
  input  wire       uart_txd_in,   // RX
  output wire       uart_rxd_out   // TX
);
  // Divide 100MHz to 25MHz to meet setup timing (max freq is ~42MHz)
  reg [1:0] clk_div = 0;
  always @(posedge CLK100) clk_div <= clk_div + 1;
  wire sys_clk;
  BUFG u_bufg (.I(clk_div[1]), .O(sys_clk));

  wire sys_rst;
  gandiva_reset_sync #(.DEPTH(3), .ACTIVE_HIGH(1'b1)) u_rst (
      .clk(sys_clk), .async_rst_in(~ck_rst), .sync_rst_out(sys_rst));

  wire [7:0] soc_leds;
  gandiva_fpga #(.CLK_HZ(25_000_000), .UART_BAUD(115_200),
                  .MEM_WORDS(16384), .MEMFILE("firmware.mem")) u_soc (
      .clk(sys_clk), .rst(sys_rst),
      .leds(soc_leds), .serial_tx(uart_rxd_out), .serial_rx(uart_txd_in),
      .tohost(), .tohost_we()
  );

  assign led = soc_leds[3:0];
endmodule

`default_nettype wire
