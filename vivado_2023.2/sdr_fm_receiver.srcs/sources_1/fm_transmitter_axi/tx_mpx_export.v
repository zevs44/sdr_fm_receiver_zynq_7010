`timescale 1ns / 1ps
// =============================================================================
// Module : tx_mpx_export
// Purpose: Exports the transmitter's own MPX composite over AXI4-Lite, the
//          same way axi_sdr_fm.v exports the receiver's. Lets you capture what
//          fm_transmitter_axi actually generates, BEFORE the RF NCO, the
//          antenna, the receiver front end and the receiver's discriminator --
//          so a failure can be attributed to the DSP or to the RF path rather
//          than guessed at.
//
//   RATE: mpx is produced at clk_audio (12.288 MHz), far too fast to poll over
//         AXI4-Lite. Decimated by 48, which gives EXACTLY 256000 Hz
//         (12288000/48) -- an integer rate, so no fractional-rate bookkeeping
//         in the analysis tools. Feed captures to redsea with -r 256000.
//         57 kHz sits comfortably below the 128 kHz Nyquist.
//
//   FILTER: reuses the project's cic_decimator, N_STAGES=3. Passband droop is
//         -0.3 dB at 19 kHz and -2.3 dB at 57 kHz -- irrelevant for a
//         diagnostic capture, and the alias rejection matters more here since
//         the sine LUT's own harmonic distortion products land above 128 kHz.
//
//   SCALING: B_IN=24 / N_STAGES=3 / R_DEC=48 / B_OUT=24 / GUARD_BITS=0 gives
//         B_MAX = 24 + 3*6 - 1 = 41 and DISCARD = 17, i.e. a net CIC gain of
//         48^3/2^17 = 0.84375, so a full-scale mpx (8388607) leaves the CIC as
//         7077887 and cannot overflow the 24-bit output. The export stage then
//         applies a runtime right shift and saturates to signed 16 bits:
//         at the default shift of 8, full-scale mpx maps to +/-27648, i.e.
//         84% of int16 full scale, with headroom left for the clipping the
//         mpx summer can produce.
//
//   CDC: the CIC runs in clk_audio, the FIFO and AXI in s_axi_aclk. One
//        toggle handshake per decimated sample, the same scheme
//        fm_transmitter_axi already uses for mpx and tuning_word. At 256 kHz
//        there are ~195 s_axi_aclk cycles (at 50 MHz) between samples, so the
//        handshake has an enormous margin. The runtime shift is applied on
//        the s_axi_aclk side, so the shift register itself never crosses
//        domains.
// =============================================================================
module tx_mpx_export #(
    parameter integer DEC_R      = 48,     // 12.288 MHz -> 256 kHz exactly
    parameter integer FIFO_DEPTH = 1024,   // power of 2; 4 ms of slack at 256 kHz
    parameter integer FIFO_ADDR_W = 10     // $clog2(FIFO_DEPTH)
)(
    // ---- clk_audio domain ----
    input  wire                     clk_audio,
    input  wire                     rst_n_audio,
    input  wire signed [23:0]       mpx_in,        // the transmitter's mpx register

    // ---- s_axi_aclk domain ----
    input  wire                     s_axi_aclk,
    input  wire                     s_axi_aresetn,
    input  wire [3:0]               shift,         // MPX_SHIFT register
    input  wire                     rd_pop,        // read of MPX_FIFO_DATA
    input  wire                     clr_overflow,  // read of MPX_FIFO_STAT
    output wire signed [15:0]       rd_data,
    output wire [FIFO_ADDR_W:0]     count,
    output wire                     empty,
    output wire                     overflow_flag
);

    // ---- decimation, clk_audio ----
    wire signed [23:0] dec_data;
    wire               dec_valid;

    cic_decimator #(
        .B_IN(24), .N_STAGES(3), .R_DEC(DEC_R), .B_OUT(24), .GUARD_BITS(0)
    ) u_tx_mpx_cic (
        .clk      (clk_audio),
        .rst_n    (rst_n_audio),
        .data_in  (mpx_in),
        .valid_in (1'b1),           // mpx is valid on every clk_audio cycle
        .data_out (dec_data),
        .valid_out(dec_valid)
    );

    // ---- toggle handshake into s_axi_aclk ----
    reg signed [23:0] dec_hold;
    reg               dec_toggle;
    always @(posedge clk_audio) begin
        if (!rst_n_audio) begin
            dec_hold   <= 24'sd0;
            dec_toggle <= 1'b0;
        end else if (dec_valid) begin
            dec_hold   <= dec_data;
            dec_toggle <= ~dec_toggle;
        end
    end

    (* ASYNC_REG = "TRUE" *) reg [2:0] tog_sync;
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) tog_sync <= 3'b000;
        else                tog_sync <= {tog_sync[1:0], dec_toggle};
    end
    wire sample_stb = tog_sync[2] ^ tog_sync[1];

    // ---- runtime shift + saturate to signed 16 bits, s_axi_aclk ----
    wire signed [23:0] shifted = dec_hold >>> shift;
    localparam signed [23:0] POS_MAX =  24'sd32767;
    localparam signed [23:0] NEG_MIN = -24'sd32768;
    wire signed [15:0] sat = (shifted > POS_MAX) ?  16'sd32767 :
                             (shifted < NEG_MIN) ? -16'sd32768 :
                                                    shifted[15:0];

    reg signed [15:0] wr_data_r;
    reg               wr_en_r;
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            wr_data_r <= 16'sd0;
            wr_en_r   <= 1'b0;
        end else begin
            wr_en_r <= sample_stb;
            if (sample_stb) wr_data_r <= sat;
        end
    end

    // ---- FIFO (the project's existing mpx_sample_fifo, reused verbatim) ----
    mpx_sample_fifo #(.DEPTH(FIFO_DEPTH), .DATA_W(16)) u_tx_mpx_fifo (
        .clk          (s_axi_aclk),
        .rst_n        (s_axi_aresetn),
        .wr_en        (wr_en_r),
        .wr_data      (wr_data_r),
        .rd_pop       (rd_pop),
        .rd_data      (rd_data),
        .count        (count),
        .empty        (empty),
        .clr_overflow (clr_overflow),
        .overflow_flag(overflow_flag)
    );

endmodule