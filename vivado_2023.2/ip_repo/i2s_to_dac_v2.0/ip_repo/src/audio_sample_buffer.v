// =============================================================================
// FILE  : audio_sample_buffer.v
// BRIEF : Single-register audio sample buffer.
//
//         Sits between i2s_receiver and delta_sigma_dac on the same <clk>
//         domain — no CDC required.  Its roles are:
//           1. Clean architectural boundary (receiver knows nothing about DAC).
//           2. Extra register stage for timing closure on wide data buses.
//           3. Extension point: swap for a small FIFO if interpolation or
//              sample-rate conversion is added later.
//
//         The DS modulator reads rd_left / rd_right continuously; it never
//         needs to stall waiting for new data (audio rate ≪ clk rate).
//         rd_valid is a 1-cycle strobe, provided for ILA / PS monitoring:
//
//           set_property MARK_DEBUG TRUE \
//             [get_nets -hier {u_buf/rd_valid}]
//
// ZYNQ-7010 NOTES
//   • With NUM_SDATA_LINES=1, AUDIO_DATA_WIDTH=24 this consumes 49 FFs.
//   • No BRAM inferred — data held in fabric registers (distributed).
// =============================================================================
`timescale 1ns / 1ps

module audio_sample_buffer #(
    parameter NUM_SDATA_LINES  = 1,
    parameter AUDIO_DATA_WIDTH = 24
)(
    input  wire clk,
    input  wire rst_n,

    // Write port — driven by i2s_receiver
    input  wire [(NUM_SDATA_LINES*AUDIO_DATA_WIDTH)-1:0] wr_left,
    input  wire [(NUM_SDATA_LINES*AUDIO_DATA_WIDTH)-1:0] wr_right,
    input  wire                                          wr_valid,

    // Read port — drives delta_sigma_dac
    output reg  [(NUM_SDATA_LINES*AUDIO_DATA_WIDTH)-1:0] rd_left,
    output reg  [(NUM_SDATA_LINES*AUDIO_DATA_WIDTH)-1:0] rd_right,
    output reg                                           rd_valid   // 1-cycle strobe
);

  localparam TOTAL_W = NUM_SDATA_LINES * AUDIO_DATA_WIDTH;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_left  <= {TOTAL_W{1'b0}};
      rd_right <= {TOTAL_W{1'b0}};
      rd_valid <= 1'b0;
    end else begin
      rd_valid <= 1'b0;          // default: deassert
      if (wr_valid) begin
        rd_left  <= wr_left;
        rd_right <= wr_right;
        rd_valid <= 1'b1;
      end
    end
  end

endmodule
