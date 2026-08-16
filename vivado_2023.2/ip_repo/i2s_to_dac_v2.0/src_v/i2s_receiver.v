// =============================================================================
// FILE  : i2s_receiver.v
// BRIEF : I2S serial receiver.
//         Synchronises i2s_bclk / i2s_lrclk / i2s_sdata from their
//         asynchronous clock domain into <clk>, then deserialises the
//         bitstream into signed parallel audio samples.
//
// PORTS (output side)
//   left_data  / right_data  — packed flat buses.
//                              Lane g occupies bits [(g+1)*W-1 : g*W].
//   sample_valid             — 1-cycle strobe, asserted when a complete
//                              stereo frame (left + right) has been latched.
//
// ZYNQ-7010 NOTES
//   • The (* ASYNC_REG = "TRUE" *) attribute marks CDC registers so that
//     Vivado does not analyse timing through them (prevents false violations).
//   • For the sdata_sync array, add an XDC constraint:
//       set_property ASYNC_REG TRUE \
//         [get_cells -hier -filter {NAME =~ *u_rx*sdata_sync_reg*}]
//   • Active-low async reset is fine for 7-series; to use synchronous reset,
//     change "or negedge rst_n" > remove, and add "if (!rst_n)" as the first
//     if-clause without the posedge guard.
// =============================================================================
`timescale 1ns / 1ps

module i2s_receiver_ds #(
    parameter NUM_SDATA_LINES  = 1,   // Physical I2S data lines (1 line = 2 ch)
    parameter AUDIO_DATA_WIDTH = 24   // Bits per channel (16 or 24 typical)
)(
    // System clock & reset
    input  wire clk,
    input  wire rst_n,

    // I2S bus — asynchronous to clk
    input  wire                       i2s_bclk,
    input  wire                       i2s_lrclk,
    input  wire [NUM_SDATA_LINES-1:0] i2s_sdata,

    // Parallel audio output — synchronous to clk
    output wire [(NUM_SDATA_LINES*AUDIO_DATA_WIDTH)-1:0] left_data,
    output wire [(NUM_SDATA_LINES*AUDIO_DATA_WIDTH)-1:0] right_data,
    output reg                                           sample_valid
);

  localparam W = AUDIO_DATA_WIDTH;
  integer ii;

  // ---------------------------------------------------------------------------
  // 1. Three-stage CDC synchronisers
  //    Shift direction: [2] = oldest (stable), [1] = 1-cycle, [0] = raw input
  // ---------------------------------------------------------------------------
  (* ASYNC_REG = "TRUE" *) reg [2:0] bclk_sync;
  (* ASYNC_REG = "TRUE" *) reg [2:0] lrclk_sync;
  // sdata_sync: mark with XDC (see file header — attributes on arrays are
  // tool-dependent; Vivado typically accepts the syntax below).
  (* ASYNC_REG = "TRUE" *) reg [2:0] sdata_sync [0:NUM_SDATA_LINES-1];

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bclk_sync  <= 3'b0;
      lrclk_sync <= 3'b0;
      for (ii = 0; ii < NUM_SDATA_LINES; ii = ii + 1)
        sdata_sync[ii] <= 3'b0;
    end else begin
      bclk_sync  <= {bclk_sync[1:0],  i2s_bclk};
      lrclk_sync <= {lrclk_sync[1:0], i2s_lrclk};
      for (ii = 0; ii < NUM_SDATA_LINES; ii = ii + 1)
        sdata_sync[ii] <= {sdata_sync[ii][1:0], i2s_sdata[ii]};
    end
  end

  // Rising edge of BCLK detected 1 system-clock cycle after the physical edge.
  // Bits [2:1] are used so both comparands have passed ?1 FF stage.
  wire bclk_rise = (bclk_sync[2:1] == 2'b01);

  // Fully-synchronised LRCLK value (2 FF stages > metastability safe).
  wire lrclk_syn = lrclk_sync[2];

  // SDATA is sampled via sdata_sync[i][1].
  // This is intentional: [1] was captured on the same system-clock cycle that
  // the BCLK rising edge entered bclk_sync[0], so it is time-aligned with the
  // I2S data that was valid at that edge.

  // ---------------------------------------------------------------------------
  // 2. I2S Deserialiser (Philips I2S: MSB arrives 1 BCLK after LRCLK edge)
  //
  //   On LRCLK transition  > latch the completed shift register, reset counter.
  //   On subsequent BCLKs  > shift bits into the active channel register.
  //                          bclk_cnt uses its OLD (pre-increment) value in the
  //                          if-condition (non-blocking semantics), so bits are
  //                          shifted for cnt = 0 … W-1 (W bits total).
  //
  //   sample_valid fires on LRCLK 1>0 (end of RIGHT channel), at which point
  //   both latch_l and latch_r hold a fresh, coherent stereo frame.
  // ---------------------------------------------------------------------------
  reg [7:0] bclk_cnt;
  reg       lrclk_prev;

  reg signed [W-1:0] shift_l [0:NUM_SDATA_LINES-1];
  reg signed [W-1:0] shift_r [0:NUM_SDATA_LINES-1];
  reg signed [W-1:0] latch_l [0:NUM_SDATA_LINES-1];
  reg signed [W-1:0] latch_r [0:NUM_SDATA_LINES-1];

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bclk_cnt     <= 8'd0;
      lrclk_prev   <= 1'b0;
      sample_valid <= 1'b0;
      for (ii = 0; ii < NUM_SDATA_LINES; ii = ii + 1) begin
        shift_l[ii] <= {W{1'b0}};
        shift_r[ii] <= {W{1'b0}};
        latch_l[ii] <= {W{1'b0}};
        latch_r[ii] <= {W{1'b0}};
      end
    end else begin
      sample_valid <= 1'b0;        // de-assert every cycle by default

      if (bclk_rise) begin

        if (lrclk_syn != lrclk_prev) begin
          // ------------------------------------------------------------------
          // LRCLK edge — end of the current channel word
          // ------------------------------------------------------------------
          lrclk_prev <= lrclk_syn;
          bclk_cnt   <= 8'd0;      // MSB of new word arrives on next BCLK

          if (lrclk_prev == 1'b0) begin
            // Was LEFT (0) > now RIGHT (1): latch completed left word
            for (ii = 0; ii < NUM_SDATA_LINES; ii = ii + 1)
              latch_l[ii] <= shift_l[ii];
          end else begin
            // Was RIGHT (1) > now LEFT (0): latch right, signal valid
            for (ii = 0; ii < NUM_SDATA_LINES; ii = ii + 1)
              latch_r[ii] <= shift_r[ii];
            sample_valid <= 1'b1;  // both latch_l and latch_r are now fresh
          end

        end else begin
          // ------------------------------------------------------------------
          // Steady-state — accumulate serial bits
          // ------------------------------------------------------------------
          bclk_cnt <= bclk_cnt + 1'b1;

          // Uses OLD bclk_cnt value > valid for cnt = 0 … W-1
          if (bclk_cnt < W) begin
            if (lrclk_prev == 1'b0) begin   // receiving LEFT
              for (ii = 0; ii < NUM_SDATA_LINES; ii = ii + 1)
                shift_l[ii] <= {shift_l[ii][W-2:0], sdata_sync[ii][1]};
            end else begin                  // receiving RIGHT
              for (ii = 0; ii < NUM_SDATA_LINES; ii = ii + 1)
                shift_r[ii] <= {shift_r[ii][W-2:0], sdata_sync[ii][1]};
            end
          end
        end

      end
    end
  end

  // ---------------------------------------------------------------------------
  // 3. Pack internal 2-D arrays > flat output ports
  //    Lane g > bits [(g+1)*W-1 : g*W]
  // ---------------------------------------------------------------------------
  genvar g;
  generate
    for (g = 0; g < NUM_SDATA_LINES; g = g + 1) begin : gen_out
      assign left_data [(g+1)*W-1 : g*W] = latch_l[g];
      assign right_data[(g+1)*W-1 : g*W] = latch_r[g];
    end
  endgenerate

endmodule
