`timescale 1ns / 1ps
// =============================================================================
// Module : fm_ddc_mixer
// Purpose: Digital down-converter -- translates the selected station to
//          baseband. Runs at 250 MHz (T = 4.0 ns).
//
// Phase accumulator (Stage 1): a plain 32-bit adder, not a carry-select
// structure. On 7-series devices CARRY4 is already a dedicated fast carry
// path (roughly 0.114 ns/bit of hop rate, as also holds for cic_decimator);
// splitting the adder into low/high segments with a select mux between them
// adds a multiplexer and inter-segment routing that costs more than the
// parallel precomputation saves. Overflow of the 32-bit unsigned addition
// is expected NCO behaviour (the phase accumulator wraps modulo 2^32 by
// design -- that wraparound is the DDS mechanism, not a bug).
//
// Half-wave ROM symmetry (Stage 2): the sin/cos table is stored as a
// 128-entry half-period table rather than a full 256-entry table, using
// sin(phi+180 deg) = -sin(phi), cos(phi+180 deg) = -cos(phi). On 7-series
// distributed RAM, a 256-deep table needs 4x RAM64X1S plus 2xMUXF7+1xMUXF8
// (two mux levels); the 128-deep table needs only 2x RAM64X1S + 1xMUXF7
// (one mux level) -- faster by one MUXF8 delay and half the LUT6 storage.
// The angular step denominator in the table-fill formula must stay 256.0
// (not 128.0), or the DDS frequency would be off by a factor of 2.
//
// Sign merge (Stage 3/4): because Stage 3 already computes both signs of
// each product (+cos_ext/-cos_ext, +sin_ext/-sin_ext), the final output mux
// in Stage 4 only needs a single combined select signal
// (sel = rf_bit XOR h_bit, where h_bit is the half-period bit from the
// half-wave lookup) -- no extra arithmetic is needed on the Stage 4
// critical path. The XOR is computed in parallel with the Stage 3 negation
// rather than after it, so it does not add to that path's depth.
//
// Pipeline: 4 stages, 4 cycles of latency, unchanged throughout:
//   Stage 1: 32-bit phase accumulator (plain adder) + register rf_bit
//   Stage 2: half-wave ROM (128x8, LUTRAM) + register rf/h/valid
//   Stage 3: pre-compute +-cos/+-sin (9-bit) + sel = rf^h (parallel XOR)
//   Stage 4: plain 2:1 output mux, selected by sel
// =============================================================================
module fm_ddc_mixer (
    input  wire         clk,          // 250 MHz
    input  wire         rst_n,        // Async active-low reset
    input  wire         rf_bit,       // 1-bit RF input (1 = +1, 0 = -1)
    input  wire [31:0]  tuning_word,  // Tuning frequency code (from PS)

    output reg  signed [8:0] i_out,   // In-phase  (I) -> CIC filter
    output reg  signed [8:0] q_out,   // Quadrature(Q) -> CIC filter
    output reg               valid_out
);

    // =========================================================================
    // Stage 1 - phase accumulator (plain 32-bit adder) + capture rf_bit
    // =========================================================================
    reg [31:0] phase_acc;

    (* SHREG_EXTRACT = "NO" *)          // Disallow SRL inference: a plain FF is required here
    reg rf_r1;
    reg valid_r1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase_acc <= 32'd0;
            rf_r1     <= 1'b0;
            valid_r1  <= 1'b0;
        end else begin
            phase_acc <= phase_acc + tuning_word;  // wraps mod 2^32 by design -- the DDS mechanism
            rf_r1     <= rf_bit;
            valid_r1  <= 1'b1;
        end
    end

    // =========================================================================
    // Stage 2 - ROM half-wave lookup (128x8, LUTRAM) + delay rf/h/valid
    // -------------------------------------------------------------------------
    // ram_style="distributed" forces deterministic inference as 128x8
    // LUTRAM (2xRAM64X1S + 1xMUXF7, one mux level less than the 256-deep
    // table would need).
    // =========================================================================
    (* ram_style = "distributed" *)
    reg signed [7:0] sin_lut_half [0:127];
    (* ram_style = "distributed" *)
    reg signed [7:0] cos_lut_half [0:127];

    integer k;
    initial begin
        for (k = 0; k < 128; k = k + 1) begin
            // Denominator is 256.0 -- do not change to 128.0 (see header)
            sin_lut_half[k] = $rtoi(127.0 * $sin(2.0 * 3.14159265358979 * k / 256.0));
            cos_lut_half[k] = $rtoi(127.0 * $cos(2.0 * 3.14159265358979 * k / 256.0));
        end
    end

    wire [6:0] addr  = phase_acc[30:24];   // 7-bit address (first half-period)
    wire       h_bit = phase_acc[31];      // second half-period bit

    reg signed [7:0] sin_r2;
    reg signed [7:0] cos_r2;

    // ROM read: kept in its own posedge-only block for clean LUTRAM inference
    always @(posedge clk) begin
        sin_r2 <= sin_lut_half[addr];
        cos_r2 <= cos_lut_half[addr];
    end

    (* SHREG_EXTRACT = "NO" *)
    reg rf_r2;
    (* SHREG_EXTRACT = "NO" *)
    reg h_r2;
    reg valid_r2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rf_r2    <= 1'b0;
            h_r2     <= 1'b0;
            valid_r2 <= 1'b0;
        end else begin
            rf_r2    <= rf_r1;
            h_r2     <= h_bit;
            valid_r2 <= valid_r1;
        end
    end

    // =========================================================================
    // Stage 3 - pre-register +-cos/+-sin + sign merge (sel_r3 = rf^h)
    // -------------------------------------------------------------------------
    // sel_r3 is computed in parallel with the 9-bit negation (not in series
    // with it): the XOR of two FF outputs is shorter than the negation, so
    // the Stage 3 critical path is still set by the negation alone.
    // =========================================================================
    wire signed [8:0] cos_ext = {cos_r2[7], cos_r2};  // sign-extend, no gates
    wire signed [8:0] sin_ext = {sin_r2[7], sin_r2};

    reg signed [8:0] cos_pos_r3;   // +cos
    reg signed [8:0] cos_neg_r3;   // -cos
    reg signed [8:0] sin_neg_r3;   // -sin
    reg signed [8:0] sin_pos_r3;   // +sin

    (* SHREG_EXTRACT = "NO" *)
    reg sel_r3;      // = rf_r2 XOR h_r2 -- final sign, including the half-wave fold
    reg valid_r3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cos_pos_r3 <= 9'sd0;
            cos_neg_r3 <= 9'sd0;
            sin_neg_r3 <= 9'sd0;
            sin_pos_r3 <= 9'sd0;
            sel_r3     <= 1'b0;
            valid_r3   <= 1'b0;
        end else begin
            cos_pos_r3 <=  cos_ext;      // sign-extend (wire) -> FF
            cos_neg_r3 <= -cos_ext;      // 9-bit negate -> FF
            sin_neg_r3 <= -sin_ext;
            sin_pos_r3 <=  sin_ext;
            sel_r3     <=  rf_r2 ^ h_r2; // XOR: 1 LUT, parallel to the negation
            valid_r3   <=  valid_r2;
        end
    end

    // =========================================================================
    // Stage 4 - output mux (plain 2:1, selected by sel_r3)
    // -------------------------------------------------------------------------
    // All inputs are registered Stage 3 outputs; no arithmetic here.
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i_out     <= 9'sd0;
            q_out     <= 9'sd0;
            valid_out <= 1'b0;
        end else begin
            i_out     <= sel_r3 ? cos_pos_r3 : cos_neg_r3;
            q_out     <= sel_r3 ? sin_neg_r3 : sin_pos_r3;
            valid_out <= valid_r3;
        end
    end

endmodule