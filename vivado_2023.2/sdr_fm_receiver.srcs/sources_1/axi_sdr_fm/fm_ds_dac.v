`timescale 1ns / 1ps
// =============================================================================
// Module : fm_ds_dac
// Purpose: 2-channel, 1st-order, 1-bit delta-sigma DAC (PDM), for s_axi_aclk
//          (~50 MHz).
//
// VOLUME_ENABLE / MUTE_ENABLE: in the top-level instantiation
// (axi_sdr_fm.v), .volume() on this module is hard-wired to the constant
// 4'd15 -- the actual runtime volume is applied earlier, in
// audio_resampler (.volume(cur_vol)). .mute_en(), by contrast, is a real
// runtime signal used both here and in audio_resampler, giving an
// immediate local mute in addition to the one upstream.
//
// VOLUME_ENABLE=0 (default): the volume port is ignored and the gain is
// fixed at the same coefficient the hard-wired vol=15 already produced
// (coeff=65535, i.e. Q16-4369 -- intentionally not the ideal 65536/unity,
// for bit-for-bit continuity with that fixed operating point). The
// multiply audio*65535 is replaced by the exact identity
// 65535 = 2^16 - 1  =>  audio*65535 = (audio<<16) - audio, so no DSP48E1
// is used in this branch.
// VOLUME_ENABLE=1: coeff depends on the actual runtime volume (16 states)
// and audio_l is fully variable (2^24 states), so a real multiplier is
// needed -- the alternative (16 parallel shift-add networks under a mux)
// would cost more area than a single DSP48E1.
//
// MUTE_ENABLE=0 (default): the mute_en port is ignored and the module
// never mutes. This is unrelated to DSP usage (mute is just a final mux
// with zero over the finished product); it is parameterized independently
// for symmetry with VOLUME_ENABLE and so both behaviours are explicit at
// the instantiation site.
// =============================================================================

module fm_ds_dac #(
    parameter AUDIO_WIDTH   = 24,
    parameter VOLUME_ENABLE = 0,
    parameter MUTE_ENABLE   = 0
)(
    input  wire                          clk,          // s_axi_aclk, ~50 MHz
    input  wire                          rst_n,

    input  wire signed [AUDIO_WIDTH-1:0] audio_l,
    input  wire signed [AUDIO_WIDTH-1:0] audio_r,
    input  wire                          audio_valid,  // ~48 kHz strobe

    input  wire [3:0]                    volume,       // 0..15 (unused when VOLUME_ENABLE=0)
    input  wire                          mute_en,       // unused when MUTE_ENABLE=0

    output wire                          dac_out_l,
    output wire                          dac_out_r
);

    // --- widths ---
    localparam ACC_WIDTH = AUDIO_WIDTH + 2;
    localparam GAIN_FRAC = 16;
    localparam COEFF_W   = 18;
    localparam PROD_W    = AUDIO_WIDTH + COEFF_W;

    localparam signed [ACC_WIDTH-1:0] MAX_VAL =  (1 <<< (AUDIO_WIDTH-1)) - 1;
    localparam signed [ACC_WIDTH-1:0] MIN_VAL = -(1 <<< (AUDIO_WIDTH-1));

    // =====================================================================
    // Stage 1: gain (volume). The generate-if is a language-level guarantee
    // that when VOLUME_ENABLE=0 the multiply does not exist in hardware at
    // all, rather than relying on the synthesizer to optimize it away.
    // =====================================================================
    wire signed [PROD_W-1:0] prod_l_unmuted, prod_r_unmuted;

    generate
    if (VOLUME_ENABLE) begin : gen_volume
        // Full functionality: coeff is a genuine 16-state runtime value and
        // audio_l/r are fully variable (2^24 states) -- a real multiplier
        // is the right choice here, not an optimization left undone.
        wire signed [COEFF_W-1:0] coeff_w = volume * 18'sd4369;
        (* use_dsp = "no" *) wire signed [PROD_W-1:0] pl = audio_l * coeff_w;
        (* use_dsp = "no" *) wire signed [PROD_W-1:0] pr = audio_r * coeff_w;
        assign prod_l_unmuted = pl;
        assign prod_r_unmuted = pr;
    end else begin : gen_volume_bypass
        // VOLUME_ENABLE=0: volume is ignored, coeff is fixed at 65535 (the
        // same result the hard-wired .volume(4'd15) already produced in
        // the top-level instantiation). audio*65535 = audio*(2^16-1) =
        // (audio<<16)-audio -- an exact identity, no DSP48E1 needed.
        // Explicit sign-extension to PROD_W before the shift avoids
        // truncation in a self-determined <<<16 context.
        wire signed [PROD_W-1:0] audio_l_ext = {{(PROD_W-AUDIO_WIDTH){audio_l[AUDIO_WIDTH-1]}}, audio_l};
        wire signed [PROD_W-1:0] audio_r_ext = {{(PROD_W-AUDIO_WIDTH){audio_r[AUDIO_WIDTH-1]}}, audio_r};
        assign prod_l_unmuted = (audio_l_ext <<< GAIN_FRAC) - audio_l_ext;
        assign prod_r_unmuted = (audio_r_ext <<< GAIN_FRAC) - audio_r_ext;
    end
    endgenerate

    // =====================================================================
    // Stage 2: mute. Unrelated to DSP usage (just a final mux with zero),
    // parameterized independently of VOLUME_ENABLE.
    // =====================================================================
    wire signed [PROD_W-1:0] prod_l_w, prod_r_w;

    generate
    if (MUTE_ENABLE) begin : gen_mute
        assign prod_l_w = mute_en ? {PROD_W{1'b0}} : prod_l_unmuted;
        assign prod_r_w = mute_en ? {PROD_W{1'b0}} : prod_r_unmuted;
    end else begin : gen_mute_bypass
        // MUTE_ENABLE=0: mute_en is ignored, the module never mutes.
        assign prod_l_w = prod_l_unmuted;
        assign prod_r_w = prod_r_unmuted;
    end
    endgenerate

    wire signed [AUDIO_WIDTH-1:0] scaled_l_w = prod_l_w >>> GAIN_FRAC;
    wire signed [AUDIO_WIDTH-1:0] scaled_r_w = prod_r_w >>> GAIN_FRAC;

    wire signed [ACC_WIDTH-1:0] din_l_w =
        {{(ACC_WIDTH-AUDIO_WIDTH){scaled_l_w[AUDIO_WIDTH-1]}}, scaled_l_w};
    wire signed [ACC_WIDTH-1:0] din_r_w =
        {{(ACC_WIDTH-AUDIO_WIDTH){scaled_r_w[AUDIO_WIDTH-1]}}, scaled_r_w};

    // Pre-compute the feedback levels for the hot loop below
    reg signed [ACC_WIDTH-1:0] l_minus_fs, l_plus_fs, r_minus_fs, r_plus_fs;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            l_minus_fs <= {ACC_WIDTH{1'b0}};
            l_plus_fs  <= {ACC_WIDTH{1'b0}};
            r_minus_fs <= {ACC_WIDTH{1'b0}};
            r_plus_fs  <= {ACC_WIDTH{1'b0}};
        end else if (audio_valid) begin
            l_minus_fs <= din_l_w - MAX_VAL;
            l_plus_fs  <= din_l_w - MIN_VAL;
            r_minus_fs <= din_r_w - MAX_VAL;
            r_plus_fs  <= din_r_w - MIN_VAL;
        end
    end

    // =====================================================================
    // Delta-sigma modulator loop
    // =====================================================================
    reg signed [ACC_WIDTH-1:0] acc_l, acc_r;
    reg                        dac_bit_l, dac_bit_r;

    wire sel_l = ~acc_l[ACC_WIDTH-1];
    wire sel_r = ~acc_r[ACC_WIDTH-1];

    wire signed [ACC_WIDTH-1:0] delta_l = sel_l ? l_minus_fs : l_plus_fs;
    wire signed [ACC_WIDTH-1:0] delta_r = sel_r ? r_minus_fs : r_plus_fs;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_l <= {ACC_WIDTH{1'b0}};
            acc_r <= {ACC_WIDTH{1'b0}};
            dac_bit_l <= 1'b0;
            dac_bit_r <= 1'b0;
        end else begin
            acc_l     <= acc_l + delta_l;
            acc_r     <= acc_r + delta_r;
            dac_bit_l <= sel_l;
            dac_bit_r <= sel_r;
        end
    end

    assign dac_out_l = dac_bit_l;
    assign dac_out_r = dac_bit_r;

endmodule