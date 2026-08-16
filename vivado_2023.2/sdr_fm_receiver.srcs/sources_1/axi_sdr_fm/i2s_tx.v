`timescale 1ns / 1ps
// =============================================================================
// Module : i2s_tx
// Purpose: I2S (Philips protocol) audio transmitter, 24-bit stereo, for an
//          external DAC (PCM5102A, MAX98357, WM8731, etc.) running in
//          parallel with the on-chip delta-sigma DAC.
//
//          Input:  audio_l/audio_r (24-bit signed) + audio_valid strobe
//                   (~48 kHz).
//          Output: i2s_bclk (bit clock), i2s_lrclk (word select, 0=L/1=R),
//                   i2s_sdata (serial data, MSB first).
//
// I2S FORMAT (not to be confused with "left-justified"/DSP format): true
// I2S shifts data by one BCLK relative to the WS transition -- at the
// instant WS changes, SD is still carrying the LAST bit of the PREVIOUS
// word, and the first (MSB) bit of the new word only appears on the
// FOLLOWING BCLK edge. This is implemented below via
// ws_phase = data_phase+1, i.e. WS always leads the data by one cycle.
//
// Slot width is 32 bits per channel (SLOT_WIDTH); data is 24 bits
// (DATA_WIDTH), MSB-justified within the slot -- the standard alignment
// expected by essentially all I2S DACs when the slot and data widths
// differ.
//
// -------------------------------------------------------------------------
// Volume / mute
// -------------------------------------------------------------------------
// volume/mute_en are only wired into hardware at all when the ENABLE_VOLUME
// / ENABLE_MUTE parameters request it, so an unused feature costs neither
// DSP nor logic:
//
//   - volume(4 bits) -> coeff(18 bits) needs no multiplier: 4369 = 0x1111
//     (a "1" in every nibble of a 16-bit value), so for a 4-bit volume
//     (0..15) that never carries into an adjacent nibble,
//     volume * 4369 == {volume, volume, volume, volume} exactly. The
//     coefficient is therefore built by bit replication
//     (coeff_raw = {2'b00, {4{volume}}}), not multiplication.
//   - audio_l*coeff and audio_r*coeff share a single 24x18 multiplier,
//     time-multiplexed over 2 clk cycles per audio_valid: the cycle
//     audio_valid arrives latches audio_l/audio_r/coeff; the next cycle
//     computes and latches latched_l; the cycle after computes and
//     latches latched_r. This is safe with a large margin -- clk runs at
//     50 MHz while audio_valid is an I2S-frame-rate strobe (tens of kHz),
//     i.e. at least two orders of magnitude more clk cycles than needed
//     per audio sample even in the extreme case (SLOT_WIDTH=32,
//     BCLK_DIV=1 gives >=128 clk cycles per frame).
//   - mute is applied before the multiplier as a plain input mux
//     (audio_{l,r}_m = mute_active ? 0 : audio_{l,r}), so it costs no DSP
//     regardless of ENABLE_VOLUME, and works even when ENABLE_VOLUME=0 and
//     no multiplier exists in the design at all.
//
// DSP48E1 usage for the volume/mute block: 1 when ENABLE_VOLUME=1, 0 when
// ENABLE_VOLUME=0 (no multiplier is present in the netlist; audio passes
// through at unity gain). ENABLE_MUTE never adds a DSP either way.
//
// BCLK_DIV is the number of clk cycles per HALF period of BCLK (not a full
// period); the top-level default is overridden in axi_sdr_fm.v via
// I2S_DIV, computed from S_AXI_ACLK_HZ.
// =============================================================================

module i2s_tx #(
    parameter DATA_WIDTH = 24,   // audio sample width (matches fm_stereo_demod)
    parameter SLOT_WIDTH = 32,   // bits per channel in the I2S frame (standard: 32)
    // BCLK_DIV = round( clk_freq / (2 * Fs * 2_channels * SLOT_WIDTH) )
    parameter BCLK_DIV      = 39,
    parameter ENABLE_VOLUME = 0, // 1 = hardware volume control (1 DSP); 0 = bypass (unity gain, 0 DSP)
    parameter ENABLE_MUTE   = 0  // 1 = mute_en is active (0 DSP either way); 0 = mute_en is ignored
)(
    input  wire                          clk,          // s_axi_aclk, ~50 MHz
    input  wire                          rst_n,
    input  wire signed [DATA_WIDTH-1:0]  audio_l,
    input  wire signed [DATA_WIDTH-1:0]  audio_r,
    input  wire                          audio_valid,

    input  wire [3:0]                    volume,       // 0..15 (unused when ENABLE_VOLUME=0)
    input  wire                          mute_en,      // mute when 1 (unused when ENABLE_MUTE=0)

    output reg                           i2s_bclk,
    output reg                           i2s_lrclk,   // 0 = left channel, 1 = right
    output reg                           i2s_sdata
);
    localparam PHASE_W = $clog2(2*SLOT_WIDTH);
    localparam DIV_W   = $clog2(BCLK_DIV+1);

    // =========================================================================
    // Volume and mute (see header for the DSP-sharing rationale)
    // =========================================================================
    localparam GAIN_FRAC = 16;
    localparam COEFF_W   = 18;
    localparam PROD_W    = DATA_WIDTH + COEFF_W;

    reg signed [DATA_WIDTH-1:0]  latched_l, latched_r;

    // Mute is a plain input mux, 0 DSP regardless of ENABLE_VOLUME.
    // ENABLE_MUTE is an elaboration-time constant, so the synthesizer folds
    // mute_active into mute_en or a hard 0 with no residual select logic.
    wire mute_active = ENABLE_MUTE ? mute_en : 1'b0;
    wire signed [DATA_WIDTH-1:0] audio_l_m = mute_active ? {DATA_WIDTH{1'b0}} : audio_l;
    wire signed [DATA_WIDTH-1:0] audio_r_m = mute_active ? {DATA_WIDTH{1'b0}} : audio_r;

    generate
    if (ENABLE_VOLUME) begin : gen_volume

        // volume(4 bits) -> coeff(18 bits), no multiplier: exact bit
        // replication (see header for the 4369 identity).
        wire signed [COEFF_W-1:0] coeff_raw = {2'b00, {4{volume}}};

        // --- Time-multiplexed 24x18 multiplier, shared for L and R ---
        reg                          tdm_busy, tdm_sel;
        reg  signed [DATA_WIDTH-1:0] tdm_l_h, tdm_r_h;
        reg  signed [COEFF_W-1:0]    tdm_coeff_h;

        wire signed [DATA_WIDTH-1:0] tdm_operand = tdm_sel ? tdm_r_h : tdm_l_h;

        (* use_dsp = "yes" *)
        wire signed [PROD_W-1:0] tdm_prod = tdm_operand * tdm_coeff_h;

        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                latched_l   <= {DATA_WIDTH{1'b0}};
                latched_r   <= {DATA_WIDTH{1'b0}};
                tdm_busy    <= 1'b0;
                tdm_sel     <= 1'b0;
                tdm_l_h     <= {DATA_WIDTH{1'b0}};
                tdm_r_h     <= {DATA_WIDTH{1'b0}};
                tdm_coeff_h <= {COEFF_W{1'b0}};
            end else if (audio_valid && !tdm_busy) begin
                // Latch the sample pair and coefficient together; the same
                // coeff is used for L and R even though the multiplier
                // processes them one after another.
                tdm_l_h     <= audio_l_m;
                tdm_r_h     <= audio_r_m;
                tdm_coeff_h <= coeff_raw;
                tdm_sel     <= 1'b0;
                tdm_busy    <= 1'b1;
            end else if (tdm_busy) begin
                if (!tdm_sel) begin
                    latched_l <= tdm_prod >>> GAIN_FRAC;
                    tdm_sel   <= 1'b1;
                end else begin
                    latched_r <= tdm_prod >>> GAIN_FRAC;
                    tdm_busy  <= 1'b0;
                end
            end
        end

    end else begin : gen_volume_bypass

        // No multiplier in the design at all -> 0 DSP. Mute (if enabled)
        // has already been applied above, in audio_{l,r}_m.
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                latched_l <= {DATA_WIDTH{1'b0}};
                latched_r <= {DATA_WIDTH{1'b0}};
            end else if (audio_valid) begin
                latched_l <= audio_l_m;
                latched_r <= audio_r_m;
            end
        end

    end
    endgenerate

    // =========================================================================
    // BCLK generator + shift registers + WS
    // =========================================================================
    reg [DIV_W-1:0]   div_cnt;
    reg [PHASE_W-1:0] data_phase;             // 0..2*SLOT_WIDTH-1
    reg [SLOT_WIDTH-1:0] left_shift, right_shift;

    wire [PHASE_W-1:0] next_phase =
        (data_phase == 2*SLOT_WIDTH-1) ? {PHASE_W{1'b0}} : (data_phase + 1'b1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt     <= {DIV_W{1'b0}};
            i2s_bclk    <= 1'b0;
            data_phase  <= {PHASE_W{1'b0}};
            left_shift  <= {SLOT_WIDTH{1'b0}};
            right_shift <= {SLOT_WIDTH{1'b0}};
            i2s_lrclk   <= 1'b0;
            i2s_sdata   <= 1'b0;
        end else if (div_cnt == BCLK_DIV-1) begin
            div_cnt  <= {DIV_W{1'b0}};
            i2s_bclk <= ~i2s_bclk;
            if (i2s_bclk) begin
                // Falling edge of BCLK (1->0): update SD/WS/shift here
                if (data_phase < SLOT_WIDTH) begin
                    i2s_sdata  <= left_shift[SLOT_WIDTH-1];
                    left_shift <= {left_shift[SLOT_WIDTH-2:0], 1'b0};
                end else begin
                    i2s_sdata   <= right_shift[SLOT_WIDTH-1];
                    right_shift <= {right_shift[SLOT_WIDTH-2:0], 1'b0};
                end

                // WS leads the data by 1 BCLK
                i2s_lrclk <= (next_phase < SLOT_WIDTH) ? 1'b0 : 1'b1;

                // Start of a new word -> load the latched sample
                if (next_phase == {PHASE_W{1'b0}})
                    left_shift  <= {latched_l, {(SLOT_WIDTH-DATA_WIDTH){1'b0}}};
                else if (next_phase == SLOT_WIDTH)
                    right_shift <= {latched_r, {(SLOT_WIDTH-DATA_WIDTH){1'b0}}};

                data_phase <= next_phase;
            end
        end else begin
            div_cnt <= div_cnt + 1'b1;
        end
    end
endmodule