// =============================================================================
// FILE  : i2s_ds_dac_top.v
// BRIEF : Top-level wrapper.
//         Connects i2s_receiver → audio_sample_buffer → delta_sigma_dac.
//
//  ┌─────────────────────────────────────────────────────────────┐
//  │                     i2s_ds_dac_top                          │
//  │                                                             │
//  │  i2s_bclk  ─►┌──────────────┐  sample_valid ┌──────────┐   │
//  │  i2s_lrclk─►│ i2s_receiver │──left_data────►│  audio   │   │
//  │  i2s_sdata─►│              │──right_data───►│  sample  │──►│── dac_out
//  │             └──────────────�?               │  buffer  │   │
//  │                                            └──────────�?   │
//  │                                                │           │
//  │                                        ┌──────────────┐   │
//  │                                        │delta_sigma   │   │
//  │                                        │    _dac      │──►│
//  │                                        └──────────────�?   │
//  └─────────────────────────────────────────────────────────────�?
//
// TYPICAL ZYNQ-7010 INSTANTIATION
//   • clk   ← FCLK_CLK0  (100 MHz from PS, or MMCM output)
//   • rst_n ← FCLK_RESET0_N  (PS reset, active-low)
//   • i2s_* ← outputs of axi_i2s_adi PL peripheral
//   • dac_out → FPGA I/O pins → RC low-pass filter → audio output
//
// SUGGESTED XDC CONSTRAINTS
//   # Mark CDC synchroniser chains (prevents false timing violations)
//   set_property ASYNC_REG TRUE \
//     [get_cells -hier -filter {NAME =~ *u_rx*bclk_sync_reg*}]
//   set_property ASYNC_REG TRUE \
//     [get_cells -hier -filter {NAME =~ *u_rx*lrclk_sync_reg*}]
//   set_property ASYNC_REG TRUE \
//     [get_cells -hier -filter {NAME =~ *u_rx*sdata_sync_reg*}]
//
//   # Optional: put PDM outputs in IOBs to reduce switching jitter
//   set_property IOB TRUE \
//     [get_cells -hier -filter {NAME =~ *u_dac*gen_mod*dac_r_reg*}]
// =============================================================================
`timescale 1ns / 1ps

module i2s_ds_dac_top #(
    parameter NUM_SDATA_LINES  = 1,   // I2S data lines (1 line = stereo pair)
    parameter AUDIO_DATA_WIDTH = 24,  // Bits per channel
    parameter DS_ORDER         = 2    // Delta-Sigma order: 1, 2, or 3
)(
    // System clock & active-low reset (Zynq PS or MMCM)
    input  wire clk,
    input  wire rst_n,

    // I2S interface (from AXI I2S ADI or equivalent)
    input  wire                       i2s_bclk,
    input  wire                       i2s_lrclk,
    input  wire [NUM_SDATA_LINES-1:0] i2s_sdata,

    // 1-bit PDM outputs to DAC RC filter
    // Index: [2g] = line g LEFT,  [2g+1] = line g RIGHT
    output wire [(NUM_SDATA_LINES*2)-1:0] dac_out
);

  localparam W = AUDIO_DATA_WIDTH;

  // Internal buses
  wire [(NUM_SDATA_LINES*W)-1:0] rx_left,  rx_right;
  wire                           rx_valid;

  wire [(NUM_SDATA_LINES*W)-1:0] buf_left, buf_right;
  wire                           buf_valid;  // available for ILA/debug

  // ---------------------------------------------------------------------------
  // Stage 1 — I2S Receiver
  // ---------------------------------------------------------------------------
  i2s_receiver_ds #(
    .NUM_SDATA_LINES  (NUM_SDATA_LINES),
    .AUDIO_DATA_WIDTH (AUDIO_DATA_WIDTH)
  ) u_rx (
    .clk          (clk),
    .rst_n        (rst_n),
    .i2s_bclk     (i2s_bclk),
    .i2s_lrclk    (i2s_lrclk),
    .i2s_sdata    (i2s_sdata),
    .left_data    (rx_left),
    .right_data   (rx_right),
    .sample_valid (rx_valid)
  );

  // ---------------------------------------------------------------------------
  // Stage 2 — Sample Buffer (register boundary)
  // ---------------------------------------------------------------------------
  audio_sample_buffer #(
    .NUM_SDATA_LINES  (NUM_SDATA_LINES),
    .AUDIO_DATA_WIDTH (AUDIO_DATA_WIDTH)
  ) u_buf (
    .clk      (clk),
    .rst_n    (rst_n),
    .wr_left  (rx_left),
    .wr_right (rx_right),
    .wr_valid (rx_valid),
    .rd_left  (buf_left),
    .rd_right (buf_right),
    .rd_valid (buf_valid)
  );

  // ---------------------------------------------------------------------------
  // Stage 3 — Delta-Sigma DAC
  // ---------------------------------------------------------------------------
  delta_sigma_dac #(
    .NUM_SDATA_LINES  (NUM_SDATA_LINES),
    .AUDIO_DATA_WIDTH (AUDIO_DATA_WIDTH),
    .DS_ORDER         (DS_ORDER)
  ) u_dac (
    .clk        (clk),
    .rst_n      (rst_n),
    .left_data  (buf_left),
    .right_data (buf_right),
    .dac_out    (dac_out)
  );

endmodule
