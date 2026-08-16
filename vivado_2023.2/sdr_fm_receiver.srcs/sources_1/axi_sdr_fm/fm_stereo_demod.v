`timescale 1ns / 1ps
// =============================================================================
// Module : fm_stereo_demod
// Purpose: FM stereo demodulator: RSSI / station-found detection,
//          pilot-tone PLL with anti-windup, L-R notch-filtered stereo
//          recovery, mono/stereo matrixing, bass boost, de-emphasis, and
//          volume/mute.
//
//          This module does NOT demodulate. It takes the already-
//          demodulated MPX composite (mpx_in @ 250 kHz) and the CORDIC
//          vector magnitude (mag_in, used only for RSSI) from
//          fm_cordic_discrim, which axi_sdr_fm.v instantiates ONCE and
//          fans out to every MPX consumer -- this module, rds_decode, and
//          the raw-MPX export path. One discriminator, several independent
//          consumers: none of them depends on any other, and each can be
//          compiled out without affecting the rest. In particular RDS
//          decoding does not need this module at all, which matters
//          because RDS is broadcast on mono stations too.
//
//          Runs entirely on s_axi_aclk (~50 MHz). The RF front end
//          (fm_rf_input, fm_ddc_mixer, the I/Q CIC decimators) is the only
//          part of the design that runs on clk_rf; its decimated I/Q
//          output crosses into this domain via a toggle-handshake CDC in
//          axi_sdr_fm.v, ahead of the shared discriminator. Because
//          everything from the discriminator onward already lives in
//          s_axi_aclk, the control inputs (bass_boost_en, deemph_sel,
//          mono_sel, volume, mute_en) are native to this domain too and do
//          not need cross-domain synchronizers -- the double registers on
//          them below add a couple of cycles of margin before use, not
//          clock-domain crossing.
// =============================================================================
module fm_stereo_demod #(
    parameter MAG_W         = 18,   // width of mag_in (fm_cordic_discrim's mag_out: IQ_W+2)
    parameter signed [8:0] DEEMPH_A_50US = 84,
    parameter signed [8:0] DEEMPH_A_75US = 60,
    parameter DEEMPH_SHIFT  = 8,
    parameter DEEMPH_ENABLE = 1,
    parameter STEREO_ENABLE = 1,
    parameter BASS_LPF_SHIFT       = 5,
    parameter [9:0] BASS_GAIN      = 10'd256,
    parameter BASS_GAIN_SHIFT      = 8,
    parameter BASS_BOOST_ENABLE    = 1,
    parameter PILOT_LOCK_THRESH = 24'sd200000,
    parameter PILOT_LOCK_THRESH_HI = 24'sd400000,
    parameter LOCK_DEBOUNCE_BITS = 12,
    parameter SIG_LPF_SHIFT     = 9,
    parameter [17:0] RSSI_THRESH_HI = 18'd20000,
    parameter [17:0] RSSI_THRESH_LO = 18'd15000,
    parameter SIG_DEBOUNCE_BITS = 10
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // ---- Inputs from the shared discriminator (fm_cordic_discrim,
    //      instantiated once at the top level and fanned out to every MPX
    //      consumer -- see the module header). ----
    input  wire signed [17:0]       mpx_in,      // demodulated MPX composite @ 250 kHz
    input  wire                     mpx_valid,   // strobe for mpx_in
    input  wire signed [MAG_W-1:0]  mag_in,      // CORDIC vector magnitude, for RSSI
    input  wire                     mag_valid,   // strobe for mag_in

    input  wire                     bass_boost_en,
    input  wire                     deemph_sel,
    input  wire                     mono_sel,
    input  wire [3:0]               volume,
    input  wire                      mute_en,

    output reg  signed [23:0]       audio_l,
    output reg  signed [23:0]       audio_r,
    output reg                      audio_valid,
    output reg                      pilot_locked,
    output wire [17:0]              signal_level,
    output reg                      station_found
);

    localparam XYW = MAG_W;

    // The MPX composite and magnitude arrive already demodulated -- see the
    // module header for why the discriminator is shared rather than owned
    // here.
    wire signed [XYW-1:0] cordic_mag = mag_in;
    wire                  phase_vld  = mag_valid;
    wire signed [17:0]    disc_data  = mpx_in;
    wire                  disc_vld   = mpx_valid;

    // =========================================================================
    // RSSI / station-found detection: a leaky-integrator level estimate of
    // the CORDIC magnitude, debounced against RSSI_THRESH_HI/LO.
    // =========================================================================
    reg signed [XYW+SIG_LPF_SHIFT-1:0] sig_lpf_acc;
    always @(posedge clk) begin
        if (!rst_n) sig_lpf_acc <= {(XYW+SIG_LPF_SHIFT){1'b0}};
        else if (phase_vld)
            sig_lpf_acc <= sig_lpf_acc + (cordic_mag - (sig_lpf_acc >>> SIG_LPF_SHIFT));
    end
    wire [17:0] signal_level_w = sig_lpf_acc[XYW+SIG_LPF_SHIFT-1:SIG_LPF_SHIFT];
    assign signal_level = signal_level_w;

    wire sig_above_hi = (signal_level_w > RSSI_THRESH_HI);
    wire sig_below_lo = (signal_level_w < RSSI_THRESH_LO);

    reg [SIG_DEBOUNCE_BITS-1:0] sig_cnt;
    always @(posedge clk) begin
        if (!rst_n) begin
            sig_cnt <= {SIG_DEBOUNCE_BITS{1'b0}};
            station_found <= 1'b0;
        end else if (phase_vld) begin
            if (sig_above_hi) begin
                if (sig_cnt != {SIG_DEBOUNCE_BITS{1'b1}}) sig_cnt <= sig_cnt + 1'b1;
            end else if (sig_below_lo) begin
                if (sig_cnt != {SIG_DEBOUNCE_BITS{1'b0}}) sig_cnt <= sig_cnt - 1'b1;
            end
            station_found <= (sig_cnt == {SIG_DEBOUNCE_BITS{1'b1}});
        end
    end

    localparam ACC_W = 24;
    localparam signed [23:0] FREQ_WORD_19K = 24'sd1275068;

    function signed [11:0] cos_q_lut;
        input [5:0] addr;
        begin
            case (addr)
                 0: cos_q_lut = 12'sd25;
                 1: cos_q_lut = 12'sd75;
                 2: cos_q_lut = 12'sd126;
                 3: cos_q_lut = 12'sd176;
                 4: cos_q_lut = 12'sd226;
                 5: cos_q_lut = 12'sd275;
                 6: cos_q_lut = 12'sd325;
                 7: cos_q_lut = 12'sd375;
                 8: cos_q_lut = 12'sd424;
                 9: cos_q_lut = 12'sd473;
                10: cos_q_lut = 12'sd522;
                11: cos_q_lut = 12'sd570;
                12: cos_q_lut = 12'sd618;
                13: cos_q_lut = 12'sd666;
                14: cos_q_lut = 12'sd713;
                15: cos_q_lut = 12'sd760;
                16: cos_q_lut = 12'sd807;
                17: cos_q_lut = 12'sd852;
                18: cos_q_lut = 12'sd898;
                19: cos_q_lut = 12'sd943;
                20: cos_q_lut = 12'sd987;
                21: cos_q_lut = 12'sd1031;
                22: cos_q_lut = 12'sd1074;
                23: cos_q_lut = 12'sd1116;
                24: cos_q_lut = 12'sd1158;
                25: cos_q_lut = 12'sd1199;
                26: cos_q_lut = 12'sd1239;
                27: cos_q_lut = 12'sd1279;
                28: cos_q_lut = 12'sd1318;
                29: cos_q_lut = 12'sd1356;
                30: cos_q_lut = 12'sd1393;
                31: cos_q_lut = 12'sd1430;
                32: cos_q_lut = 12'sd1465;
                33: cos_q_lut = 12'sd1500;
                34: cos_q_lut = 12'sd1533;
                35: cos_q_lut = 12'sd1566;
                36: cos_q_lut = 12'sd1598;
                37: cos_q_lut = 12'sd1629;
                38: cos_q_lut = 12'sd1659;
                39: cos_q_lut = 12'sd1688;
                40: cos_q_lut = 12'sd1716;
                41: cos_q_lut = 12'sd1743;
                42: cos_q_lut = 12'sd1769;
                43: cos_q_lut = 12'sd1793;
                44: cos_q_lut = 12'sd1817;
                45: cos_q_lut = 12'sd1840;
                46: cos_q_lut = 12'sd1861;
                47: cos_q_lut = 12'sd1881;
                48: cos_q_lut = 12'sd1901;
                49: cos_q_lut = 12'sd1919;
                50: cos_q_lut = 12'sd1936;
                51: cos_q_lut = 12'sd1951;
                52: cos_q_lut = 12'sd1966;
                53: cos_q_lut = 12'sd1979;
                54: cos_q_lut = 12'sd1992;
                55: cos_q_lut = 12'sd2003;
                56: cos_q_lut = 12'sd2012;
                57: cos_q_lut = 12'sd2021;
                58: cos_q_lut = 12'sd2028;
                59: cos_q_lut = 12'sd2035;
                60: cos_q_lut = 12'sd2039;
                61: cos_q_lut = 12'sd2043;
                62: cos_q_lut = 12'sd2046;
                63: cos_q_lut = 12'sd2047;
            endcase
        end
    endfunction

    function signed [11:0] nco_cos;
        input [ACC_W-1:0] ph;
        reg [1:0] quad;
        reg [5:0] sub;
        begin
            quad = ph[ACC_W-1:ACC_W-2];
            sub  = ph[ACC_W-3:ACC_W-8];
            case (quad)
                2'b00: nco_cos =  cos_q_lut(6'd63-sub);
                2'b01: nco_cos = -cos_q_lut(sub);
                2'b10: nco_cos = -cos_q_lut(6'd63-sub);
                default: nco_cos = cos_q_lut(sub);
            endcase
        end
    endfunction

    reg [ACC_W-1:0] nco_phase;

    localparam LPF_SHIFT = 10;
    localparam KI_SHIFT   = 26;
    localparam KP_SHIFT   = 12;

    // =========================================================================
    // Pilot-tone (19 kHz) PLL. Leaky-integrator (KI) plus proportional (KP)
    // loop, driving an NCO used both to demodulate the stereo (L-R)
    // subcarrier and to gate pilot_locked.
    //
    // The integral branch is saturated so its contribution to the NCO
    // correction never exceeds +-2^PLL_ICORR_LOG2, and the combined (I+P)
    // correction is further saturated to +-2^PLL_CORR_LOG2. Integration is
    // conditional (anti-windup): while the total correction is pinned at
    // its limit, error pushing further in that direction is not
    // accumulated -- this matters because with no pilot present (e.g.
    // before a station is tuned in) err is pure noise and would otherwise
    // let the integrator random-walk without bound; once it overflowed a
    // fixed-width correction register the NCO could be thrown far enough
    // off frequency that reacquiring a pilot that later appears would take
    // a long time. PLL_ICORR_LOG2=12 gives roughly +-61 Hz of integral
    // authority at the pilot's own 250 kHz NCO rate (an order of magnitude
    // more than the real pilot offset: +-2 Hz per the broadcast standard,
    // plus crystal ppm); PLL_CORR_LOG2=14 leaves headroom on top of that
    // for the proportional branch during fast phase transients. Within the
    // normal operating range none of this saturation is active, so loop
    // dynamics are unchanged from an unbounded implementation.
    // =========================================================================
    localparam PLL_ICORR_LOG2 = 12;
    localparam PLL_CORR_LOG2  = 14;
    localparam PLL_ACC_W      = KI_SHIFT + PLL_ICORR_LOG2 + 2;   // 40 bits
    localparam signed [PLL_ACC_W:0] PLL_ACC_LIM_POS =
        {{2{1'b0}}, 1'b1, {(KI_SHIFT+PLL_ICORR_LOG2){1'b0}}};    // +2^(KI+12)
    localparam signed [PLL_ACC_W:0] PLL_ACC_LIM_NEG = -PLL_ACC_LIM_POS;
    localparam signed [24:0] PLL_CORR_LIM_POS = 25'sd1 <<< PLL_CORR_LOG2;   // +2^14
    localparam signed [24:0] PLL_CORR_LIM_NEG = -(25'sd1 <<< PLL_CORR_LOG2);

    reg signed [11:0] c19_q, c38_q;
    reg signed [17:0] disc_q1;
    reg               vld_p1;

    always @(posedge clk) begin
        if (!rst_n) begin
            disc_q1 <= 18'sd0; vld_p1 <= 1'b0;
        end else begin
            vld_p1 <= disc_vld;
            if (disc_vld) disc_q1 <= disc_data;
        end
    end

    generate if (STEREO_ENABLE) begin : gen_pll_p1
    always @(posedge clk) begin
        if (!rst_n) begin
            c19_q <= 12'sd0; c38_q <= 12'sd0;
        end else if (disc_vld) begin
            c19_q <= nco_cos(nco_phase);
            c38_q <= nco_cos(nco_phase << 1);
        end
    end
    end endgenerate

    reg signed [29:0] err_raw_q, lmr_raw_q;
    reg signed [17:0] disc_q2;
    reg               vld_p2;

    always @(posedge clk) begin
        if (!rst_n) begin
            disc_q2 <= 18'sd0; vld_p2 <= 1'b0;
        end else begin
            vld_p2 <= vld_p1;
            if (vld_p1) disc_q2 <= disc_q1;
        end
    end

    generate if (STEREO_ENABLE) begin : gen_pll_p2
    always @(posedge clk) begin
        if (!rst_n) begin
            err_raw_q <= 30'sd0; lmr_raw_q <= 30'sd0;
        end else if (vld_p1) begin
            err_raw_q <= disc_q1 * c19_q;
            lmr_raw_q <= disc_q1 * c38_q;
        end
    end
    end endgenerate

    reg signed [41:0] err_lpf_acc;
    reg               vld_p3;
    always @(posedge clk) begin
        if (!rst_n) vld_p3 <= 1'b0;
        else        vld_p3 <= vld_p2;
    end

    generate if (STEREO_ENABLE) begin : gen_pll_p3
    always @(posedge clk) begin
        if (!rst_n) begin
            err_lpf_acc <= 42'sd0;
        end else if (vld_p2) begin
            err_lpf_acc <= err_lpf_acc + (err_raw_q - (err_lpf_acc >>> LPF_SHIFT));
        end
    end
    end endgenerate

    reg signed [31:0] err_q;
    reg signed [29:0] lmr_raw_q2;
    reg signed [17:0] disc_q3;
    reg               vld_p4;

    always @(posedge clk) begin
        if (!rst_n) begin
            disc_q3 <= 18'sd0; vld_p4 <= 1'b0;
        end else begin
            vld_p4 <= vld_p3;
            if (vld_p3) disc_q3 <= disc_q2;
        end
    end

    generate if (STEREO_ENABLE) begin : gen_pll_p4
    always @(posedge clk) begin
        if (!rst_n) begin
            err_q <= 32'sd0; lmr_raw_q2 <= 30'sd0;
        end else if (vld_p3) begin
            err_q      <= err_lpf_acc >>> LPF_SHIFT;
            lmr_raw_q2 <= lmr_raw_q;
        end
    end
    end endgenerate

    // freq_acc: width bounded to PLL_ACC_W=40 bits (see the PLL_ICORR_LOG2
    // comment above -- the useful operating range is entirely within the
    // saturation limits).
    reg signed [PLL_ACC_W-1:0] freq_acc;
    reg signed [23:0] kp_term_q;
    reg signed [29:0] lmr_raw_q3;
    reg signed [17:0] disc_q4;
    reg               vld_p5;
    // "correction pinned at its limit" flags -- registered at stage p7
    // (where the full correction is computed and saturated), read here
    // (p5) to gate conditional integration. The one-sample lag on the flag
    // is immaterial for this slow anti-windup path.
    reg               pll_corr_at_pos;
    reg               pll_corr_at_neg;

    always @(posedge clk) begin
        if (!rst_n) begin
            disc_q4 <= 18'sd0; vld_p5 <= 1'b0;
        end else begin
            vld_p5 <= vld_p4;
            if (vld_p4) disc_q4 <= disc_q3;
        end
    end

    generate if (STEREO_ENABLE) begin : gen_pll_p5
    wire signed [PLL_ACC_W:0] pll_acc_sum = freq_acc + err_q;
    wire                      pll_err_neg = err_q[31];
    // conditional integration (anti-windup) -- see the PLL_ICORR_LOG2 comment above
    wire                      pll_int_en  = ~((pll_corr_at_pos & ~pll_err_neg)
                                            | (pll_corr_at_neg &  pll_err_neg));
    always @(posedge clk) begin
        if (!rst_n) begin
            freq_acc <= {PLL_ACC_W{1'b0}}; kp_term_q <= 24'sd0; lmr_raw_q3 <= 30'sd0;
        end else if (vld_p4) begin
            if (pll_int_en) begin
                if      (pll_acc_sum > PLL_ACC_LIM_POS) freq_acc <= PLL_ACC_LIM_POS[PLL_ACC_W-1:0];
                else if (pll_acc_sum < PLL_ACC_LIM_NEG) freq_acc <= PLL_ACC_LIM_NEG[PLL_ACC_W-1:0];
                else                                    freq_acc <= pll_acc_sum[PLL_ACC_W-1:0];
            end
            kp_term_q  <= err_q >>> KP_SHIFT;
            lmr_raw_q3 <= lmr_raw_q2;
        end
    end
    end endgenerate

    generate if (STEREO_ENABLE) begin : gen_pilot_lock
    reg signed [31:0] err_abs_q;
    reg                vld_lockA;
    always @(posedge clk) begin
        if (!rst_n) begin
            err_abs_q <= 32'sd0; vld_lockA <= 1'b0;
        end else begin
            vld_lockA <= vld_p4;
            if (vld_p4) err_abs_q <= err_q[31] ? -err_q : err_q;
        end
    end

    reg                err_below_lo_q;
    reg                err_above_hi_q;
    reg                vld_lockB;
    always @(posedge clk) begin
        if (!rst_n) begin
            err_below_lo_q <= 1'b0; err_above_hi_q <= 1'b0; vld_lockB <= 1'b0;
        end else begin
            vld_lockB <= vld_lockA;
            if (vld_lockA) begin
                err_below_lo_q <= (err_abs_q < PILOT_LOCK_THRESH);
                err_above_hi_q <= (err_abs_q > PILOT_LOCK_THRESH_HI);
            end
        end
    end

    reg [LOCK_DEBOUNCE_BITS-1:0] lock_cnt;
    always @(posedge clk) begin
        if (!rst_n) begin
            lock_cnt <= {LOCK_DEBOUNCE_BITS{1'b0}}; pilot_locked <= 1'b0;
        end else if (vld_lockB) begin
            if (err_below_lo_q) begin
                if (lock_cnt != {LOCK_DEBOUNCE_BITS{1'b1}}) lock_cnt <= lock_cnt + 1'b1;
            end else if (err_above_hi_q) begin
                if (lock_cnt != {LOCK_DEBOUNCE_BITS{1'b0}}) lock_cnt <= lock_cnt - 1'b1;
            end
            if (lock_cnt == {LOCK_DEBOUNCE_BITS{1'b1}})
                pilot_locked <= 1'b1;
            else if (lock_cnt == {LOCK_DEBOUNCE_BITS{1'b0}})
                pilot_locked <= 1'b0;
        end
    end
    end else begin : gen_pilot_lock_bypass
    always @(posedge clk) begin
        if (!rst_n) pilot_locked <= 1'b0;
        else        pilot_locked <= 1'b0;
    end
    end endgenerate

    reg signed [23:0] freq_corr_i_q;
    reg signed [23:0] kp_term_q2;
    reg signed [29:0] lmr_raw_q4;
    reg signed [17:0] disc_q5;
    reg               vld_p6;

    always @(posedge clk) begin
        if (!rst_n) begin
            disc_q5 <= 18'sd0; vld_p6 <= 1'b0;
        end else begin
            vld_p6 <= vld_p5;
            if (vld_p5) disc_q5 <= disc_q4;
        end
    end

    generate if (STEREO_ENABLE) begin : gen_pll_p6
    always @(posedge clk) begin
        if (!rst_n) begin
            freq_corr_i_q <= 24'sd0; kp_term_q2 <= 24'sd0; lmr_raw_q4 <= 30'sd0;
        end else if (vld_p5) begin
            // freq_acc is saturated to +-2^(KI+12) above, so freq_acc>>>KI
            // is guaranteed to fit in +-2^12 -- no truncation risk here.
            freq_corr_i_q <= freq_acc >>> KI_SHIFT;
            kp_term_q2    <= kp_term_q;
            lmr_raw_q4    <= lmr_raw_q3;
        end
    end
    end endgenerate

    reg signed [25:0] fw_q;
    reg signed [29:0] lmr_raw_q5;
    reg signed [17:0] disc_q6;
    reg               vld_p7;

    always @(posedge clk) begin
        if (!rst_n) begin
            disc_q6 <= 18'sd0; vld_p7 <= 1'b0;
        end else begin
            vld_p7 <= vld_p6;
            if (vld_p6) disc_q6 <= disc_q5;
        end
    end

    generate if (STEREO_ENABLE) begin : gen_pll_p7
    // combined (I+P) correction, saturated (see the PLL_ICORR_LOG2 comment above)
    wire signed [24:0] pll_corr_sum = freq_corr_i_q + kp_term_q2;
    always @(posedge clk) begin
        if (!rst_n) begin
            fw_q <= 26'sd0; lmr_raw_q5 <= 30'sd0;
            pll_corr_at_pos <= 1'b0; pll_corr_at_neg <= 1'b0;
        end else if (vld_p6) begin
            if (pll_corr_sum > PLL_CORR_LIM_POS) begin
                fw_q <= $signed({{2{FREQ_WORD_19K[23]}}, FREQ_WORD_19K}) + PLL_CORR_LIM_POS;
                pll_corr_at_pos <= 1'b1; pll_corr_at_neg <= 1'b0;
            end else if (pll_corr_sum < PLL_CORR_LIM_NEG) begin
                fw_q <= $signed({{2{FREQ_WORD_19K[23]}}, FREQ_WORD_19K}) + PLL_CORR_LIM_NEG;
                pll_corr_at_pos <= 1'b0; pll_corr_at_neg <= 1'b1;
            end else begin
                fw_q <= $signed({{2{FREQ_WORD_19K[23]}}, FREQ_WORD_19K}) + pll_corr_sum;
                pll_corr_at_pos <= 1'b0; pll_corr_at_neg <= 1'b0;
            end
            lmr_raw_q5 <= lmr_raw_q4;
        end
    end
    end endgenerate

    reg signed [29:0] lmr_raw_final;
    reg signed [17:0] disc_final;
    reg               vld_p8;

    always @(posedge clk) begin
        if (!rst_n) begin
            disc_final <= 18'sd0; vld_p8 <= 1'b0;
        end else begin
            vld_p8 <= vld_p7;
            if (vld_p7) disc_final <= disc_q6;
        end
    end

    generate if (STEREO_ENABLE) begin : gen_pll_p8
    always @(posedge clk) begin
        if (!rst_n) begin
            nco_phase <= {ACC_W{1'b0}}; lmr_raw_final <= 30'sd0;
        end else if (vld_p7) begin
            nco_phase     <= nco_phase + fw_q[ACC_W-1:0];
            lmr_raw_final <= lmr_raw_q5;
        end
    end
    end endgenerate

    localparam signed [17:0] NOTCH_B0 = 18'sd31818;
    localparam signed [17:0] NOTCH_B1 = -18'sd56518;
    localparam signed [17:0] NOTCH_B2 = 18'sd31818;
    localparam signed [17:0] NOTCH_A1 = -18'sd56518;
    localparam signed [17:0] NOTCH_A2 = 18'sd30868;
    localparam NOTCH_QSHIFT = 15;

    // =========================================================================
    // L+R (mono/main) path: pilot notch filter, biquad IIR, 4-stage pipeline.
    // =========================================================================
    reg signed [17:0] lpr_x1, lpr_x2, lpr_y1, lpr_y2;
    wire signed [17:0] lpr_x_ext = disc_final;

    reg signed [35:0] lpr_m0, lpr_m1, lpr_m2, lpr_ma1, lpr_ma2;
    reg signed [17:0] lpr_xq_a;
    reg                vld_n1a;
    always @(posedge clk) begin
        if (!rst_n) begin
            lpr_m0<=36'sd0; lpr_m1<=36'sd0; lpr_m2<=36'sd0;
            lpr_ma1<=36'sd0; lpr_ma2<=36'sd0; lpr_xq_a<=18'sd0; vld_n1a<=1'b0;
        end else begin
            vld_n1a <= vld_p8;
            if (vld_p8) begin
                lpr_m0  <= NOTCH_B0*lpr_x_ext;
                lpr_m1  <= NOTCH_B1*lpr_x1;
                lpr_m2  <= NOTCH_B2*lpr_x2;
                lpr_ma1 <= NOTCH_A1*lpr_y1;
                lpr_ma2 <= NOTCH_A2*lpr_y2;
                lpr_xq_a<= lpr_x_ext;
            end
        end
    end

    reg signed [36:0] lpr_sum01, lpr_suma;
    reg signed [35:0] lpr_m2_q;
    reg signed [17:0] lpr_xq_b;
    reg                vld_n1b;
    always @(posedge clk) begin
        if (!rst_n) begin
            lpr_sum01<=37'sd0; lpr_suma<=37'sd0; lpr_m2_q<=36'sd0; lpr_xq_b<=18'sd0; vld_n1b<=1'b0;
        end else begin
            vld_n1b <= vld_n1a;
            if (vld_n1a) begin
                lpr_sum01 <= lpr_m0 + lpr_m1;
                lpr_suma  <= lpr_ma1 + lpr_ma2;
                lpr_m2_q  <= lpr_m2;
                lpr_xq_b  <= lpr_xq_a;
            end
        end
    end

    reg signed [37:0] lpr_sumb;
    reg signed [36:0] lpr_suma_q;
    reg signed [17:0] lpr_xq_c;
    reg                vld_n1c0;
    always @(posedge clk) begin
        if (!rst_n) begin
            lpr_sumb<=38'sd0; lpr_suma_q<=37'sd0; lpr_xq_c<=18'sd0; vld_n1c0<=1'b0;
        end else begin
            vld_n1c0 <= vld_n1b;
            if (vld_n1b) begin
                lpr_sumb   <= lpr_sum01 + lpr_m2_q;
                lpr_suma_q <= lpr_suma;
                lpr_xq_c   <= lpr_xq_b;
            end
        end
    end

    reg signed [38:0] lpr_diff;
    reg signed [17:0] lpr_xq_d;
    reg                vld_n1d;
    always @(posedge clk) begin
        if (!rst_n) begin
            lpr_diff<=39'sd0; lpr_xq_d<=18'sd0; vld_n1d<=1'b0;
        end else begin
            vld_n1d <= vld_n1c0;
            if (vld_n1c0) begin
                lpr_diff <= lpr_sumb - lpr_suma_q;
                lpr_xq_d <= lpr_xq_c;
            end
        end
    end

    wire signed [17:0] lpr_notched_w = lpr_diff >>> NOTCH_QSHIFT;
    reg  signed [17:0] lpr_notched;
    reg                vld_n1e;
    always @(posedge clk) begin
        if (!rst_n) begin
            lpr_notched <= 18'sd0; vld_n1e <= 1'b0;
            lpr_x1 <= 18'sd0; lpr_x2 <= 18'sd0; lpr_y1 <= 18'sd0; lpr_y2 <= 18'sd0;
        end else begin
            vld_n1e <= vld_n1d;
            if (vld_n1d) begin
                lpr_notched <= lpr_notched_w;
                lpr_x2 <= lpr_x1; lpr_x1 <= lpr_xq_d;
                lpr_y2 <= lpr_y1; lpr_y1 <= lpr_notched_w;
            end
        end
    end
    wire vld_n1c = vld_n1e;

    wire signed [22:0] lmr_x4x;

    // =========================================================================
    // L-R (stereo difference) path: pilot notch filter (same coefficients
    // as the L+R path above), CIC decimation, x4 scale for the matrix
    // stage below.
    // =========================================================================
    generate if (STEREO_ENABLE) begin : gen_lmr_notch

    reg signed [17:0] lmr_x1, lmr_x2, lmr_y1, lmr_y2;
    wire signed [17:0] lmr_x_ext = lmr_raw_final >>> 12;

    reg signed [35:0] lmr_m0, lmr_m1, lmr_m2, lmr_ma1, lmr_ma2;
    reg signed [17:0] lmr_xq_a;
    reg                vld_n2a;
    always @(posedge clk) begin
        if (!rst_n) begin
            lmr_m0<=36'sd0; lmr_m1<=36'sd0; lmr_m2<=36'sd0;
            lmr_ma1<=36'sd0; lmr_ma2<=36'sd0; lmr_xq_a<=18'sd0; vld_n2a<=1'b0;
        end else begin
            vld_n2a <= vld_p8;
            if (vld_p8) begin
                lmr_m0  <= NOTCH_B0*lmr_x_ext;
                lmr_m1  <= NOTCH_B1*lmr_x1;
                lmr_m2  <= NOTCH_B2*lmr_x2;
                lmr_ma1 <= NOTCH_A1*lmr_y1;
                lmr_ma2 <= NOTCH_A2*lmr_y2;
                lmr_xq_a<= lmr_x_ext;
            end
        end
    end

    reg signed [36:0] lmr_sum01, lmr_suma;
    reg signed [35:0] lmr_m2_q;
    reg signed [17:0] lmr_xq_b;
    reg                vld_n2b;
    always @(posedge clk) begin
        if (!rst_n) begin
            lmr_sum01<=37'sd0; lmr_suma<=37'sd0; lmr_m2_q<=36'sd0; lmr_xq_b<=18'sd0; vld_n2b<=1'b0;
        end else begin
            vld_n2b <= vld_n2a;
            if (vld_n2a) begin
                lmr_sum01 <= lmr_m0 + lmr_m1;
                lmr_suma  <= lmr_ma1 + lmr_ma2;
                lmr_m2_q  <= lmr_m2;
                lmr_xq_b  <= lmr_xq_a;
            end
        end
    end

    reg signed [37:0] lmr_sumb;
    reg signed [36:0] lmr_suma_q;
    reg signed [17:0] lmr_xq_c;
    reg                vld_n2c0;
    always @(posedge clk) begin
        if (!rst_n) begin
            lmr_sumb<=38'sd0; lmr_suma_q<=37'sd0; lmr_xq_c<=18'sd0; vld_n2c0<=1'b0;
        end else begin
            vld_n2c0 <= vld_n2b;
            if (vld_n2b) begin
                lmr_sumb   <= lmr_sum01 + lmr_m2_q;
                lmr_suma_q <= lmr_suma;
                lmr_xq_c   <= lmr_xq_b;
            end
        end
    end

    reg signed [38:0] lmr_diff;
    reg signed [17:0] lmr_xq_d;
    reg                vld_n2d;
    always @(posedge clk) begin
        if (!rst_n) begin
            lmr_diff<=39'sd0; lmr_xq_d<=18'sd0; vld_n2d<=1'b0;
        end else begin
            vld_n2d <= vld_n2c0;
            if (vld_n2c0) begin
                lmr_diff <= lmr_sumb - lmr_suma_q;
                lmr_xq_d <= lmr_xq_c;
            end
        end
    end

    wire signed [17:0] lmr_notched_w = lmr_diff >>> NOTCH_QSHIFT;
    reg  signed [17:0] lmr_notched;
    reg                vld_n2e;
    always @(posedge clk) begin
        if (!rst_n) begin
            lmr_notched <= 18'sd0; vld_n2e <= 1'b0;
            lmr_x1 <= 18'sd0; lmr_x2 <= 18'sd0; lmr_y1 <= 18'sd0; lmr_y2 <= 18'sd0;
        end else begin
            vld_n2e <= vld_n2d;
            if (vld_n2d) begin
                lmr_notched <= lmr_notched_w;
                lmr_x2 <= lmr_x1; lmr_x1 <= lmr_xq_d;
                lmr_y2 <= lmr_y1; lmr_y1 <= lmr_notched_w;
            end
        end
    end
    wire vld_n2c = vld_n2e;

    wire signed [19:0] lmr_dec;
    wire               lmr_dec_vld;
    cic_decimator #(
        .B_IN(18), .N_STAGES(3), .R_DEC(5), .B_OUT(20)
    ) u_lmr_cic (
        .clk      (clk),
        .rst_n    (rst_n),
        .data_in  (lmr_notched),
        .valid_in (vld_n2c),
        .data_out (lmr_dec),
        .valid_out(lmr_dec_vld)
    );

    wire signed [22:0] lmr_x4x_raw = {{3{lmr_dec[19]}}, lmr_dec} <<< 2;
    assign lmr_x4x = mono_sel_sync2 ? 23'sd0 : lmr_x4x_raw;

    end endgenerate

    localparam signed [17:0] MLPF1_B0=18'sd621,  MLPF1_B1=18'sd1241,  MLPF1_B2=18'sd621;
    localparam signed [17:0] MLPF1_A1=-18'sd49103, MLPF1_A2=18'sd18656;
    localparam signed [17:0] MLPF2_B0=18'sd621,  MLPF2_B1=18'sd1241,  MLPF2_B2=18'sd621;
    localparam signed [17:0] MLPF2_A1=-18'sd56191, MLPF2_A2=18'sd26079;
    localparam MLPF_QSHIFT = 15;

    // =========================================================================
    // Forced-mono low-pass filter (used when mono_sel is active): two
    // cascaded biquads. All five coefficient multiplies below are against
    // fixed localparam constants (never a runtime value), so each is
    // expanded into a non-adjacent-form (NAF) sum/difference of power-of-
    // two shifts -- an exact decomposition (not an approximation), with no
    // multiplier needed. For example 621 = +2^0-2^2-2^4+2^7+2^9.
    // =========================================================================
    wire signed [35:0] lpr_notched_ext = {{18{lpr_notched[17]}}, lpr_notched};
    wire signed [35:0] ml1_x1_ext = {{18{ml1_x1[17]}}, ml1_x1};
    wire signed [35:0] ml1_x2_ext = {{18{ml1_x2[17]}}, ml1_x2};
    wire signed [35:0] ml1_y1_ext = {{18{ml1_y1[17]}}, ml1_y1};
    wire signed [35:0] ml1_y2_ext = {{18{ml1_y2[17]}}, ml1_y2};
    // 621 = +2^0-2^2-2^4+2^7+2^9
    (* use_dsp = "no" *)     wire signed [35:0] ml1_m0_naf  = lpr_notched_ext - (lpr_notched_ext<<<2) - (lpr_notched_ext<<<4) + (lpr_notched_ext<<<7) + (lpr_notched_ext<<<9);
    // 1241 = +2^0-2^3-2^5+2^8+2^10
    (* use_dsp = "no" *)     wire signed [35:0] ml1_m1_naf  = ml1_x1_ext - (ml1_x1_ext<<<3) - (ml1_x1_ext<<<5) + (ml1_x1_ext<<<8) + (ml1_x1_ext<<<10);
    // 621 (same constant as B0)
    (* use_dsp = "no" *)     wire signed [35:0] ml1_m2_naf  = ml1_x2_ext - (ml1_x2_ext<<<2) - (ml1_x2_ext<<<4) + (ml1_x2_ext<<<7) + (ml1_x2_ext<<<9);
    // -49103 = +2^0-2^4+2^6+2^14-2^16
    (* use_dsp = "no" *)     wire signed [35:0] ml1_ma1_naf = ml1_y1_ext - (ml1_y1_ext<<<4) + (ml1_y1_ext<<<6) + (ml1_y1_ext<<<14) - (ml1_y1_ext<<<16);
    // 18656 = -2^5+2^8+2^11+2^14
    (* use_dsp = "no" *)     wire signed [35:0] ml1_ma2_naf = -(ml1_y2_ext<<<5) + (ml1_y2_ext<<<8) + (ml1_y2_ext<<<11) + (ml1_y2_ext<<<14);

    reg signed [17:0] ml1_x1, ml1_x2, ml1_y1, ml1_y2;

    reg signed [35:0] ml1_m0, ml1_m1, ml1_m2, ml1_ma1, ml1_ma2;
    reg signed [17:0] ml1_xq_a;
    reg                vld_ml1a;
    always @(posedge clk) begin
        if (!rst_n) begin
            ml1_m0<=0; ml1_m1<=0; ml1_m2<=0; ml1_ma1<=0; ml1_ma2<=0; ml1_xq_a<=0; vld_ml1a<=1'b0;
        end else begin
            vld_ml1a <= vld_n1c;
            if (vld_n1c) begin
                ml1_m0  <= ml1_m0_naf;
                ml1_m1  <= ml1_m1_naf;
                ml1_m2  <= ml1_m2_naf;
                ml1_ma1 <= ml1_ma1_naf;
                ml1_ma2 <= ml1_ma2_naf;
                ml1_xq_a<= lpr_notched;
            end
        end
    end

    reg signed [36:0] ml1_sum01, ml1_suma;
    reg signed [35:0] ml1_m2_q;
    reg signed [17:0] ml1_xq_b;
    reg                vld_ml1b;
    always @(posedge clk) begin
        if (!rst_n) begin
            ml1_sum01<=0; ml1_suma<=0; ml1_m2_q<=0; ml1_xq_b<=0; vld_ml1b<=1'b0;
        end else begin
            vld_ml1b <= vld_ml1a;
            if (vld_ml1a) begin
                ml1_sum01 <= ml1_m0 + ml1_m1;
                ml1_suma  <= ml1_ma1 + ml1_ma2;
                ml1_m2_q  <= ml1_m2;
                ml1_xq_b  <= ml1_xq_a;
            end
        end
    end

    reg signed [37:0] ml1_sumb;
    reg signed [36:0] ml1_suma_q;
    reg signed [17:0] ml1_xq_c;
    reg                vld_ml1c0;
    always @(posedge clk) begin
        if (!rst_n) begin
            ml1_sumb<=0; ml1_suma_q<=0; ml1_xq_c<=0; vld_ml1c0<=1'b0;
        end else begin
            vld_ml1c0 <= vld_ml1b;
            if (vld_ml1b) begin
                ml1_sumb   <= ml1_sum01 + ml1_m2_q;
                ml1_suma_q <= ml1_suma;
                ml1_xq_c   <= ml1_xq_b;
            end
        end
    end

    reg signed [38:0] ml1_diff;
    reg signed [17:0] ml1_xq_d;
    reg                vld_ml1d;
    always @(posedge clk) begin
        if (!rst_n) begin
            ml1_diff<=0; ml1_xq_d<=0; vld_ml1d<=1'b0;
        end else begin
            vld_ml1d <= vld_ml1c0;
            if (vld_ml1c0) begin
                ml1_diff <= ml1_sumb - ml1_suma_q;
                ml1_xq_d <= ml1_xq_c;
            end
        end
    end

    wire signed [17:0] ml1_out_w = ml1_diff >>> MLPF_QSHIFT;
    reg  signed [17:0] ml1_out;
    reg                vld_ml1e;
    always @(posedge clk) begin
        if (!rst_n) begin
            ml1_out <= 0; vld_ml1e <= 1'b0;
            ml1_x1 <= 0; ml1_x2 <= 0; ml1_y1 <= 0; ml1_y2 <= 0;
        end else begin
            vld_ml1e <= vld_ml1d;
            if (vld_ml1d) begin
                ml1_out <= ml1_out_w;
                ml1_x2 <= ml1_x1; ml1_x1 <= ml1_xq_d;
                ml1_y2 <= ml1_y1; ml1_y1 <= ml1_out_w;
            end
        end
    end

    wire signed [35:0] ml1_out_ext = {{18{ml1_out[17]}}, ml1_out};
    wire signed [35:0] ml2_x1_ext = {{18{ml2_x1[17]}}, ml2_x1};
    wire signed [35:0] ml2_x2_ext = {{18{ml2_x2[17]}}, ml2_x2};
    wire signed [35:0] ml2_y1_ext = {{18{ml2_y1[17]}}, ml2_y1};
    wire signed [35:0] ml2_y2_ext = {{18{ml2_y2[17]}}, ml2_y2};
    // 621 = +2^0-2^2-2^4+2^7+2^9 (same constant as MLPF1_B0/B2)
    (* use_dsp = "no" *)     wire signed [35:0] ml2_m0_naf  = ml1_out_ext - (ml1_out_ext<<<2) - (ml1_out_ext<<<4) + (ml1_out_ext<<<7) + (ml1_out_ext<<<9);
    // 1241 = +2^0-2^3-2^5+2^8+2^10 (same as MLPF1_B1)
    (* use_dsp = "no" *)     wire signed [35:0] ml2_m1_naf  = ml2_x1_ext - (ml2_x1_ext<<<3) - (ml2_x1_ext<<<5) + (ml2_x1_ext<<<8) + (ml2_x1_ext<<<10);
    (* use_dsp = "no" *)     wire signed [35:0] ml2_m2_naf  = ml2_x2_ext - (ml2_x2_ext<<<2) - (ml2_x2_ext<<<4) + (ml2_x2_ext<<<7) + (ml2_x2_ext<<<9);
    // -56191 = +2^0+2^7+2^10+2^13-2^16
    (* use_dsp = "no" *)     wire signed [35:0] ml2_ma1_naf = ml2_y1_ext + (ml2_y1_ext<<<7) + (ml2_y1_ext<<<10) + (ml2_y1_ext<<<13) - (ml2_y1_ext<<<16);
    // 26079 = -2^0-2^5-2^9+2^11-2^13+2^15
    (* use_dsp = "no" *)     wire signed [35:0] ml2_ma2_naf = -ml2_y2_ext - (ml2_y2_ext<<<5) - (ml2_y2_ext<<<9) + (ml2_y2_ext<<<11) - (ml2_y2_ext<<<13) + (ml2_y2_ext<<<15);

    reg signed [17:0] ml2_x1, ml2_x2, ml2_y1, ml2_y2;

    reg signed [35:0] ml2_m0, ml2_m1, ml2_m2, ml2_ma1, ml2_ma2;
    reg signed [17:0] ml2_xq_a;
    reg                vld_ml2a;
    always @(posedge clk) begin
        if (!rst_n) begin
            ml2_m0<=0; ml2_m1<=0; ml2_m2<=0; ml2_ma1<=0; ml2_ma2<=0; ml2_xq_a<=0; vld_ml2a<=1'b0;
        end else begin
            vld_ml2a <= vld_ml1e;
            if (vld_ml1e) begin
                ml2_m0  <= ml2_m0_naf;
                ml2_m1  <= ml2_m1_naf;
                ml2_m2  <= ml2_m2_naf;
                ml2_ma1 <= ml2_ma1_naf;
                ml2_ma2 <= ml2_ma2_naf;
                ml2_xq_a<= ml1_out;
            end
        end
    end

    reg signed [36:0] ml2_sum01, ml2_suma;
    reg signed [35:0] ml2_m2_q;
    reg signed [17:0] ml2_xq_b;
    reg                vld_ml2b;
    always @(posedge clk) begin
        if (!rst_n) begin
            ml2_sum01<=0; ml2_suma<=0; ml2_m2_q<=0; ml2_xq_b<=0; vld_ml2b<=1'b0;
        end else begin
            vld_ml2b <= vld_ml2a;
            if (vld_ml2a) begin
                ml2_sum01 <= ml2_m0 + ml2_m1;
                ml2_suma  <= ml2_ma1 + ml2_ma2;
                ml2_m2_q  <= ml2_m2;
                ml2_xq_b  <= ml2_xq_a;
            end
        end
    end

    reg signed [37:0] ml2_sumb;
    reg signed [36:0] ml2_suma_q;
    reg signed [17:0] ml2_xq_c;
    reg                vld_ml2c0;
    always @(posedge clk) begin
        if (!rst_n) begin
            ml2_sumb<=0; ml2_suma_q<=0; ml2_xq_c<=0; vld_ml2c0<=1'b0;
        end else begin
            vld_ml2c0 <= vld_ml2b;
            if (vld_ml2b) begin
                ml2_sumb   <= ml2_sum01 + ml2_m2_q;
                ml2_suma_q <= ml2_suma;
                ml2_xq_c   <= ml2_xq_b;
            end
        end
    end

    reg signed [38:0] ml2_diff;
    reg signed [17:0] ml2_xq_d;
    reg                vld_ml2d;
    always @(posedge clk) begin
        if (!rst_n) begin
            ml2_diff<=0; ml2_xq_d<=0; vld_ml2d<=1'b0;
        end else begin
            vld_ml2d <= vld_ml2c0;
            if (vld_ml2c0) begin
                ml2_diff <= ml2_sumb - ml2_suma_q;
                ml2_xq_d <= ml2_xq_c;
            end
        end
    end

    wire signed [17:0] ml2_out_w = ml2_diff >>> MLPF_QSHIFT;
    (* KEEP = "TRUE" *) reg  signed [17:0] mono_filtered;
    reg                vld_mono_filt;
    always @(posedge clk) begin
        if (!rst_n) begin
            mono_filtered <= 0; vld_mono_filt <= 1'b0;
            ml2_x1 <= 0; ml2_x2 <= 0; ml2_y1 <= 0; ml2_y2 <= 0;
        end else begin
            vld_mono_filt <= vld_ml2d;
            if (vld_ml2d) begin
                mono_filtered <= ml2_out_w;
                ml2_x2 <= ml2_x1; ml2_x1 <= ml2_xq_d;
                ml2_y2 <= ml2_y1; ml2_y1 <= ml2_out_w;
            end
        end
    end

    (* ASYNC_REG = "TRUE" *) reg mono_sel_sync1;
    (* ASYNC_REG = "TRUE" *) reg mono_sel_sync2;
    wire signed [17:0] lpr_for_cic;
    wire               vld_for_cic;

    generate if (STEREO_ENABLE) begin : gen_mono_sel
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mono_sel_sync1 <= 1'b0;
            mono_sel_sync2 <= 1'b0;
        end else begin
            mono_sel_sync1 <= mono_sel;
            mono_sel_sync2 <= mono_sel_sync1;
        end
    end
    assign lpr_for_cic = mono_sel_sync2 ? mono_filtered  : lpr_notched;
    assign vld_for_cic = mono_sel_sync2 ? vld_mono_filt : vld_n1c;
    end else begin : gen_mono_sel_bypass
    assign lpr_for_cic = mono_filtered;
    assign vld_for_cic = vld_mono_filt;
    end
    endgenerate

    wire signed [19:0] lpr_dec;
    wire               lpr_dec_vld;

    cic_decimator #(
        .B_IN(18), .N_STAGES(3), .R_DEC(5), .B_OUT(20)
    ) u_lpr_cic (
        .clk      (clk),
        .rst_n    (rst_n),
        .data_in  (lpr_for_cic),
        .valid_in (vld_for_cic),
        .data_out (lpr_dec),
        .valid_out(lpr_dec_vld)
    );

    wire signed [22:0] lpr_ext = {{3{lpr_dec[19]}}, lpr_dec};

    // =========================================================================
    // L/R matrix: L = (L+R) + (L-R), R = (L+R) - (L-R).
    // =========================================================================
    reg signed [23:0] mtx_l, mtx_r;
    reg               vld_mtx;

    generate if (STEREO_ENABLE) begin : gen_mtx

    always @(posedge clk) begin
        if (!rst_n) begin
            mtx_l <= 24'sd0; mtx_r <= 24'sd0; vld_mtx <= 1'b0;
        end else begin
            vld_mtx <= lpr_dec_vld;
            if (lpr_dec_vld) begin
                mtx_l <= lpr_ext + lmr_x4x;
                mtx_r <= lpr_ext - lmr_x4x;
            end
        end
    end

    end else begin : gen_mtx_bypass
    always @(posedge clk) begin
        if (!rst_n) begin
            mtx_l <= 24'sd0; mtx_r <= 24'sd0; vld_mtx <= 1'b0;
        end else begin
            vld_mtx <= lpr_dec_vld;
            if (lpr_dec_vld) begin
                mtx_l <= lpr_ext;
                mtx_r <= lpr_ext;
            end
        end
    end
    end
    endgenerate

    reg signed [23:0] boosted_l, boosted_r;
    reg                vld_bb;

    // =========================================================================
    // Bass boost: a leaky-integrator low-pass extracts the bass band, which
    // is scaled by BASS_GAIN and added back on top of the full-band signal.
    // =========================================================================
    generate if (BASS_BOOST_ENABLE) begin : gen_bass_boost

    (* ASYNC_REG = "TRUE" *) reg bass_boost_en_sync1;
    (* ASYNC_REG = "TRUE" *) reg bass_boost_en_sync2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bass_boost_en_sync1 <= 1'b0;
            bass_boost_en_sync2 <= 1'b0;
        end else begin
            bass_boost_en_sync1 <= bass_boost_en;
            bass_boost_en_sync2 <= bass_boost_en_sync1;
        end
    end

    reg signed [24+BASS_LPF_SHIFT-1:0] bass_lpf_l, bass_lpf_r;
    reg signed [24+BASS_LPF_SHIFT-1:0] bb_err_l, bb_err_r;
    reg signed [23:0] bb_mtx_l_q1, bb_mtx_r_q1;
    reg                bb_vld_a;
    always @(posedge clk) begin
        if (!rst_n) begin
            bb_err_l <= 0; bb_err_r <= 0;
            bb_mtx_l_q1 <= 24'sd0; bb_mtx_r_q1 <= 24'sd0; bb_vld_a <= 1'b0;
        end else begin
            bb_vld_a <= vld_mtx;
            if (vld_mtx) begin
                bb_err_l <= $signed({{BASS_LPF_SHIFT{mtx_l[23]}}, mtx_l}) - bass_lpf_l;
                bb_err_r <= $signed({{BASS_LPF_SHIFT{mtx_r[23]}}, mtx_r}) - bass_lpf_r;
                bb_mtx_l_q1 <= mtx_l; bb_mtx_r_q1 <= mtx_r;
            end
        end
    end

    reg signed [23:0] bb_mtx_l_q2, bb_mtx_r_q2;
    reg                bb_vld_b;
    always @(posedge clk) begin
        if (!rst_n) begin
            bass_lpf_l <= 0; bass_lpf_r <= 0;
            bb_mtx_l_q2 <= 24'sd0; bb_mtx_r_q2 <= 24'sd0; bb_vld_b <= 1'b0;
        end else begin
            bb_vld_b <= bb_vld_a;
            if (bb_vld_a) begin
                bass_lpf_l <= bass_lpf_l + (bb_err_l >>> BASS_LPF_SHIFT);
                bass_lpf_r <= bass_lpf_r + (bb_err_r >>> BASS_LPF_SHIFT);
                bb_mtx_l_q2 <= bb_mtx_l_q1; bb_mtx_r_q2 <= bb_mtx_r_q1;
            end
        end
    end

    wire signed [23:0] bass_lpf_readout_l = bass_lpf_l[23:0];
    wire signed [23:0] bass_lpf_readout_r = bass_lpf_r[23:0];

    // At the default parameters (BASS_GAIN=256=2^8, BASS_GAIN_SHIFT=8), the
    // composition (x*BASS_GAIN)>>>BASS_GAIN_SHIFT is the exact identity x
    // (no precision loss). bb_premul_l/r is the "pre-multiply" value common
    // to both branches below (produced by both at the same pipeline stage,
    // bb_vld_c), so the following >>>BASS_GAIN_SHIFT (stage bb_vld_d) stays
    // a single, unconditional path shared by both. The generate-if branches
    // on an elaboration-time condition: if BASS_GAIN is ever configured to
    // a value that is not a power of two equal to 2^BASS_GAIN_SHIFT, the
    // general (genuine-multiplier) path below is used automatically.
    localparam BB_GAIN_IS_UNITY_SHIFT = (BASS_GAIN == (10'd1 <<< BASS_GAIN_SHIFT));
    localparam BB_PREMUL_W = 24 + 10; // bass_lpf_readout(24) x BASS_GAIN(10), common width for both branches

    (* use_dsp = "no" *) reg signed [BB_PREMUL_W-1:0] bb_premul_l, bb_premul_r;
    reg signed [23:0] bb_mtx_l_q3, bb_mtx_r_q3;
    reg                bb_vld_c;

    if (BB_GAIN_IS_UNITY_SHIFT) begin : gen_bb_gain_identity
        // (x*BASS_GAIN)>>>BASS_GAIN_SHIFT == x -- bb_premul is obtained as
        // x<<<BASS_GAIN_SHIFT (equivalent to x*256 at the default
        // BASS_GAIN_SHIFT=8), with no DSP48E1 required.
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                bb_premul_l <= {BB_PREMUL_W{1'b0}}; bb_premul_r <= {BB_PREMUL_W{1'b0}};
                bb_mtx_l_q3 <= 24'sd0; bb_mtx_r_q3 <= 24'sd0; bb_vld_c <= 1'b0;
            end else begin
                bb_vld_c <= bb_vld_b;
                if (bb_vld_b) begin
                    bb_premul_l <= $signed({{(BB_PREMUL_W-24){bass_lpf_readout_l[23]}}, bass_lpf_readout_l}) <<< BASS_GAIN_SHIFT;
                    bb_premul_r <= $signed({{(BB_PREMUL_W-24){bass_lpf_readout_r[23]}}, bass_lpf_readout_r}) <<< BASS_GAIN_SHIFT;
                    bb_mtx_l_q3 <= bb_mtx_l_q2; bb_mtx_r_q3 <= bb_mtx_r_q2;
                end
            end
        end
    end else begin : gen_bb_gain_general
        // General case -- an actual multiply (only used if BASS_GAIN is
        // overridden to a value other than 2^BASS_GAIN_SHIFT).
        reg signed [27:0] bb_hi_m_l, bb_lo_m_l, bb_hi_m_r, bb_lo_m_r;
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                bb_hi_m_l <= 0; bb_lo_m_l <= 0; bb_hi_m_r <= 0; bb_lo_m_r <= 0;
                bb_premul_l <= {BB_PREMUL_W{1'b0}}; bb_premul_r <= {BB_PREMUL_W{1'b0}};
                bb_mtx_l_q3 <= 24'sd0; bb_mtx_r_q3 <= 24'sd0; bb_vld_c <= 1'b0;
            end else begin
                bb_vld_c <= bb_vld_b;
                if (bb_vld_b) begin
                    bb_hi_m_l <= $signed(bass_lpf_readout_l[23:14]) * $signed({1'b0, BASS_GAIN});
                    bb_lo_m_l <= bass_lpf_readout_l[13:0] * BASS_GAIN;
                    bb_hi_m_r <= $signed(bass_lpf_readout_r[23:14]) * $signed({1'b0, BASS_GAIN});
                    bb_lo_m_r <= bass_lpf_readout_r[13:0] * BASS_GAIN;
                    bb_premul_l <= $signed({bb_hi_m_l, 14'b0}) + bb_lo_m_l;
                    bb_premul_r <= $signed({bb_hi_m_r, 14'b0}) + bb_lo_m_r;
                    bb_mtx_l_q3 <= bb_mtx_l_q2; bb_mtx_r_q3 <= bb_mtx_r_q2;
                end
            end
        end
    end
    reg signed [31:0] bb_boost_l, bb_boost_r;
    reg signed [23:0] bb_mtx_l_q4, bb_mtx_r_q4;
    reg                bb_vld_d;
    always @(posedge clk) begin
        if (!rst_n) begin
            bb_boost_l <= 0; bb_boost_r <= 0;
            bb_mtx_l_q4 <= 24'sd0; bb_mtx_r_q4 <= 24'sd0; bb_vld_d <= 1'b0;
        end else begin
            bb_vld_d <= bb_vld_c;
            if (bb_vld_c) begin
                bb_boost_l <= bb_premul_l >>> BASS_GAIN_SHIFT;
                bb_boost_r <= bb_premul_r >>> BASS_GAIN_SHIFT;
                bb_mtx_l_q4 <= bb_mtx_l_q3; bb_mtx_r_q4 <= bb_mtx_r_q3;
            end
        end
    end

    wire signed [32:0] bb_boost_l_gated = bass_boost_en_sync2 ? bb_boost_l : 32'sd0;
    wire signed [32:0] bb_boost_r_gated = bass_boost_en_sync2 ? bb_boost_r : 32'sd0;

    wire signed [32:0] bb_sum_l = $signed({{5{bb_mtx_l_q4[23]}}, bb_mtx_l_q4}) + bb_boost_l_gated;
    wire signed [32:0] bb_sum_r = $signed({{5{bb_mtx_r_q4[23]}}, bb_mtx_r_q4}) + bb_boost_r_gated;
    wire bb_ovf_l = |(bb_sum_l[32:23] ^ {10{bb_sum_l[23]}});
    wire bb_ovf_r = |(bb_sum_r[32:23] ^ {10{bb_sum_r[23]}});

    always @(posedge clk) begin
        if (!rst_n) begin
            boosted_l <= 24'sd0; boosted_r <= 24'sd0; vld_bb <= 1'b0;
        end else begin
            vld_bb <= bb_vld_d;
            if (bb_vld_d) begin
                boosted_l <= !bb_ovf_l ? bb_sum_l[23:0] : (bb_sum_l[32] ? 24'sh800000 : 24'sh7FFFFF);
                boosted_r <= !bb_ovf_r ? bb_sum_r[23:0] : (bb_sum_r[32] ? 24'sh800000 : 24'sh7FFFFF);
            end
        end
    end

    end else begin : gen_bass_boost_bypass
    always @(posedge clk) begin
        if (!rst_n) begin
            boosted_l <= 24'sd0; boosted_r <= 24'sd0; vld_bb <= 1'b0;
        end else begin
            vld_bb <= vld_mtx;
            if (vld_mtx) begin
                boosted_l <= mtx_l;
                boosted_r <= mtx_r;
            end
        end
    end

    end
    endgenerate

    (* ASYNC_REG = "TRUE" *) reg deemph_75us_sync1;
    (* ASYNC_REG = "TRUE" *) reg deemph_75us_sync2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            deemph_75us_sync1 <= 1'b0;
            deemph_75us_sync2 <= 1'b0;
        end else begin
            deemph_75us_sync1 <= deemph_sel;
            deemph_75us_sync2 <= deemph_75us_sync1;
        end
    end
    wire signed [8:0] DEEMPH_A_eff = deemph_75us_sync2 ? DEEMPH_A_75US : DEEMPH_A_50US;

    (* ASYNC_REG = "TRUE" *) reg [3:0] volume_sync1, volume_sync2;
    (* ASYNC_REG = "TRUE" *) reg       mute_en_sync1, mute_en_sync2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            volume_sync1 <= 4'd0; volume_sync2 <= 4'd0;
            mute_en_sync1 <= 1'b0; mute_en_sync2 <= 1'b0;
        end else begin
            volume_sync1 <= volume;       volume_sync2 <= volume_sync1;
            mute_en_sync1 <= mute_en;     mute_en_sync2 <= mute_en_sync1;
        end
    end

    function signed [9:0] volume_lut;
        input [3:0] lvl;
        begin
            case (lvl)
                 0: volume_lut = 10'sd0;
                 1: volume_lut = 10'sd1;
                 2: volume_lut = 10'sd1;
                 3: volume_lut = 10'sd2;
                 4: volume_lut = 10'sd3;
                 5: volume_lut = 10'sd4;
                 6: volume_lut = 10'sd6;
                 7: volume_lut = 10'sd8;
                 8: volume_lut = 10'sd11;
                 9: volume_lut = 10'sd16;
                10: volume_lut = 10'sd23;
                11: volume_lut = 10'sd32;
                12: volume_lut = 10'sd45;
                13: volume_lut = 10'sd64;
                14: volume_lut = 10'sd91;
                15: volume_lut = 10'sd128;
                default: volume_lut = 10'sd0;
            endcase
        end
    endfunction

    reg signed [9:0] VOL_eff;
    always @(posedge clk) begin
        if (!rst_n) VOL_eff <= 10'sd0;
        else        VOL_eff <= mute_en_sync2 ? 10'sd0 : volume_lut(volume_sync2);
    end

    localparam signed [31:0] SAT_HI =  32'sd8388607;
    localparam signed [31:0] SAT_LO = -32'sd8388608;

    wire signed [27:0] x_de_l = {{4{boosted_l[23]}}, boosted_l};
    wire                l_audio_vld;

    // =========================================================================
    // De-emphasis (L channel) + volume scale. Note: .volume() on this
    // module is hard-wired to the constant 4'd15 in the top-level
    // instantiation (axi_sdr_fm.v) -- real volume is applied downstream, in
    // audio_resampler. So VOL_eff here only ever takes one of two values:
    // 0 (mute_en=1) or volume_lut(15)=128 (mute_en=0), never anything in
    // between. Multiplying by the constant 128=2^7 is a shift, not a
    // multiply, so the volume scale below uses a conditional shift
    // (l_vol_shifted) rather than a genuine multiplier, while keeping the
    // exact same pipeline depth the multiply-based version would have had.
    // =========================================================================
    generate if (DEEMPH_ENABLE) begin : gen_deemph_l
        reg signed [27:0] deemph_y_l;
        reg signed [27:0] l_err_q, l_yold_q;       reg l_vld_a;
        reg signed [23:0] l_err_hi_m, l_err_lo_m;
        reg signed [31:0] l_vol_shifted;
        reg signed [27:0] l_yold_q2a;
        reg                l_vld_b1;
        reg signed [27:0] l_step_q, l_yold_q2;     reg l_vld_b;
        reg signed [31:0] l_scaled_q;              reg l_vld_5a;

        always @(posedge clk) begin
            if (!rst_n) begin
                l_err_q<=28'sd0; l_yold_q<=28'sd0; l_vld_a<=1'b0;
            end else begin
                l_vld_a <= vld_bb;
                if (vld_bb) begin
                    l_err_q  <= x_de_l - deemph_y_l;
                    l_yold_q <= deemph_y_l;
                end
            end
        end
        reg signed [27:0] l_err_q_d, l_yold_q_d;
        reg signed [8:0]  l_deemph_a_q;
        reg signed [9:0]  l_vol_q;
        reg                l_vld_a2;
        always @(posedge clk) begin
            if (!rst_n) begin
                l_err_q_d<=28'sd0; l_yold_q_d<=28'sd0;
                l_deemph_a_q<=9'sd0; l_vol_q<=10'sd0; l_vld_a2<=1'b0;
            end else begin
                l_vld_a2 <= l_vld_a;
                if (l_vld_a) begin
                    l_err_q_d    <= l_err_q;
                    l_yold_q_d   <= l_yold_q;
                    l_deemph_a_q <= DEEMPH_A_eff;
                    l_vol_q      <= VOL_eff;
                end
            end
        end
        always @(posedge clk) begin
            if (!rst_n) begin
                l_err_hi_m<=24'sd0; l_err_lo_m<=24'sd0;
                l_vol_shifted<=32'sd0;
                l_yold_q2a<=28'sd0; l_vld_b1<=1'b0;
            end else begin
                l_vld_b1 <= l_vld_a2;
                if (l_vld_a2) begin
                    l_err_hi_m <= $signed(l_err_q_d[27:14]) * l_deemph_a_q;
                    l_err_lo_m <= l_err_q_d[13:0] * l_deemph_a_q;
                    l_vol_shifted <= (l_vol_q == 10'sd0) ? 32'sd0
                                    : ({{4{l_yold_q_d[27]}}, l_yold_q_d} <<< 7);
                    l_yold_q2a <= l_yold_q_d;
                end
            end
        end
        always @(posedge clk) begin
            if (!rst_n) begin
                l_step_q<=28'sd0; l_yold_q2<=28'sd0; l_vld_b<=1'b0;
                l_scaled_q<=32'sd0; l_vld_5a<=1'b0;
            end else begin
                l_vld_b  <= l_vld_b1;
                l_vld_5a <= l_vld_b1;
                if (l_vld_b1) begin
                    l_step_q   <= (($signed({l_err_hi_m, 14'b0}) + l_err_lo_m) >>> DEEMPH_SHIFT);
                    l_yold_q2  <= l_yold_q2a;
                    l_scaled_q <= l_vol_shifted;
                end
            end
        end
        always @(posedge clk) begin
            if (!rst_n) deemph_y_l <= 28'sd0;
            else if (l_vld_b) deemph_y_l <= l_yold_q2 + l_step_q;
        end
        wire ovf_l = |(l_scaled_q[31:23] ^ {9{l_scaled_q[23]}});
        always @(posedge clk) begin
            if (!rst_n) begin
                audio_l <= 24'sd0;
            end else if (l_vld_5a) begin
                if (!ovf_l)            audio_l <= l_scaled_q[23:0];
                else if (l_scaled_q[31]) audio_l <= 24'sh800000;
                else                     audio_l <= 24'sh7FFFFF;
            end
        end
        assign l_audio_vld = l_vld_5a;
    end else begin : gen_deemph_bypass_l
        reg signed [27:0] l_yold_q;                reg l_vld_a;
        // Same reasoning as gen_deemph_l above -- VOL_eff is always 0 or
        // 128 here, so the multiply is a shift and needs no DSP; pipeline
        // depth matches the enabled path.
        reg signed [31:0] l_vol_shifted;
        reg                l_vld_b1;
        reg signed [31:0] l_scaled_q;              reg l_vld_5a;

        always @(posedge clk) begin
            if (!rst_n) begin
                l_yold_q<=28'sd0; l_vld_a<=1'b0;
            end else begin
                l_vld_a <= vld_bb;
                if (vld_bb) l_yold_q <= x_de_l;
            end
        end
        always @(posedge clk) begin
            if (!rst_n) begin
                l_vol_shifted<=32'sd0; l_vld_b1<=1'b0;
            end else begin
                l_vld_b1 <= l_vld_a;
                if (l_vld_a) begin
                    l_vol_shifted <= (VOL_eff == 10'sd0) ? 32'sd0
                                    : ({{4{l_yold_q[27]}}, l_yold_q} <<< 7);
                end
            end
        end
        always @(posedge clk) begin
            if (!rst_n) begin
                l_scaled_q<=32'sd0; l_vld_5a<=1'b0;
            end else begin
                l_vld_5a <= l_vld_b1;
                if (l_vld_b1) l_scaled_q <= l_vol_shifted;
            end
        end
        wire ovf_l = |(l_scaled_q[31:23] ^ {9{l_scaled_q[23]}});
        always @(posedge clk) begin
            if (!rst_n) begin
                audio_l <= 24'sd0;
            end else if (l_vld_5a) begin
                if (!ovf_l)            audio_l <= l_scaled_q[23:0];
                else if (l_scaled_q[31]) audio_l <= 24'sh800000;
                else                     audio_l <= 24'sh7FFFFF;
            end
        end
        assign l_audio_vld = l_vld_5a;
    end
    endgenerate

    wire signed [27:0] x_de_r = {{4{boosted_r[23]}}, boosted_r};

    // De-emphasis (R channel) + volume scale -- mirrors the L channel above.
    generate if (DEEMPH_ENABLE) begin : gen_deemph_r
        reg signed [27:0] deemph_y_r;
        reg signed [27:0] r_err_q, r_yold_q;       reg r_vld_a;
        reg signed [23:0] r_err_hi_m, r_err_lo_m;
        reg signed [31:0] r_vol_shifted;
        reg signed [27:0] r_yold_q2a;
        reg                r_vld_b1;
        reg signed [27:0] r_step_q, r_yold_q2;     reg r_vld_b;
        reg signed [31:0] r_scaled_q;              reg r_vld_5a;

        always @(posedge clk) begin
            if (!rst_n) begin
                r_err_q<=28'sd0; r_yold_q<=28'sd0; r_vld_a<=1'b0;
            end else begin
                r_vld_a <= vld_bb;
                if (vld_bb) begin
                    r_err_q  <= x_de_r - deemph_y_r;
                    r_yold_q <= deemph_y_r;
                end
            end
        end
        reg signed [27:0] r_err_q_d, r_yold_q_d;
        reg signed [8:0]  r_deemph_a_q;
        reg signed [9:0]  r_vol_q;
        reg                r_vld_a2;
        always @(posedge clk) begin
            if (!rst_n) begin
                r_err_q_d<=28'sd0; r_yold_q_d<=28'sd0;
                r_deemph_a_q<=9'sd0; r_vol_q<=10'sd0; r_vld_a2<=1'b0;
            end else begin
                r_vld_a2 <= r_vld_a;
                if (r_vld_a) begin
                    r_err_q_d    <= r_err_q;
                    r_yold_q_d   <= r_yold_q;
                    r_deemph_a_q <= DEEMPH_A_eff;
                    r_vol_q      <= VOL_eff;
                end
            end
        end
        always @(posedge clk) begin
            if (!rst_n) begin
                r_err_hi_m<=24'sd0; r_err_lo_m<=24'sd0;
                r_vol_shifted<=32'sd0;
                r_yold_q2a<=28'sd0; r_vld_b1<=1'b0;
            end else begin
                r_vld_b1 <= r_vld_a2;
                if (r_vld_a2) begin
                    r_err_hi_m <= $signed(r_err_q_d[27:14]) * r_deemph_a_q;
                    r_err_lo_m <= r_err_q_d[13:0] * r_deemph_a_q;
                    r_vol_shifted <= (r_vol_q == 10'sd0) ? 32'sd0
                                    : ({{4{r_yold_q_d[27]}}, r_yold_q_d} <<< 7);
                    r_yold_q2a <= r_yold_q_d;
                end
            end
        end
        always @(posedge clk) begin
            if (!rst_n) begin
                r_step_q<=28'sd0; r_yold_q2<=28'sd0; r_vld_b<=1'b0;
                r_scaled_q<=32'sd0; r_vld_5a<=1'b0;
            end else begin
                r_vld_b  <= r_vld_b1;
                r_vld_5a <= r_vld_b1;
                if (r_vld_b1) begin
                    r_step_q   <= (($signed({r_err_hi_m, 14'b0}) + r_err_lo_m) >>> DEEMPH_SHIFT);
                    r_yold_q2  <= r_yold_q2a;
                    r_scaled_q <= r_vol_shifted;
                end
            end
        end
        always @(posedge clk) begin
            if (!rst_n) deemph_y_r <= 28'sd0;
            else if (r_vld_b) deemph_y_r <= r_yold_q2 + r_step_q;
        end
        wire ovf_r = |(r_scaled_q[31:23] ^ {9{r_scaled_q[23]}});
        always @(posedge clk) begin
            if (!rst_n) begin
                audio_r <= 24'sd0;
            end else if (r_vld_5a) begin
                if (!ovf_r)              audio_r <= r_scaled_q[23:0];
                else if (r_scaled_q[31]) audio_r <= 24'sh800000;
                else                     audio_r <= 24'sh7FFFFF;
            end
        end
    end else begin : gen_deemph_bypass_r
        reg signed [27:0] r_yold_q;                reg r_vld_a;
        reg signed [31:0] r_vol_shifted;
        reg                r_vld_b1;
        reg signed [31:0] r_scaled_q;              reg r_vld_5a;

        always @(posedge clk) begin
            if (!rst_n) begin
                r_yold_q<=28'sd0; r_vld_a<=1'b0;
            end else begin
                r_vld_a <= vld_bb;
                if (vld_bb) r_yold_q <= x_de_r;
            end
        end
        always @(posedge clk) begin
            if (!rst_n) begin
                r_vol_shifted<=32'sd0; r_vld_b1<=1'b0;
            end else begin
                r_vld_b1 <= r_vld_a;
                if (r_vld_a) begin
                    r_vol_shifted <= (VOL_eff == 10'sd0) ? 32'sd0
                                    : ({{4{r_yold_q[27]}}, r_yold_q} <<< 7);
                end
            end
        end
        always @(posedge clk) begin
            if (!rst_n) begin
                r_scaled_q<=32'sd0; r_vld_5a<=1'b0;
            end else begin
                r_vld_5a <= r_vld_b1;
                if (r_vld_b1) r_scaled_q <= r_vol_shifted;
            end
        end
        wire ovf_r = |(r_scaled_q[31:23] ^ {9{r_scaled_q[23]}});
        always @(posedge clk) begin
            if (!rst_n) begin
                audio_r <= 24'sd0;
            end else if (r_vld_5a) begin
                if (!ovf_r)              audio_r <= r_scaled_q[23:0];
                else if (r_scaled_q[31]) audio_r <= 24'sh800000;
                else                     audio_r <= 24'sh7FFFFF;
            end
        end
    end
    endgenerate

    always @(posedge clk) begin
        if (!rst_n) audio_valid <= 1'b0;
        else        audio_valid <= l_audio_vld;
    end

endmodule