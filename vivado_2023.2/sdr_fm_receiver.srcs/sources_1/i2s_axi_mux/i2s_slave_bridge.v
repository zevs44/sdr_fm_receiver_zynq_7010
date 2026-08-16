`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 14.08.2026
// Design Name:
// Module Name: i2s_slave_bridge
// Project Name:
// Target Devices: Zynq-7010
// Tool Versions: Vivado 2023.2
// Description: I2S master-source -> I2S slave-sink bridge.
//              Deserializes an incoming I2S stream that carries its own
//              (asynchronous) BCLK/LRCLK, buffers the L/R sample pair across
//              the clock domain boundary, and re-serializes it onto a
//              *foreign* BCLK/LRCLK pair supplied by an external I2S master
//              (e.g. axi_i2s_adi, which can only operate as a master).
//              This module therefore acts as an I2S SLAVE transmitter:
//              it drives SDATA only, all clocks are inputs.
//
// Dependencies: none
//
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
//   * Standard I2S framing only (SDATA delayed by one BCLK after the LRCLK
//     edge, MSB first, LRCLK low = left channel).
//   * Source and sink run at unrelated sample rates. Sample-and-hold
//     (double-buffered "latest complete frame") is used, so a rate mismatch
//     shows up as an occasional repeated or dropped frame, NOT as a click
//     train or channel swap. Use identical nominal sample rates on both
//     sides to keep that rate low.
//   * If the source stops clocking, the last received frame is held (DC).
//////////////////////////////////////////////////////////////////////////////////

module i2s_slave_bridge #(
    // Number of significant bits per slot, MSB-first, MSB-aligned to the slot
    // start. Should be >= the number of significant bits of the source and
    // >= the SLOT_WIDTH of the sink; extra bits are emitted as trailing zeros
    // and extra source bits beyond DATA_WIDTH are ignored.
    parameter integer DATA_WIDTH = 32
) (
    input  wire                   aresetn,      // async active-low reset (AXI domain reset is fine)

    // --- Source side: external I2S master (all signals are inputs) ---
    input  wire                   src_bclk,
    input  wire                   src_lrclk,
    input  wire                   src_sdata,

    // --- Sink side: we are the SLAVE, clocks are driven by axi_i2s_adi ---
    input  wire                   slv_bclk,
    input  wire                   slv_lrclk,
    output wire                   slv_sdata     // -> axi_i2s_adi SDATA_I
);

    // =====================================================================
    // 1. Reset synchronizers (async assert, sync deassert) per clock domain
    // =====================================================================
    reg [1:0] src_rst_sync;
    always @(posedge src_bclk or negedge aresetn) begin
        if (!aresetn) src_rst_sync <= 2'b11;
        else          src_rst_sync <= {src_rst_sync[0], 1'b0};
    end
    wire src_rst = src_rst_sync[1];

    reg [1:0] slv_rst_sync;
    always @(posedge slv_bclk or negedge aresetn) begin
        if (!aresetn) slv_rst_sync <= 2'b11;
        else          slv_rst_sync <= {slv_rst_sync[0], 1'b0};
    end
    wire slv_rst = slv_rst_sync[1];

    // =====================================================================
    // 2. Deserializer (src_bclk domain)
    // =====================================================================
    // I2S timing recap: the transmitter changes LRCLK/SDATA on the falling
    // BCLK edge, the receiver samples on the rising edge, and LRCLK changes
    // one bit period BEFORE the MSB of the new word. Consequently the LSB of
    // the *previous* word is still sampled on the very rising edge at which
    // the LRCLK change becomes visible - that bit must be folded into the
    // word that has just finished, which is what slot_word below does.

    reg  [DATA_WIDTH-1:0]   cap_sh;        // capture shift register
    reg  [7:0]              bit_cnt;       // bits captured in the current slot
    reg                     src_lrclk_d;
    reg  [DATA_WIDTH-1:0]   samp_l;        // left slot of the frame in progress

    reg  [2*DATA_WIDTH-1:0] pp_buf [0:1];  // ping-pong frame buffer {L,R}
    reg                     wr_sel;        // buffer being written next

    wire                    ws_edge   = (src_lrclk != src_lrclk_d);
    wire [DATA_WIDTH-1:0]   slot_word = (bit_cnt < DATA_WIDTH) ?
                                        {cap_sh[DATA_WIDTH-2:0], src_sdata} : cap_sh;

    always @(posedge src_bclk) begin
        if (src_rst) begin
            cap_sh      <= {DATA_WIDTH{1'b0}};
            bit_cnt     <= 8'd0;
            src_lrclk_d <= 1'b0;
            samp_l      <= {DATA_WIDTH{1'b0}};
            wr_sel      <= 1'b0;
            pp_buf[0]   <= {(2*DATA_WIDTH){1'b0}};
            pp_buf[1]   <= {(2*DATA_WIDTH){1'b0}};
        end else begin
            src_lrclk_d <= src_lrclk;

            if (ws_edge) begin
                // The slot that has just ended belonged to channel src_lrclk_d
                // (LRCLK low = left).
                if (src_lrclk_d == 1'b0) begin
                    samp_l <= slot_word;                    // left half stored
                end else begin
                    // Right slot done -> the frame is complete, publish it.
                    pp_buf[wr_sel] <= {samp_l, slot_word};
                    wr_sel         <= ~wr_sel;
                end
                cap_sh  <= {DATA_WIDTH{1'b0}};
                bit_cnt <= 8'd0;
            end else if (bit_cnt < DATA_WIDTH) begin
                cap_sh  <= {cap_sh[DATA_WIDTH-2:0], src_sdata};
                bit_cnt <= bit_cnt + 8'd1;
            end
        end
    end

    // =====================================================================
    // 3. Clock domain crossing
    // =====================================================================
    // Only the single-bit wr_sel crosses domains. The reader always reads the
    // buffer the writer is NOT going to touch next, so the payload is stable
    // while it is being read - no multi-bit synchronizer, no FIFO, no
    // handshake latency. Worst case the reader sees a frame one period old.

    reg  slv_wr_sel_s0, slv_wr_sel_s1;
    always @(posedge slv_bclk) begin
        if (slv_rst) begin
            slv_wr_sel_s0 <= 1'b0;
            slv_wr_sel_s1 <= 1'b0;
        end else begin
            slv_wr_sel_s0 <= wr_sel;
            slv_wr_sel_s1 <= slv_wr_sel_s0;
        end
    end

    wire                    rd_idx   = ~slv_wr_sel_s1;
    wire [2*DATA_WIDTH-1:0] frame_rd = pp_buf[rd_idx];

    // =====================================================================
    // 4. Slave serializer (slv_bclk domain, clocks come from axi_i2s_adi)
    // =====================================================================
    // LRCLK is sampled on the rising edge (where it is guaranteed stable,
    // since the master changes it on the falling edge), the shift register is
    // updated on the rising edge, and SDATA is registered on the FALLING edge
    // so that the master samples a settled value on its next rising edge.
    // This yields exactly the one-BCLK I2S data delay.

    reg                     slv_lrclk_d;
    reg  [DATA_WIDTH-1:0]   sh;
    reg  [DATA_WIDTH-1:0]   hold_r;        // right half of the latched frame
    reg                     sd_q;

    always @(posedge slv_bclk) begin
        if (slv_rst) begin
            slv_lrclk_d <= 1'b0;
            sh          <= {DATA_WIDTH{1'b0}};
            hold_r      <= {DATA_WIDTH{1'b0}};
        end else begin
            slv_lrclk_d <= slv_lrclk;

            if (slv_lrclk != slv_lrclk_d) begin
                if (slv_lrclk == 1'b0) begin
                    // Falling LRCLK = start of the LEFT slot: latch a whole
                    // frame here so that L and R always come from the same
                    // sample pair.
                    sh     <= frame_rd[2*DATA_WIDTH-1 -: DATA_WIDTH];
                    hold_r <= frame_rd[DATA_WIDTH-1:0];
                end else begin
                    sh     <= hold_r;
                end
            end else begin
                sh <= {sh[DATA_WIDTH-2:0], 1'b0};   // trailing zeros past DATA_WIDTH
            end
        end
    end

    always @(negedge slv_bclk) begin
        if (slv_rst) sd_q <= 1'b0;
        else         sd_q <= sh[DATA_WIDTH-1];
    end

    assign slv_sdata = sd_q;

endmodule
