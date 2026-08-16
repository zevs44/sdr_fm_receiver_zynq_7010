`timescale 1ns / 1ps
// =============================================================================
// Module : fm_cordic_discrim
// Purpose: CORDIC-based FM discriminator: baseband I/Q in, demodulated MPX
//          composite out, plus a signal-magnitude output for RSSI.
//
//          A 14-stage vectoring CORDIC extracts the instantaneous phase of
//          each I/Q sample; differentiating that phase between consecutive
//          samples gives the instantaneous frequency, which for FM is the
//          MPX composite (L+R baseband + 19 kHz pilot + 38 kHz L-R DSB-SC
//          + 57 kHz RDS subcarrier, all still undecoded here). The CORDIC's
//          x output after the final iteration is the vector magnitude
//          (scaled by the usual CORDIC gain), brought out on mag_out for
//          RSSI/station-detect use by the caller. Unlike a cross-product
//          discriminator, a true phase-difference CORDIC has no sin(dphi)
//          compression at large deviation, so it stays linear across the
//          full +/-75 kHz broadcast FM range.
//
//          This module exists as its own file because it is shared: in
//          axi_sdr_fm.v a single instance demodulates once and fans its
//          MPX composite out to every consumer -- fm_stereo_demod,
//          rds_decode, and the raw-MPX export path. Those consumers stay
//          independent of each other (none reads the others' signals, any
//          can be compiled out), while the demodulation they would
//          otherwise each duplicate is done once. Keeping it separate also
//          means RDS decoding does not depend on the stereo demodulator
//          being present at all, which matters because RDS is broadcast on
//          mono stations too.
//
//          Purely feed-forward: no feedback loops, no runtime controls,
//          nothing to configure. Latency from valid_in to mpx_valid is
//          ITER+2 cycles, but nothing downstream depends on the exact
//          number.
// =============================================================================
module fm_cordic_discrim #(
    parameter IQ_W = 16      // input I/Q sample width (signed)
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire signed [IQ_W-1:0]   i_in,
    input  wire signed [IQ_W-1:0]   q_in,
    input  wire                     valid_in,

    output reg  signed [17:0]       mpx_out,     // demodulated MPX composite
    output reg                      mpx_valid,   // strobe for mpx_out

    output wire signed [IQ_W+1:0]   mag_out,     // CORDIC vector magnitude (>=0)
    output wire                     mag_valid    // strobe for mag_out
);

    localparam ITER = 14;
    localparam XYW  = IQ_W + 2;
    localparam ZW   = 20;
    localparam signed [ZW-1:0] QUARTER = 20'sd32768;

    function signed [ZW-1:0] atan_lut;
        input integer k;
        begin
            case (k)
                0:  atan_lut = 20'sd16384;
                1:  atan_lut = 20'sd9672;
                2:  atan_lut = 20'sd5110;
                3:  atan_lut = 20'sd2594;
                4:  atan_lut = 20'sd1302;
                5:  atan_lut = 20'sd652;
                6:  atan_lut = 20'sd326;
                7:  atan_lut = 20'sd163;
                8:  atan_lut = 20'sd81;
                9:  atan_lut = 20'sd41;
                10: atan_lut = 20'sd20;
                11: atan_lut = 20'sd10;
                12: atan_lut = 20'sd5;
                13: atan_lut = 20'sd3;
                default: atan_lut = 20'sd0;
            endcase
        end
    endfunction

    // =========================================================================
    // CORDIC (vectoring mode), ITER=14 stages: extracts the instantaneous
    // phase of the I/Q input.
    // =========================================================================
    reg signed [XYW-1:0] x_p [0:ITER];
    reg signed [XYW-1:0] y_p [0:ITER];
    reg signed [ZW-1:0]  z_p [0:ITER];
    reg                  v_p [0:ITER];

    wire signed [XYW-1:0] i_ext = {{(XYW-IQ_W){i_in[IQ_W-1]}}, i_in};
    wire signed [XYW-1:0] q_ext = {{(XYW-IQ_W){q_in[IQ_W-1]}}, q_in};

    // Pre-rotation into the right half-plane -- the CORDIC vectoring
    // iteration only converges for |angle| <= ~99 deg, so quadrants 2/3 are
    // folded in by a 90-degree rotation with the matching QUARTER phase
    // offset seeded into z.
    reg signed [XYW-1:0] x0, y0;
    reg signed [ZW-1:0]  z0;
    always @(*) begin
        if (i_ext >= 0) begin
            x0 = i_ext;  y0 = q_ext;  z0 = 20'sd0;
        end else if (q_ext >= 0) begin
            x0 = q_ext;  y0 = -i_ext; z0 =  QUARTER;
        end else begin
            x0 = -q_ext; y0 = i_ext;  z0 = -QUARTER;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            x_p[0] <= 0; y_p[0] <= 0; z_p[0] <= 0; v_p[0] <= 1'b0;
        end else begin
            x_p[0] <= x0;  y_p[0] <= y0;  z_p[0] <= z0;  v_p[0] <= valid_in;
        end
    end

    genvar gs;
    generate
        for (gs = 0; gs < ITER; gs = gs + 1) begin : cordic_stage
            wire                   dir = y_p[gs][XYW-1];
            wire signed [XYW-1:0]  xs  = x_p[gs] >>> gs;
            wire signed [XYW-1:0]  ys  = y_p[gs] >>> gs;
            always @(posedge clk) begin
                if (!rst_n) begin
                    x_p[gs+1] <= 0; y_p[gs+1] <= 0; z_p[gs+1] <= 0; v_p[gs+1] <= 1'b0;
                end else begin
                    x_p[gs+1] <= dir ? (x_p[gs] - ys) : (x_p[gs] + ys);
                    y_p[gs+1] <= dir ? (y_p[gs] + xs) : (y_p[gs] - xs);
                    z_p[gs+1] <= dir ? (z_p[gs] - atan_lut(gs)) : (z_p[gs] + atan_lut(gs));
                    v_p[gs+1] <= v_p[gs];
                end
            end
        end
    endgenerate

    wire signed [ZW-1:0] phase     = z_p[ITER];
    wire                 phase_vld = v_p[ITER];

    // Vector magnitude, clamped at 0: after a correct vectoring run x is
    // non-negative, so a negative value only occurs on a not-yet-valid or
    // degenerate pipeline state and would otherwise corrupt a downstream
    // RSSI integrator.
    assign mag_out   = x_p[ITER][XYW-1] ? {XYW{1'b0}} : x_p[ITER];
    assign mag_valid = phase_vld;

    // =========================================================================
    // Phase differentiator: mpx = phase[n] - phase[n-1].
    //
    // The subtraction is done on the low 17 bits and reinterpreted as
    // signed, so phase wraparound is handled for free by modular
    // arithmetic -- a step across the +/-pi boundary produces the correct
    // small signed difference rather than a full-scale jump.
    // =========================================================================
    wire [16:0] phase17 = phase[16:0];
    reg  [16:0] phase_prev;
    wire [16:0] diff_u  = phase17 - phase_prev;
    wire signed [16:0] diff_s = diff_u;

    always @(posedge clk) begin
        if (!rst_n) begin
            phase_prev <= 17'd0;
            mpx_out    <= 18'sd0;
            mpx_valid  <= 1'b0;
        end else begin
            mpx_valid <= phase_vld;
            if (phase_vld) begin
                phase_prev <= phase17;
                mpx_out    <= {diff_s[16], diff_s};
            end
        end
    end

endmodule
