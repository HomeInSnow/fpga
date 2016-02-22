//
// Copyright 2016 Ettus Research LLC
//
// Note: Register addresses defined radio_core_regs.vh

module db_control #(
  // Drive SPI core with input spi_clk instead of ce_clk. This is useful if ce_clk is very slow which
  // would cause spi transactions to take a long time. WARNING: This adds a clock crossing FIFO!
  parameter USE_SPI_CLK = 0
)(
  // Commands from Radio Core
  input clk, input reset,
  input set_stb, input [7:0] set_addr, input [31:0] set_data,
  output reg rb_stb, input [7:0] rb_addr, output reg [63:0] rb_data,
  input run_rx, input run_tx,
  // Frontend / Daughterboard I/O
  input [31:0] misc_ins, output [31:0] misc_outs, output sync,
  input [31:0] fp_gpio_in, output [31:0] fp_gpio_out, output [31:0] fp_gpio_ddr,
  input [31:0] db_gpio_in, output [31:0] db_gpio_out, output [31:0] db_gpio_ddr,
  output [31:0] leds,
  input spi_clk, input spi_rst, output [7:0] sen, output sclk, output mosi, input miso
);
  `include "radio_core_regs.vh"

  /********************************************************
  ** Settings registers
  ********************************************************/
  setting_reg #(.my_addr(SR_MISC_OUTS), .width(32)) sr_misc_outs (
    .clk(clk), .rst(reset),
    .strobe(set_stb), .addr(set_addr), .in(set_data),
    .out(misc_outs), .changed());

  setting_reg #(.my_addr(SR_SYNC), .width(1)) sr_sync (
    .clk(clk), .rst(reset),
    .strobe(set_stb), .addr(set_addr), .in(set_data),
    .out(), .changed(sync));

  // Readback
  wire spi_ready_sync;
  wire [7:0] spi_readback_sync;
  wire [31:0] fp_gpio_readback, db_gpio_readback, leds_readback;
  always @* begin
    case(rb_addr)
      RB_MISC_IO  : {rb_stb, rb_data} <= {          1'b1, {misc_ins, misc_outs}};
      // Use spi ready (instead of a strobe) so delayed readbacks after a SPI transaction will work
      RB_SPI      : {rb_stb, rb_data} <= {spi_ready_sync, {32'd0, 24'd0, spi_readback_sync}};
      RB_LEDS     : {rb_stb, rb_data} <= {          1'b1, {32'd0, leds}};
      RB_DB_GPIO  : {rb_stb, rb_data} <= {          1'b1, {32'd0, db_gpio_readback}};
      RB_FP_GPIO  : {rb_stb, rb_data} <= {          1'b1, {32'd0, fp_gpio_readback}};
      default     : {rb_stb, rb_data} <= {          1'b1, {64'h0BADC0DE0BADC0DE}};
    endcase
  end

  /********************************************************
  ** GPIO
  ********************************************************/
  gpio_atr #(.BASE(SR_LEDS), .WIDTH(32), .DEFAULT_DDR(32'hFFFF_FFFF), .DEFAULT_IDLE(32'd0)) leds_gpio_atr (
    .clk(clk), .reset(reset),
    .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
    .rx(run_rx), .tx(run_tx),
    .gpio_in(32'd0), .gpio_out(leds), .gpio_ddr(/*unused, assumed output only*/), .gpio_sw_rb(leds_readback));

  gpio_atr #(.BASE(SR_FP_GPIO), .WIDTH(32), .DEFAULT_DDR(32'hFFFF_FFFF), .DEFAULT_IDLE(32'd0)) fp_gpio_atr (
    .clk(clk), .reset(reset),
    .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
    .rx(run_rx), .tx(run_tx),
    .gpio_in(fp_gpio_in), .gpio_out(fp_gpio_out), .gpio_ddr(fp_gpio_ddr), .gpio_sw_rb(fp_gpio_readback));

  gpio_atr #(.BASE(SR_DB_GPIO), .WIDTH(32), .DEFAULT_DDR(32'hFFFF_FFFF), .DEFAULT_IDLE(32'd0)) db_gpio_atr (
    .clk(clk), .reset(reset),
    .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
    .rx(run_rx), .tx(run_tx),
    .gpio_in(db_gpio_in), .gpio_out(db_gpio_out), .gpio_ddr(db_gpio_ddr), .gpio_sw_rb(db_gpio_readback));

  /********************************************************
  ** SPI
  ********************************************************/
  wire spi_set_stb, spi_ready;
  wire [7:0] spi_set_addr;
  wire [31:0] spi_set_data;
  wire [7:0] spi_readback;
  wire spi_clk_int, spi_rst_int;
  genvar i;
  generate
    if (USE_SPI_CLK) begin
      settings_bus_crossclock #(
        .FLOW_CTRL(1),
        .SR_AWIDTH(8),
        .SR_DWIDTH(32),
        .RB_DWIDTH(9))
      settings_bus_crossclock (
        .clk_a(clk), .rst_a(reset),
        .set_stb_a(set_stb), .set_addr_a(set_addr), .set_data_a(set_data),
        .rb_stb_a(), .rb_addr_a('d0), .rb_data_a(),
        .rb_ready(1'b1),
        .clk_b(spi_clk), .rst_b(spi_rst),
        .set_stb_b(spi_set_stb), .set_addr_b(spi_set_addr), .set_data_b(spi_set_data),
        .rb_stb_b(), .rb_addr_b(), .rb_data_b(),
        .set_ready(spi_ready));

      synchronizer #(.STAGES(3), .INITIAL_VAL(1'b0)) synchronizer_spi_ready (
        .clk(clk), .rst(reset), .in(spi_ready), .out(spi_ready_sync));
      for (i = 0; i < 8; i = i + 1) begin
        synchronizer #(.STAGES(3), .INITIAL_VAL(1'b0)) synchronizer_spi_readback (
          .clk(clk), .rst(reset), .in(spi_readback[i]), .out(spi_readback_sync[i]));
      end

      assign spi_clk_int       = spi_clk;
      assign spi_rst_int       = spi_rst;
    end else begin
      assign spi_set_stb       = set_stb;
      assign spi_set_addr      = set_addr;
      assign spi_set_data      = set_data;
      assign spi_readback_sync = spi_readback;
      assign spi_ready_sync    = spi_ready;
      assign spi_clk_int       = clk;
      assign spi_rst_int       = reset;
    end
  endgenerate

  simple_spi_core #(.BASE(SR_SPI), .WIDTH(8), .CLK_IDLE(0), .SEN_IDLE(8'hFF)) simple_spi_core (
    .clock(spi_clk_int), .reset(spi_rst_int),
    .set_stb(spi_set_stb), .set_addr(spi_set_addr), .set_data(spi_set_data),
    .readback(spi_readback), .readback_stb(), .ready(spi_ready),
    .sen(sen), .sclk(sclk), .mosi(mosi), .miso(miso),
    .debug());

endmodule