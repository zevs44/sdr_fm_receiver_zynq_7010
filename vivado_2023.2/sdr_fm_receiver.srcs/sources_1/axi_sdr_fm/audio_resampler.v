`timescale 1ns / 1ps
// =============================================================================
// Module : audio_resampler  (single time-multiplexed multiplier variant)
// Purpose: audio path between the FM demodulator and the DAC:
//            - linear-interpolation, parametric resampler FS_IN -> FS_OUT
//            - switchable de-emphasis filter (suppresses FM demod HF noise)
//            - switchable equalizer with a parametric number of bands (NB)
//            - digital volume control (0-15) and mute_en
//
// -------------------------------------------------------------------------
// Single-multiplier (1 DSP48E1) architecture
// -------------------------------------------------------------------------
// The core clock is 50 MHz while the audio stream runs at tens to hundreds
// of kHz, so each input sample gets clk/FS_IN cycles to work with
// (50 MHz / 192 kHz ~ 260 cycles, 50 MHz / 50 kHz = 1000 cycles). The full
// path only needs about (4*NB+10) multiplies per output sample (NB=3 ~ 22,
// NB=6 ~ 34), which leaves enough margin to time-multiplex a SINGLE
// multiplier across every operation instead of running ~15-30 multipliers
// in parallel.
//
// A micro-sequencer (FSM) steps through one multiply per cycle via a
// single shared expression mul_p = mul_a * mul_b (25x18 signed -> exactly
// one DSP48E1). Operands are muxed by phase/band/channel and the result is
// routed to the appropriate register. There is no other multiply anywhere
// in the RTL, so synthesis produces exactly 1 DSP regardless of NB,
// FILTER_EN, or EQ_EN.
//
//     DSP48E1 count: 1 (a fully-parallel version would need
//                       1+2+2+(NB-1)*2+NB*2 = 15 at NB=3, 27 at NB=6)
//
// Constraint: at least (4*NB+10) cycles must separate two valid_in strobes
// (guaranteed at 50 MHz with audio-rate sampling); back-to-back valid_in
// every cycle is not supported -- an intentional area/throughput trade-off.
//
// -------------------------------------------------------------------------
// Parametric resampler FS_IN -> FS_OUT
// -------------------------------------------------------------------------
// Input-driven: each valid_in produces 0 or 1 output samples. Supports
// decimation/unity only (FS_IN >= FS_OUT, matching the FM-demod -> DAC
// path). Exact (drift-free) integer phase accumulator:
//     A < FS_OUT:  out = in[n-1] + (in[n]-in[n-1])*A/FS_OUT ; A += FS_IN-FS_OUT
//     otherwise:                                              A -= FS_OUT
// The fraction frac = A/FS_OUT is computed in Q16 via a scaled reciprocal
// RECIP = round(2^(16+FSHIFT)/FS_OUT), FSHIFT=floor(log2 FS_OUT):
//     coef_Q16 = (A*RECIP + 2^(FSHIFT-1)) >> FSHIFT
// RECIP <= 2^16, which fits the shared multiplier's 18-bit port. The
// coefficient error is under 1 LSB; the frequency ratio itself is exact.
//
// -------------------------------------------------------------------------
// De-emphasis as a noise filter
// -------------------------------------------------------------------------
// One-pole IIR: y += k*(x - y). k=50us@48k ~ DEEMPH_COEF=22334 (Q16);
// k=75us ~ 15895. Suppresses FM-demodulator HF noise and restores the
// transmit-side pre-emphasis response.
//
// -------------------------------------------------------------------------
// Equalizer (NB bands)
// -------------------------------------------------------------------------
// Linear crossover bank: NB-1 one-pole LPF crossovers, band[0]=lp[0],
// band[i]=lp[i]-lp[i-1], band[NB-1]=x-lp[NB-2]. Sum(band)=x, so at
// gain=16 for every band the path is perfectly flat.
// out=(sum band*gain)/16, rounded, saturated to +-2^23.
// Per-band gain is eq_gain[5*i+:5] (16=0dB, 0=mute, 31=+5.7dB).
// Crossover coefficients are the flat parameter EQ_COEFS (17 bits Q16 per
// crossover, band0 in the least-significant position).
//
// Signal flow: FM demod -> [resample] -> [de-emphasis] -> [EQ] ->
//              [volume] -> [mute] -> DAC
// =============================================================================

module audio_resampler #(
    parameter integer AUDIO_W = 24,             // <= 24 for the single-DSP variant

    // --- Sample rates (Hz). Requirement: FS_IN >= FS_OUT ---
    parameter integer FS_IN  = 50000,           // input (from the FM demodulator)
    parameter integer FS_OUT = 48000,           // output (to the DAC)

    // --- De-emphasis filter ---
    parameter        FILTER_EN   = 1,           // 1 = enabled, 0 = bypass
    parameter [16:0] DEEMPH_COEF = 17'd22334,   // k in Q16: 50 us @ 48 kHz

    // --- Equalizer ---
    parameter        EQ_EN   = 1,               // 1 = enabled, 0 = bypass
    parameter integer NB      = 3,              // number of bands (>= 2)
    parameter [17*(NB-1)-1:0] EQ_COEFS = {17'd26712, 17'd2111}
)(
    input  wire                      clk,
    input  wire                      rst_n,

    input  wire signed [AUDIO_W-1:0] in_l,
    input  wire signed [AUDIO_W-1:0] in_r,
    input  wire                      valid_in,

    input  wire [5*NB-1:0]           eq_gain,    // gain[i] = eq_gain[5*i +: 5]
    input  wire [3:0]                volume,     // 0 = silence ... 15 = max
    input  wire                      mute_en,       // 1 = forced silence

    output reg  signed [AUDIO_W-1:0] out_l,
    output reg  signed [AUDIO_W-1:0] out_r,
    output reg                       valid_out
);

    // --- floor(log2), constant-folds to compute the RECIP scale ---
    function integer flog2;
        input integer value;
        integer i;
        begin
            flog2 = 0;
            for (i = 0; value > 1; i = i + 1) begin
                value = value >> 1;
                flog2 = i + 1;
            end
        end
    endfunction

    // =========================================================================
    //  Fixed-point constants
    // =========================================================================
    localparam integer ACC_W  = 32;
    localparam integer FSHIFT = flog2(FS_OUT);
    localparam [63:0]  RECIP64 = ((64'd1 << (16 + FSHIFT)) + (FS_OUT/2)) / FS_OUT;
    localparam signed [17:0] RECIP = RECIP64[17:0];

    localparam signed [AUDIO_W+18:0] RND_16    = (1 <<< 15);            // >>>16
    localparam signed [AUDIO_W+18:0] RND_COEF  = (FSHIFT > 0) ? (1 <<< (FSHIFT-1)) : 0;
    localparam signed [AUDIO_W+18:0] RND_VOL   = (1 <<< 3);             // >>>4
    localparam signed [AUDIO_W+18:0] RND_EQMIX = (1 <<< 3);             // >>>4 (EQ)

    localparam signed [AUDIO_W+12:0] SATMAX = (1 <<< (AUDIO_W-1)) - 1;
    localparam signed [AUDIO_W+12:0] SATMIN = -(1 <<< (AUDIO_W-1));
    localparam signed [AUDIO_W-1:0]  SAT_HI = {1'b0, {(AUDIO_W-1){1'b1}}};
    localparam signed [AUDIO_W-1:0]  SAT_LO = {1'b1, {(AUDIO_W-1){1'b0}}};

    integer bi;

    // --- register the control inputs ---
    reg [3:0]        vol_r;
    reg              mute_r;
    reg [5*NB-1:0]   eqg_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vol_r  <= 4'd15;
            mute_r <= 1'b0;
            for (bi = 0; bi < NB; bi = bi + 1)
                eqg_r[5*bi +: 5] <= 5'd16;
        end else begin
            vol_r  <= volume;
            mute_r <= mute_en;
            eqg_r  <= eq_gain;
        end
    end

    // =========================================================================
    //  Phase accumulator + operand capture for the sequencer
    // =========================================================================
    reg signed [ACC_W-1:0]   pacc;
    reg signed [AUDIO_W-1:0] prev_l, prev_r;

    // Operand holding registers for the current output sample (channel index 0=L,1=R)
    reg signed [AUDIO_W-1:0] base [0:1];
    reg signed [AUDIO_W-1:0] cur  [0:1];
    reg        [ACC_W-1:0]   Aval;
    reg                      start;

    // Datapath (channel index 0=L,1=R)
    reg signed [17:0]         coef;
    reg signed [AUDIO_W-1:0]  interp [0:1];
    reg signed [AUDIO_W-1:0]  yf     [0:1];              // de-emphasis state
    reg signed [AUDIO_W-1:0]  dout   [0:1];
    reg signed [AUDIO_W-1:0]  elp_l  [0:NB-2];           // crossover state
    reg signed [AUDIO_W-1:0]  elp_r  [0:NB-2];
    reg signed [AUDIO_W:0]    band_l [0:NB-1];
    reg signed [AUDIO_W:0]    band_r [0:NB-1];
    reg signed [AUDIO_W+12:0] acc    [0:1];
    reg signed [AUDIO_W-1:0]  eqout  [0:1];
    reg signed [AUDIO_W-1:0]  vout   [0:1];

    // /16 for the EQ output (rounding is already folded into acc via RND_EQMIX)
    wire signed [AUDIO_W+12:0] acc_sh0 = acc[0] >>> 4;
    wire signed [AUDIO_W+12:0] acc_sh1 = acc[1] >>> 4;

    // =========================================================================
    //  The single shared multiplier (25 x 18 signed -> 1 DSP48E1)
    // =========================================================================
    reg  signed [AUDIO_W:0]    mul_a;             // 25 bits
    reg  signed [17:0]         mul_b;             // 18 bits
    wire signed [AUDIO_W+18:0] mul_p = mul_a * mul_b;   // 43 bits

    // --- sequencer states ---
    localparam [3:0] ST_IDLE=0, ST_COEF=1, ST_INTERP=2, ST_DEEMPH=3,
                     ST_DCOPY=4, ST_XOVER=5, ST_BANDS=6, ST_GAIN=7,
                     ST_EQFIN=8, ST_ECOPY=9, ST_VOL=10, ST_DONE=11;
    reg [3:0]              state;
    reg                   ch;                     // 0=L, 1=R
    integer               kb;                     // band/crossover index

    // =========================================================================
    //  Combinational multiplier-operand select (by current sequencer phase)
    // =========================================================================
    always @(*) begin
        mul_a = {(AUDIO_W+1){1'b0}};
        mul_b = 18'sd0;
        case (state)
            ST_COEF:   begin
                mul_a = $signed({1'b0, Aval[AUDIO_W-1:0]});
                mul_b = RECIP;
            end
            ST_INTERP: begin
                mul_a = {cur[ch][AUDIO_W-1], cur[ch]} - {base[ch][AUDIO_W-1], base[ch]};
                mul_b = coef;
            end
            ST_DEEMPH: begin
                mul_a = {interp[ch][AUDIO_W-1], interp[ch]} - {yf[ch][AUDIO_W-1], yf[ch]};
                mul_b = $signed(DEEMPH_COEF);
            end
            ST_XOVER:  begin
                if (ch == 1'b0)
                    mul_a = {dout[0][AUDIO_W-1], dout[0]} - {elp_l[kb][AUDIO_W-1], elp_l[kb]};
                else
                    mul_a = {dout[1][AUDIO_W-1], dout[1]} - {elp_r[kb][AUDIO_W-1], elp_r[kb]};
                mul_b = $signed(EQ_COEFS[17*kb +: 17]);
            end
            ST_GAIN:   begin
                mul_a = (ch == 1'b0) ? band_l[kb] : band_r[kb];
                mul_b = $signed({1'b0, eqg_r[5*kb +: 5]});
            end
            ST_VOL:    begin
                mul_a = eqout[ch];
                mul_b = $signed({1'b0, vol_r});
            end
            default: ;
        endcase
    end

    // =========================================================================
    //  Main synchronous process: phase accumulator + sequencer
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pacc   <= {ACC_W{1'b0}};
            prev_l <= {AUDIO_W{1'b0}};
            prev_r <= {AUDIO_W{1'b0}};
            start  <= 1'b0;
            state  <= ST_IDLE;
            ch     <= 1'b0;
            kb     <= 0;
            valid_out <= 1'b0;
            out_l  <= {AUDIO_W{1'b0}};
            out_r  <= {AUDIO_W{1'b0}};
            yf[0]  <= {AUDIO_W{1'b0}};  yf[1] <= {AUDIO_W{1'b0}};
            for (bi = 0; bi < NB-1; bi = bi + 1) begin
                elp_l[bi] <= {AUDIO_W{1'b0}};
                elp_r[bi] <= {AUDIO_W{1'b0}};
            end
        end else begin
            valid_out <= 1'b0;
            start     <= 1'b0;

            // -- Accept input @ FS_IN: advance the phase and, when due, arm the sequencer --
            if (valid_in) begin
                if ($signed(pacc) < FS_OUT) begin
                    base[0] <= prev_l;  base[1] <= prev_r;   // input[n-1]
                    cur[0]  <= in_l;    cur[1]  <= in_r;     // input[n]
                    Aval    <= pacc[ACC_W-1:0];
                    start   <= 1'b1;
                    pacc    <= pacc + FS_IN - FS_OUT;
                end else begin
                    pacc <= pacc - FS_OUT;
                end
                prev_l <= in_l;
                prev_r <= in_r;
            end

            // -- Sequencer: one multiply per cycle through the shared mul_p --
            case (state)
                ST_IDLE: if (start) begin state <= ST_COEF; ch <= 1'b0; end

                ST_COEF: begin
                    coef  <= (mul_p + RND_COEF) >>> FSHIFT;   // Q16, 0..<2^16
                    ch    <= 1'b0;
                    state <= ST_INTERP;
                end

                ST_INTERP: begin
                    interp[ch] <= base[ch] + ((mul_p + RND_16) >>> 16);
                    if (ch == 1'b0) ch <= 1'b1;
                    else begin
                        ch <= 1'b0;
                        state <= (FILTER_EN != 0) ? ST_DEEMPH : ST_DCOPY;
                    end
                end

                ST_DEEMPH: begin
                    yf[ch]   <= yf[ch] + ((mul_p + RND_16) >>> 16);
                    dout[ch] <= yf[ch] + ((mul_p + RND_16) >>> 16);
                    if (ch == 1'b0) ch <= 1'b1;
                    else begin
                        ch <= 1'b0; kb <= 0;
                        state <= (EQ_EN != 0) ? ST_XOVER : ST_ECOPY;
                    end
                end

                ST_DCOPY: begin
                    dout[0] <= interp[0];
                    dout[1] <= interp[1];
                    ch <= 1'b0; kb <= 0;
                    state <= (EQ_EN != 0) ? ST_XOVER : ST_ECOPY;
                end

                ST_XOVER: begin
                    if (ch == 1'b0)
                        elp_l[kb] <= elp_l[kb] + ((mul_p + RND_16) >>> 16);
                    else
                        elp_r[kb] <= elp_r[kb] + ((mul_p + RND_16) >>> 16);
                    if (ch == 1'b0) ch <= 1'b1;
                    else begin
                        ch <= 1'b0;
                        if (kb == NB-2) state <= ST_BANDS;
                        else kb <= kb + 1;
                    end
                end

                ST_BANDS: begin
                    band_l[0] <= {elp_l[0][AUDIO_W-1], elp_l[0]};
                    band_r[0] <= {elp_r[0][AUDIO_W-1], elp_r[0]};
                    for (bi = 1; bi < NB-1; bi = bi + 1) begin
                        band_l[bi] <= {elp_l[bi][AUDIO_W-1], elp_l[bi]} - {elp_l[bi-1][AUDIO_W-1], elp_l[bi-1]};
                        band_r[bi] <= {elp_r[bi][AUDIO_W-1], elp_r[bi]} - {elp_r[bi-1][AUDIO_W-1], elp_r[bi-1]};
                    end
                    band_l[NB-1] <= {dout[0][AUDIO_W-1], dout[0]} - {elp_l[NB-2][AUDIO_W-1], elp_l[NB-2]};
                    band_r[NB-1] <= {dout[1][AUDIO_W-1], dout[1]} - {elp_r[NB-2][AUDIO_W-1], elp_r[NB-2]};
                    acc[0] <= RND_EQMIX;  acc[1] <= RND_EQMIX;
                    ch <= 1'b0; kb <= 0;
                    state <= ST_GAIN;
                end

                ST_GAIN: begin
                    acc[ch] <= acc[ch] + mul_p;
                    if (ch == 1'b0) ch <= 1'b1;
                    else begin
                        ch <= 1'b0;
                        if (kb == NB-1) state <= ST_EQFIN;
                        else kb <= kb + 1;
                    end
                end

                ST_EQFIN: begin
                    eqout[0] <= (acc_sh0 > SATMAX) ? SAT_HI :
                                (acc_sh0 < SATMIN) ? SAT_LO : acc_sh0[AUDIO_W-1:0] ;
                    eqout[1] <= (acc_sh1 > SATMAX) ? SAT_HI :
                                (acc_sh1 < SATMIN) ? SAT_LO : acc_sh1[AUDIO_W-1:0] ;
                    ch <= 1'b0;
                    state <= ST_VOL;
                end

                ST_ECOPY: begin
                    eqout[0] <= dout[0];
                    eqout[1] <= dout[1];
                    ch <= 1'b0;
                    state <= ST_VOL;
                end

                ST_VOL: begin
                    vout[ch] <= (mul_p + RND_VOL) >>> 4;
                    if (ch == 1'b0) ch <= 1'b1;
                    else begin ch <= 1'b0; state <= ST_DONE; end
                end

                ST_DONE: begin
                    out_l     <= mute_r ? {AUDIO_W{1'b0}} : vout[0];
                    out_r     <= mute_r ? {AUDIO_W{1'b0}} : vout[1];
                    valid_out <= 1'b1;
                    state     <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule