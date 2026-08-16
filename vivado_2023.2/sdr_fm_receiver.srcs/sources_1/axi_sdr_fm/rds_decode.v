`timescale 1ns / 1ps
// =============================================================================
// Module : rds_decode  (rev 3 -- stability fixes)
// Purpose: full hardware RDS (Radio Data System, IEC 62106) decoder.
//          57 kHz subcarrier recovery (own Costas loop), 1187.5 bit/s
//          biphase demodulation, CRC-10 block synchronization (IEC 62106
//          Annex C), extraction of PI, PTY, TP/TA/MS, group 0 (PS) and
//          group 2A (RadioText).
//
//   PROCESSING CHAIN:
//     1. 57 kHz carrier NCO (fixed, uncorrected) + quadrature mixer at
//        250 kHz, DC blocker.
//     2. CIC decimation x10 (250 kHz -> 25 kHz), I and Q separately.
//     3. Costas loop at 25 kHz: de-rotation, err = I*Q, PI loop filter.
//     4. Bit synchronization (coarse parallel phase search + proportional
//        tracking loop).
//     5. Differential decoding b[k] = g[k]^g[k-1].
//     6. Block/group synchronization (sliding syndrome search + CRC).
//     7. Group parsing (PI/PTY/TP, group 0 -> PS, group 2A -> RadioText).
//
// -----------------------------------------------------------------------------
//   REV 2 -- WHAT CHANGED AND WHY
//
//   FIX-1..FIX-6 were found by simulating this module against a synthetic but
//   correctly scaled MPX composite (fm_cordic_discrim output units: +/-75 kHz
//   deviation = +/-39322 LSB, so an RDS subcarrier at the usual 2 kHz
//   deviation is only ~1050 LSB peak). FIX-7 was found afterwards, on a 5 s
//   capture of a live station taken through the MPX export FIFO, by dumping
//   this module's own Ii_q and decoding it in software: that gave the same
//   83% block yield as a reference FIR/liquid-dsp front end, proving sections
//   1-3 were already correct and localizing the entire remaining loss to the
//   bit synchronizer below.
//
//   Measured on that live capture (blocks passing CRC / groups assembled):
//       rev 1                        19.1%  /  4
//       rev 2 (FIX-1..FIX-6)         36.5%  / 11
//       software reference decoder   83.3%  / 47
//       rev 3 (FIX-1..FIX-7)         87.6%  / 44
//
//   FIX-1  COSTAS LOOP GAIN WAS ~128x BELOW ITS DESIGN POINT (AGC ADDED).
//          Rev 1 used a FIXED pre-shift (COSTAS_PRESHIFT=6) sized for
//          "nominal |Ii_q| on the order of 2^20". Measured on a realistic
//          composite, |Ii_q| is ~2^16.5, i.e. 11x smaller. Since the
//          discriminator err = Ii*Qi is QUADRATIC in amplitude, the loop
//          gain was ~2^7 = 128x lower than intended. Consequence: the real
//          pull-in range collapsed to well under the +-6 Hz the broadcast
//          standard itself permits -- at a 5 Hz carrier offset the loop
//          never locked (Qi rms ~ Ii rms) and the block error rate went to
//          95%. Fixed by replacing the fixed pre-shift with a slow AGC: a
//          leaky-averaged magnitude estimate picks the shift so the
//          discriminator operands always land near AGC_TARGET_LOG2,
//          restoring the intended loop dynamics at ANY signal level (weak
//          station, strong station, different RDS injection depth). Set
//          COSTAS_AGC_ENABLE=0 to get the rev-1 fixed-shift behaviour back.
//
//   FIX-2  BIT_WIN WAS TOO WIDE (0.40 -> 0.25 BIT).
//          In biphase coding, transitions occur at the bit CENTRE (every
//          bit) and at the bit BOUNDARY (whenever two adjacent symbols are
//          equal, ~50% of bits). A window of +-0.40 bit around the centre
//          admits BOTH, which broke the timing recovery in two ways:
//            (a) the coarse search could not tell the correct phase from
//                one shifted by exactly half a bit period -- measured
//                candidate scores were e.g. 110 110 47 62 111 110 70 77,
//                where candidates 0 and 4 (half a bit apart) differ by ONE
//                count out of ~110, so the winner was decided by noise;
//            (b) the tracking loop had a competing false lock: a boundary
//                transition at phase error d enters the window as soon as
//                d > 0.5 + BIT_BIAS - BIT_WIN = 0.124 bit, and then pulls
//                the loop TOWARDS the boundary instead of the centre.
//          At +-0.25 bit, centre and boundary transitions are cleanly
//          separated in both roles (correct candidate scores ~2x the
//          half-shifted one), and, as a side effect, the phase correction
//          can no longer be applied near the phase wraparound, which also
//          removes a rare bit-slip path in stage B2's wrap detection.
//
//   FIX-3  COARSE METRIC IS NOW SOFT, AND ITS ACCUMULATOR WAS TOO NARROW.
//          Two separate problems with the rev-1 par_good_count:
//            (a) OVERFLOW. It was sized GOOD_CNT_W = clog2(N_BITS_PROBE+2)
//                = 7 bits, i.e. max 127, on the assumption of at most one
//                transition per bit. Biphase has up to TWO (bit centre plus
//                bit boundary), so a 64-bit scan sees ~96 real transitions
//                and more with noise. Measured on a noisy run, the scores
//                came out as 91 2 127 67 75 127 127 85 -- the "2" is a
//                candidate that counted 130 and wrapped, so a good
//                candidate could score lower than every bad one. The
//                accumulator is now sized for 2 transitions per bit.
//            (b) TIES. Counting hits inside a window produces equal scores
//                for neighbouring candidates, and the tie-break was
//                "lowest candidate index wins", i.e. arbitrary. The metric
//                now accumulates (BIT_WIN - |phase error|), so the
//                candidate closest to the true bit centre wins outright.
//
//   FIX-4  HYSTERESIS ON THE DATA SLICER.
//          The transition detector took the raw sign bit of Ii_q with no
//          matched filtering, so every noise-induced zero crossing counted
//          as a bit transition (measured: ~105 detected transitions over a
//          64-bit scan against ~96 real ones). The slicer now has a
//          hysteresis threshold derived from the AGC magnitude estimate
//          (BIT_HYST_SHIFT), so the sign only changes on a genuine
//          excursion. This is symmetric for both edge directions, so it
//          adds only a small constant detection delay, which the existing
//          BIT_BIAS correction and the tracking loop absorb.
//
//   FIX-5  BLOCK-QUALITY GATE WAS TOO LENIENT (35/50 -> QUALITY_BAD_THRESH).
//          Dropping synchronization only above 35 bad blocks out of 50
//          (70%) meant a WRONG bit-clock lock, which yields roughly 60%
//          bad blocks, was held indefinitely: block_synced stayed 1, so
//          rds_sync stayed asserted, so the RESYNC_TIMEOUT_SAMPLES timer
//          (which only runs while !block_synced) never fired and the
//          decoder never re-acquired. Observed directly in simulation:
//          5% good blocks, 0 groups, rds_sync = 1, no resync for the whole
//          run. The threshold is now a parameter, defaulting to 20/50
//          (40%) -- still far above the error rate of a genuinely locked
//          receiver on a weak signal, but low enough that a false lock is
//          abandoned within ~1 s.
//
//   FIX-6  HALF-BIT DITHER ON RE-ACQUISITION.
//          Each forced re-acquisition now offsets the candidate grid by
//          half a candidate step (1/16 bit), so a retry does not
//          re-examine exactly the same eight phases as the attempt that
//          just failed.
//
//   FIX-7  TIMING-LOOP CORRECTION WAS AN UNSIGNED SHIFT (see stage B1).
//          The dominant defect on real signals, and the reason the timing
//          loop was stuck at an unusably high gain. Written inline as
//              bit_phase_a - (err_t_a >>> BIT_KP_SHIFT)
//          the unsigned bit_phase_a makes the whole expression unsigned,
//          so the signed err_t_a is converted to unsigned before the shift
//          and >>> degenerates into a LOGICAL shift. Measured on an
//          isolated test: a timing error of -0.05 bit with a shift of 2
//          produced a correction of -0.4875 bit instead of +0.0125 bit.
//          At BIT_KP_SHIFT=1 -- and ONLY there -- the spurious
//          -2^BIT_ACC_W term cancels exactly in the 20-bit truncation, so
//          the expression happens to give the right answer; that is why
//          the original code looked functional while being locked to a
//          proportional gain of 0.5. A gain that high makes every
//          noise-induced transition throw the bit phase by a quarter bit,
//          which a clean synthetic signal never exposes (both gains decode
//          at 100%) but a live signal punishes hard: a bit-exact model of
//          this loop driven by the captured Ii_q scored 10.7% at kp=1/2
//          against 82.2% at kp<=1/4, with a free-running clock (no
//          tracking at all) also at 82-83% -- the bit rate is exact, so
//          the loop only ever needs to correct phase, never frequency.
//          Fixed by evaluating the shift in its own signed context;
//          BIT_KP_SHIFT now defaults to 2, near the fast end of a flat
//          1/4..1/64 plateau.
// =============================================================================
module rds_decode #(
    parameter RDS_PS_CHARS = 8,       // standard PS width -- 8 characters
    parameter RDS_RT_CHARS = 64,      // standard RadioText width (group 2A)

    // --- Carrier NCO / Costas loop (sections 1, 3) ---
    parameter ACC_W = 24,                                 // NCO phase format
    parameter signed [23:0] FREQ_WORD_57K = 24'sd3825205, // round(57000/250000*2^24)
    parameter KI_SHIFT_COSTAS = 20,   // Costas integral gain shift
    parameter KP_SHIFT_COSTAS = 16,   // Costas proportional gain shift.
                                       // Both are stated relative to
                                       // discriminator operands scaled to
                                       // ~2^AGC_TARGET_LOG2-1; the AGC below
                                       // guarantees that scaling, so these no
                                       // longer depend on signal level.
    parameter COSTAS_AGC_ENABLE = 1,  // FIX-1. 1 = dynamic pre-shift (AGC),
                                       // 0 = fixed COSTAS_PRESHIFT (rev-1
                                       // behaviour, kept only for comparison)
    parameter AGC_TARGET_LOG2 = 15,   // AGC target: the averaged magnitude
                                       // estimate is shifted down to about
                                       // this many bits, so |Ii_c| sits near
                                       // 2^14 with ~8x margin below the
                                       // +-2^(COSTAS_CLAMP_W-1) saturation
    parameter AGC_LP_SHIFT = 10,      // AGC averaging time constant, in
                                       // decimated samples: 2^10 = 1024 at
                                       // 25 kHz = ~41 ms. Fast enough to
                                       // settle well inside
                                       // COSTAS_SETTLE_SAMPLES, slow enough
                                       // not to track the data modulation
    parameter COSTAS_PRESHIFT = 6,    // fixed pre-shift, used only when
                                       // COSTAS_AGC_ENABLE = 0
    parameter COSTAS_CLAMP_W  = 18,   // discriminator operand width after the
                                       // clamp: 18x18 is exactly one DSP48E1
    parameter CIC_R_DEC    = 10,      // 250 kHz -> 25 kHz (~21 samples/bit)
    parameter CIC_N_STAGES = 3,
    parameter CIC_B_IN     = 18,
    parameter CIC_B_OUT    = 58,
    parameter CIC_GUARD_BITS = 30,    // REQUIRED with this project's
                                       // cic_decimator.v: it derives its own
                                       // internal width as
                                       // B_MAX = B_IN + N*ceil(log2 R)
                                       //         - (R power of 2 ? 0 : 1)
                                       //         + GUARD_BITS
                                       // and needs B_MAX > B_OUT. With
                                       // 18/3/10/58 this gives B_MAX = 59,
                                       // DISCARD = 1. Recompute if any of
                                       // CIC_B_IN/N_STAGES/R_DEC/B_OUT change.

    // --- Bit synchronization (section 4) ---
    parameter FW_CLAMP_LOG2 = 15,     // Costas frequency-correction clamp:
                                       // |df| <= 2^FW_CLAMP_LOG2 / 2^ACC_W * 25 kHz
                                       // 14 -> +-24.4 Hz, 15 -> +-48.8 Hz.
                                       // The broadcast standard allows the
                                       // subcarrier +-6 Hz, but a co-located
                                       // transmitter whose audio clock is
                                       // synthesised from a different PLL can
                                       // sit far outside that: measured +32.85
                                       // Hz (+576 ppm) on this project's own
                                       // transmitter.
    parameter BIT_ACC_W = 20,                             // bit-clock phase format
    parameter [19:0] BIT_FREQ_WORD = 20'd49807,           // round(1187.5/25000*2^20)
    parameter [19:0] BIT_WIN = 20'd262144,                // FIX-2: +-0.25 bit (was 419430 = 0.40).
                                                           // Must stay < 0.5-BIT_BIAS so that bit-boundary
                                                           // transitions are excluded from both the coarse
                                                           // metric and the tracking loop
    parameter BIT_KP_SHIFT = 2,                           // tracking-loop proportional gain: the phase
                                                           // correction applied per detected transition is
                                                           // (timing error >> this)
    parameter BIT_HYST_SHIFT = 3,                         // FIX-4: slicer hysteresis =
                                                           // (AGC magnitude estimate >> this).
                                                           // 0 disables hysteresis
    parameter N_COARSE_CANDIDATES = 8,                    // coarse search: 8 starting phases (1/8-bit step)
    parameter N_BITS_PROBE = 64,                          // bits "listened to" per candidate
    parameter COSTAS_SETTLE_SAMPLES = 17'd6000,           // ~0.24 s of decimated samples before the coarse
                                                           // search starts (Costas loop + AGC settling)
    parameter [5:0] QUALITY_BAD_THRESH = 6'd20,           // FIX-5: drop block sync above this many bad
                                                           // blocks per 50-block window (was hardcoded 35)
    parameter [21:0] RESYNC_TIMEOUT_SAMPLES = 22'd75000   // 3 s of decimated samples: if block sync is not
                                                           // reached within this time after entering TRACK,
                                                           // the whole acquisition restarts
)(
    input  wire                          clk,        // s_axi_aclk domain (see axi_sdr_fm.v)
    input  wire                          rst_n,
    input  wire                          rds_en,     // 1 = decoding enabled

    input  wire signed [17:0]            mpx_in,     // MPX composite @ 250 kHz (fm_cordic_discrim)
    input  wire                          mpx_valid,

    output reg                           rds_sync,   // 1 = block/group synchronization achieved
    output reg  [8*RDS_PS_CHARS-1:0]     rds_ps,     // station name, ASCII, MS character first
    output reg  [15:0]                   rds_pi,     // Programme Identification (block A)
    output reg  [4:0]                    rds_pty,    // Programme Type (block B)
    output reg                           rds_tp,     // Traffic Programme (block B)
    output reg                           rds_ta,     // Traffic Announcement (group 0)
    output reg                           rds_ms,     // Music/Speech (group 0)
    output reg  [8*RDS_RT_CHARS-1:0]     rds_rt,     // RadioText (group 2A), ASCII, MS character first

    // ---- Raw block stream, consumed by axi_sdr_fm.v ----
    output reg                           rds_raw_block_valid,
    output reg  [15:0]                   rds_raw_block_data,
    output reg  [2:0]                    rds_raw_block_id,   // 0=A,1=B,2=C,3=D,4=C'
    output reg                           rds_raw_block_good
);

    // =========================================================================
    // Quadrant-symmetric sin/cos LUT (local copy of the fm_stereo_demod one)
    // =========================================================================
    function signed [11:0] cos_q_lut;
        input [5:0] addr;
        begin
            case (addr)
                 0: cos_q_lut = 12'sd25;    1: cos_q_lut = 12'sd75;    2: cos_q_lut = 12'sd126;
                 3: cos_q_lut = 12'sd176;   4: cos_q_lut = 12'sd226;   5: cos_q_lut = 12'sd275;
                 6: cos_q_lut = 12'sd325;   7: cos_q_lut = 12'sd375;   8: cos_q_lut = 12'sd424;
                 9: cos_q_lut = 12'sd473;  10: cos_q_lut = 12'sd522;  11: cos_q_lut = 12'sd570;
                12: cos_q_lut = 12'sd618;  13: cos_q_lut = 12'sd666;  14: cos_q_lut = 12'sd713;
                15: cos_q_lut = 12'sd760;  16: cos_q_lut = 12'sd807;  17: cos_q_lut = 12'sd852;
                18: cos_q_lut = 12'sd898;  19: cos_q_lut = 12'sd943;  20: cos_q_lut = 12'sd987;
                21: cos_q_lut = 12'sd1031; 22: cos_q_lut = 12'sd1074; 23: cos_q_lut = 12'sd1116;
                24: cos_q_lut = 12'sd1158; 25: cos_q_lut = 12'sd1199; 26: cos_q_lut = 12'sd1239;
                27: cos_q_lut = 12'sd1279; 28: cos_q_lut = 12'sd1318; 29: cos_q_lut = 12'sd1356;
                30: cos_q_lut = 12'sd1393; 31: cos_q_lut = 12'sd1430; 32: cos_q_lut = 12'sd1465;
                33: cos_q_lut = 12'sd1500; 34: cos_q_lut = 12'sd1533; 35: cos_q_lut = 12'sd1566;
                36: cos_q_lut = 12'sd1598; 37: cos_q_lut = 12'sd1629; 38: cos_q_lut = 12'sd1659;
                39: cos_q_lut = 12'sd1688; 40: cos_q_lut = 12'sd1716; 41: cos_q_lut = 12'sd1743;
                42: cos_q_lut = 12'sd1769; 43: cos_q_lut = 12'sd1793; 44: cos_q_lut = 12'sd1817;
                45: cos_q_lut = 12'sd1840; 46: cos_q_lut = 12'sd1861; 47: cos_q_lut = 12'sd1881;
                48: cos_q_lut = 12'sd1901; 49: cos_q_lut = 12'sd1919; 50: cos_q_lut = 12'sd1936;
                51: cos_q_lut = 12'sd1951; 52: cos_q_lut = 12'sd1966; 53: cos_q_lut = 12'sd1979;
                54: cos_q_lut = 12'sd1992; 55: cos_q_lut = 12'sd2003; 56: cos_q_lut = 12'sd2012;
                57: cos_q_lut = 12'sd2021; 58: cos_q_lut = 12'sd2028; 59: cos_q_lut = 12'sd2035;
                60: cos_q_lut = 12'sd2039; 61: cos_q_lut = 12'sd2043; 62: cos_q_lut = 12'sd2046;
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

    function signed [11:0] nco_sin;
        input [ACC_W-1:0] ph;
        begin
            nco_sin = nco_cos(ph - (1 << (ACC_W-2)));
        end
    endfunction

    // =========================================================================
    // 1. 57 kHz carrier NCO (fixed) + quadrature mixer, 250 kHz
    // =========================================================================
    reg [ACC_W-1:0] carrier_phase;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) carrier_phase <= {ACC_W{1'b0}};
        else if (mpx_valid) carrier_phase <= carrier_phase + FREQ_WORD_57K;
    end

    reg signed [11:0] c57_q, s57_q;
    reg signed [17:0] mpx_q;
    reg               vld_m0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vld_m0 <= 1'b0;
        end else begin
            vld_m0 <= mpx_valid;
            if (mpx_valid) begin
                c57_q <= nco_cos(carrier_phase);
                s57_q <= nco_sin(carrier_phase);
                mpx_q <= mpx_in;
            end
        end
    end

    reg signed [29:0] I_raw_q, Q_raw_q;
    reg                vld_m1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vld_m1 <= 1'b0;
        end else begin
            vld_m1 <= vld_m0;
            if (vld_m0) begin
                I_raw_q <= mpx_q * c57_q;
                Q_raw_q <= mpx_q * s57_q;
            end
        end
    end

    wire signed [CIC_B_IN-1:0] I_pre_raw = I_raw_q >>> 12;
    wire signed [CIC_B_IN-1:0] Q_pre_raw = Q_raw_q >>> 12;

    // -- DC blocker (1st-order HPF). The carrier NCO is uncorrected, so
    //    I_pre/Q_pre carry a slowly rotating residual; without this the CIC
    //    integrator state grows essentially without bound. DC_SHIFT=14 gives
    //    ~65 ms at 250 kHz, two orders of magnitude slower than the RDS bit
    //    period, so the signal itself is not distorted. --
    localparam DC_SHIFT = 14;
    localparam DC_ACC_W = CIC_B_IN + DC_SHIFT + 2;
    reg signed [DC_ACC_W-1:0] dc_acc_i, dc_acc_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dc_acc_i <= {DC_ACC_W{1'b0}};
            dc_acc_q <= {DC_ACC_W{1'b0}};
        end else if (vld_m1) begin
            dc_acc_i <= dc_acc_i - (dc_acc_i >>> DC_SHIFT) + I_pre_raw;
            dc_acc_q <= dc_acc_q - (dc_acc_q >>> DC_SHIFT) + Q_pre_raw;
        end
    end

    // -- Saturating (not wrapping) subtraction: on a sharp transient the
    //    difference needs one more bit than CIC_B_IN, and a wrap would inject
    //    a full-scale impulse of the wrong sign into the CIC. --
    function signed [CIC_B_IN-1:0] saturate_to_bin;
        input signed [DC_ACC_W-1:0] wide;
        begin
            if (wide[DC_ACC_W-1:CIC_B_IN-1] == {(DC_ACC_W-CIC_B_IN+1){wide[CIC_B_IN-1]}})
                saturate_to_bin = wide[CIC_B_IN-1:0];
            else
                saturate_to_bin = wide[DC_ACC_W-1] ? {1'b1,{(CIC_B_IN-1){1'b0}}}
                                                   : {1'b0,{(CIC_B_IN-1){1'b1}}};
        end
    endfunction

    wire signed [CIC_B_IN-1:0] I_pre = saturate_to_bin(I_pre_raw - (dc_acc_i >>> DC_SHIFT));
    wire signed [CIC_B_IN-1:0] Q_pre = saturate_to_bin(Q_pre_raw - (dc_acc_q >>> DC_SHIFT));

    // =========================================================================
    // 2. CIC decimation x10 (250 kHz -> 25 kHz), matched I/Q pair
    // =========================================================================
    wire signed [CIC_B_OUT-1:0] I_dec, Q_dec;
    wire                        I_dec_vld, Q_dec_vld;

    cic_decimator #(
        .B_IN(CIC_B_IN), .N_STAGES(CIC_N_STAGES), .R_DEC(CIC_R_DEC), .B_OUT(CIC_B_OUT),
        .GUARD_BITS(CIC_GUARD_BITS)
    ) u_i_cic (
        .clk(clk), .rst_n(rst_n), .data_in(I_pre), .valid_in(vld_m1),
        .data_out(I_dec), .valid_out(I_dec_vld)
    );

    cic_decimator #(
        .B_IN(CIC_B_IN), .N_STAGES(CIC_N_STAGES), .R_DEC(CIC_R_DEC), .B_OUT(CIC_B_OUT),
        .GUARD_BITS(CIC_GUARD_BITS)
    ) u_q_cic (
        .clk(clk), .rst_n(rst_n), .data_in(Q_pre), .valid_in(vld_m1),
        .data_out(Q_dec), .valid_out(Q_dec_vld)
    );
    wire dec_vld = I_dec_vld;   // matched delay, mirrors Q_dec_vld

    // =========================================================================
    // 3. Costas loop on the decimated I/Q (25 kHz)
    // =========================================================================
    reg [ACC_W-1:0] costas_phase;

    reg signed [11:0] c2_q, s2_q;
    reg signed [CIC_B_OUT-1:0] I_dec_q, Q_dec_q;
    reg                        vld_c0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vld_c0 <= 1'b0;
        end else begin
            vld_c0 <= dec_vld;
            if (dec_vld) begin
                c2_q <= nco_cos(costas_phase);
                s2_q <= nco_sin(costas_phase);
                I_dec_q <= I_dec;
                Q_dec_q <= Q_dec;
            end
        end
    end

    // -- de-rotation, pipelined: multiplies (DSP) and the wide add (CARRY4)
    //    in separate cycles --
    localparam PROD_W  = CIC_B_OUT + 12;
    localparam DEROT_W = CIC_B_OUT + 12 + 2;

    reg signed [PROD_W-1:0] p_Ic, p_Qs, p_Is, p_Qc;
    reg                     vld_c0b;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vld_c0b <= 1'b0;
        end else begin
            vld_c0b <= vld_c0;
            if (vld_c0) begin
                p_Ic <= I_dec_q * c2_q;
                p_Qs <= Q_dec_q * s2_q;
                p_Is <= I_dec_q * s2_q;
                p_Qc <= Q_dec_q * c2_q;
            end
        end
    end

    reg signed [DEROT_W-1:0] Ii_sum, Qi_sum;
    reg                      vld_c1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vld_c1 <= 1'b0;
        end else begin
            vld_c1 <= vld_c0b;
            if (vld_c0b) begin
                Ii_sum <=  p_Ic + p_Qs;
                Qi_sum <= -p_Is + p_Qc;
            end
        end
    end

    localparam IQ_LOCK_W = DEROT_W - 11;
    wire signed [IQ_LOCK_W-1:0] Ii = Ii_sum >>> 11;
    wire signed [IQ_LOCK_W-1:0] Qi = Qi_sum >>> 11;
    reg signed [IQ_LOCK_W-1:0] Ii_q, Qi_q;
    reg                        vld_c2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vld_c2 <= 1'b0;
        end else begin
            vld_c2 <= vld_c1;
            if (vld_c1) begin Ii_q <= Ii; Qi_q <= Qi; end
        end
    end

    // -------------------------------------------------------------------------
    // FIX-1: AGC. A leaky-averaged |Ii|+|Qi| estimate drives a barrel-shift
    // so the discriminator operands always sit near 2^AGC_TARGET_LOG2,
    // regardless of RSSI or RDS injection depth. Without this the loop gain
    // scales with the SQUARE of the signal amplitude and the design point is
    // only met at one particular field strength.
    //
    // The same magnitude estimate also supplies the slicer hysteresis
    // threshold used by the bit synchronizer (FIX-4).
    // -------------------------------------------------------------------------
    wire [IQ_LOCK_W-1:0] abs_Ii = Ii_q[IQ_LOCK_W-1] ? (~Ii_q + 1'b1) : Ii_q;
    wire [IQ_LOCK_W-1:0] abs_Qi = Qi_q[IQ_LOCK_W-1] ? (~Qi_q + 1'b1) : Qi_q;
    wire [IQ_LOCK_W:0]   mag_inst = {1'b0, abs_Ii} + {1'b0, abs_Qi};

    localparam MAG_ACC_W = IQ_LOCK_W + 1 + AGC_LP_SHIFT;
    reg  [MAG_ACC_W-1:0] mag_acc;
    wire [IQ_LOCK_W:0]   mag_avg = mag_acc >> AGC_LP_SHIFT;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) mag_acc <= {MAG_ACC_W{1'b0}};
        else if (vld_c2) mag_acc <= mag_acc - (mag_acc >> AGC_LP_SHIFT) + {{AGC_LP_SHIFT{1'b0}}, mag_inst};
    end

    // priority encoder: position of the highest set bit of mag_avg
    integer mi;
    reg [5:0] mag_msb;
    always @(*) begin
        mag_msb = 6'd0;
        for (mi = 0; mi <= IQ_LOCK_W; mi = mi + 1)
            if (mag_avg[mi]) mag_msb = mi[5:0];
    end

    reg [5:0] agc_shift;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) agc_shift <= COSTAS_PRESHIFT[5:0];
        else if (vld_c2) begin
            if (!COSTAS_AGC_ENABLE)              agc_shift <= COSTAS_PRESHIFT[5:0];
            else if (mag_msb > AGC_TARGET_LOG2)  agc_shift <= mag_msb - AGC_TARGET_LOG2;
            else                                 agc_shift <= 6'd0;   // weak signal: no attenuation
        end
    end

    // slicer hysteresis threshold (FIX-4), derived from the same estimate
    wire [IQ_LOCK_W:0] slice_hyst = (BIT_HYST_SHIFT == 0) ? {(IQ_LOCK_W+1){1'b0}}
                                                          : (mag_avg >> BIT_HYST_SHIFT);

    // -- discriminator operand clamp (saturating, not truncating) --
    function signed [COSTAS_CLAMP_W-1:0] sat_iq_clamp;
        input signed [IQ_LOCK_W-1:0] v;
        begin
            if (v[IQ_LOCK_W-1:COSTAS_CLAMP_W-1] == {(IQ_LOCK_W-COSTAS_CLAMP_W+1){v[COSTAS_CLAMP_W-1]}})
                sat_iq_clamp = v[COSTAS_CLAMP_W-1:0];
            else
                sat_iq_clamp = v[IQ_LOCK_W-1] ? {1'b1,{(COSTAS_CLAMP_W-1){1'b0}}}
                                              : {1'b0,{(COSTAS_CLAMP_W-1){1'b1}}};
        end
    endfunction

    wire signed [IQ_LOCK_W-1:0] Ii_ps = Ii_q >>> agc_shift;
    wire signed [IQ_LOCK_W-1:0] Qi_ps = Qi_q >>> agc_shift;
    reg  signed [COSTAS_CLAMP_W-1:0] Ii_c, Qi_c;
    reg                              vld_c2a;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vld_c2a <= 1'b0;
        end else begin
            vld_c2a <= vld_c2;
            if (vld_c2) begin
                Ii_c <= sat_iq_clamp(Ii_ps);
                Qi_c <= sat_iq_clamp(Qi_ps);
            end
        end
    end

    // -- err = Ii*Qi (BPSK/Costas discriminator), 18x18 = one DSP48E1 --
    localparam ERR_W = 2*COSTAS_CLAMP_W;
    reg signed [ERR_W-1:0] err_costas_q;
    reg                    vld_c3;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vld_c3 <= 1'b0;
        end else begin
            vld_c3 <= vld_c2a;
            if (vld_c2a) err_costas_q <= Ii_c * Qi_c;
        end
    end

    // -- leaky integrator with saturation and conditional integration --
    // FW_CLAMP_LOG2 is now a parameter (see the port list above)
    localparam FREQACC_W = KI_SHIFT_COSTAS + FW_CLAMP_LOG2 + 2;
    localparam signed [FREQACC_W:0] ACC_LIM_POS =
        {{2{1'b0}}, 1'b1, {(KI_SHIFT_COSTAS+FW_CLAMP_LOG2){1'b0}}};
    localparam signed [FREQACC_W:0] ACC_LIM_NEG = -ACC_LIM_POS;

    localparam FWSUM_W = 20;
    localparam signed [FWSUM_W-1:0] FW_LIM_POS =
        {{(FWSUM_W-FW_CLAMP_LOG2-1){1'b0}}, 1'b1, {FW_CLAMP_LOG2{1'b0}}};
    localparam signed [FWSUM_W-1:0] FW_LIM_NEG = -FW_LIM_POS;

    reg signed [FWSUM_W-1:0] fw_costas_q;
    reg                      vld_c4;

    wire fw_at_pos_lim = (fw_costas_q == FW_LIM_POS);
    wire fw_at_neg_lim = (fw_costas_q == FW_LIM_NEG);
    wire err_is_neg    = err_costas_q[ERR_W-1];
    wire acc_int_en    = ~((fw_at_pos_lim & ~err_is_neg) | (fw_at_neg_lim & err_is_neg));

    reg  signed [FREQACC_W-1:0] freq_acc_costas;
    wire signed [FREQACC_W:0]   acc_sum = freq_acc_costas + err_costas_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) freq_acc_costas <= {FREQACC_W{1'b0}};
        else if (vld_c3 && acc_int_en) begin
            if      (acc_sum > ACC_LIM_POS) freq_acc_costas <= ACC_LIM_POS[FREQACC_W-1:0];
            else if (acc_sum < ACC_LIM_NEG) freq_acc_costas <= ACC_LIM_NEG[FREQACC_W-1:0];
            else                            freq_acc_costas <= acc_sum[FREQACC_W-1:0];
        end
    end

    wire signed [FWSUM_W-1:0] fw_full = (freq_acc_costas >>> KI_SHIFT_COSTAS)
                                      + (err_costas_q   >>> KP_SHIFT_COSTAS);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin fw_costas_q <= {FWSUM_W{1'b0}}; vld_c4 <= 1'b0; end
        else begin
            vld_c4 <= vld_c3;
            if (vld_c3) begin
                if      (fw_full > FW_LIM_POS) fw_costas_q <= FW_LIM_POS;
                else if (fw_full < FW_LIM_NEG) fw_costas_q <= FW_LIM_NEG;
                else                           fw_costas_q <= fw_full;
            end
        end
    end

    // sign-extend FWSUM_W -> ACC_W (keep FWSUM_W < ACC_W if either changes)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) costas_phase <= {ACC_W{1'b0}};
        else if (vld_c4) costas_phase <= costas_phase
                                       + {{(ACC_W-FWSUM_W){fw_costas_q[FWSUM_W-1]}}, fw_costas_q};
    end

    // =========================================================================
    // rds_en synchronization + 0->1 edge detector
    // =========================================================================
    (* ASYNC_REG = "TRUE" *) reg rds_en_sync1;
    (* ASYNC_REG = "TRUE" *) reg rds_en_sync2;
    reg rds_en_sync2_d;
    wire rds_en_rising = rds_en_sync2 & ~rds_en_sync2_d;

    reg force_resync;
    reg [21:0] resync_timeout_cnt;   // driven at the end of the file (needs
                                      // bitsync_state and block_synced)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rds_en_sync1 <= 1'b0; rds_en_sync2 <= 1'b0; rds_en_sync2_d <= 1'b0;
        end else begin
            rds_en_sync1 <= rds_en;
            rds_en_sync2 <= rds_en_sync1;
            rds_en_sync2_d <= rds_en_sync2;
        end
    end

    // =========================================================================
    // 4. Bit synchronization: parallel coarse phase search + proportional
    //    tracking loop, on the decimated strobe vld_c2 and the Costas-loop
    //    in-phase channel Ii_q.
    // =========================================================================
    localparam S_COARSE = 1'b0;
    localparam S_TRACK  = 1'b1;

    localparam HALFACC_W = IQ_LOCK_W + 6;
    localparam integer SCAN_DURATION_SAMPLES = (N_BITS_PROBE * (1 << BIT_ACC_W)) / BIT_FREQ_WORD;
    localparam SCAN_CNT_W = $clog2(SCAN_DURATION_SAMPLES + 2);
    // FIX-3: soft metric accumulator. Worst case ~2 transitions/bit x
    // N_BITS_PROBE bits x BIT_WIN, so BIT_ACC_W + log2(2*N_BITS_PROBE) bits.
    localparam METRIC_W = BIT_ACC_W + $clog2(2*N_BITS_PROBE) + 1;

    reg                     bitsync_state;
    reg  [BIT_ACC_W-1:0]    bit_phase;
    reg  [SCAN_CNT_W-1:0]   scan_cnt;
    reg  signed [HALFACC_W-1:0] half_a, half_b;
    reg  [BIT_ACC_W-1:0]    best_phase;
    reg                     prev_sign;
    reg                     g_bit_valid;
    reg                     g_bit_q;
    reg                     costas_settled;
    reg  [16:0]             settle_cnt;
    reg                     resync_dither;      // FIX-6

    reg  [BIT_ACC_W-1:0]        par_bit_phase [0:N_COARSE_CANDIDATES-1];
    reg                         par_prev_sign [0:N_COARSE_CANDIDATES-1];
    reg  [METRIC_W-1:0]         par_metric    [0:N_COARSE_CANDIDATES-1];

    // FIX-4: sliced data sign with hysteresis. Only a genuine excursion past
    // +-slice_hyst changes the sign; inside the band the previous sign is
    // held, so noise crossings near zero no longer look like bit transitions.
    reg  slice_sign_r;
    wire slice_sign = ( $signed(Ii_q) >  $signed({1'b0, slice_hyst}) ) ? 1'b0 :
                      ( $signed(Ii_q) < -$signed({1'b0, slice_hyst}) ) ? 1'b1 :
                                                                        slice_sign_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) slice_sign_r <= 1'b0;
        else if (vld_c2) slice_sign_r <= slice_sign;
    end

    // -- scratch (blocking) --
    reg  signed [HALFACC_W-1:0] half_a_nxt, half_b_nxt;
    reg  signed [HALFACC_W:0]   diff_nxt;
    reg  [BIT_ACC_W-1:0]        bit_phase_nxt;
    reg                         cur_sign_nxt;
    reg  signed [BIT_ACC_W:0]   err_t_nxt;
    reg  [BIT_ACC_W-1:0]        err_t_abs_nxt;
    reg  signed [BIT_ACC_W:0]   err_kp_nxt;       // FIX-7: see stage B1
    reg                         apply_corr_nxt;
    // -- TRACK pipeline A -> B1 -> B2 -> B3 --
    reg  signed [HALFACC_W:0]   diff_a;
    reg  signed [HALFACC_W-1:0] half_a_stage, half_b_stage;
    reg  [BIT_ACC_W-1:0]        bit_phase_a;
    reg  signed [BIT_ACC_W:0]   err_t_a;
    reg                         apply_corr_a;
    reg                         vld_trk_b;
    reg  [BIT_ACC_W-1:0]        corr_bit_phase_b1;
    reg  signed [HALFACC_W:0]   diff_b1;
    reg  signed [HALFACC_W-1:0] half_a_b1, half_b_b1;
    reg                         vld_trk_b2;
    reg  [BIT_ACC_W-1:0]        bit_phase_nxt_b2;
    reg                         wrap_b2;
    reg  signed [HALFACC_W:0]   diff_b2;
    reg  signed [HALFACC_W-1:0] half_a_b2, half_b_b2;
    reg                         vld_trk_b3;
    integer                     ci;
    reg                         par_cur_sign;
    reg  signed [BIT_ACC_W:0]   par_err_t;
    reg  [BIT_ACC_W-1:0]        par_err_t_abs;
    reg                         coarse_pick_pending;
    reg  [BIT_ACC_W-1:0]        best_bitphase_scan_r;
    // 3-round binary tournament (log2(8)) instead of an 8-way chain
    reg  [METRIC_W-1:0]         r1_count [0:3];
    reg  [BIT_ACC_W-1:0]        r1_phase [0:3];
    reg                         vld_r1;
    reg  [METRIC_W-1:0]         r2_count [0:1];
    reg  [BIT_ACC_W-1:0]        r2_phase [0:1];
    reg                         vld_r2;
    integer                     ti;

    localparam [BIT_ACC_W-1:0] BIT_HALF  = {1'b1, {(BIT_ACC_W-1){1'b0}}};   // 0.5
    localparam [BIT_ACC_W-1:0] BIT_BIAS  = BIT_FREQ_WORD >> 1;              // detector delay correction
    localparam [BIT_ACC_W-1:0] CAND_STEP = (1 << (BIT_ACC_W-3));            // 1/8 bit
    localparam [BIT_ACC_W-1:0] CAND_DITH = (1 << (BIT_ACC_W-4));            // 1/16 bit (FIX-6)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bitsync_state <= S_COARSE;
            bit_phase <= {BIT_ACC_W{1'b0}};
            scan_cnt <= {SCAN_CNT_W{1'b0}};
            half_a <= {HALFACC_W{1'b0}};
            half_b <= {HALFACC_W{1'b0}};
            best_phase <= {BIT_ACC_W{1'b0}};
            prev_sign <= 1'b0;
            g_bit_valid <= 1'b0;
            g_bit_q <= 1'b0;
            costas_settled <= 1'b0;
            settle_cnt <= 17'd0;
            resync_dither <= 1'b0;
            vld_trk_b <= 1'b0;
            vld_trk_b2 <= 1'b0;
            vld_trk_b3 <= 1'b0;
            wrap_b2 <= 1'b0;
            apply_corr_a <= 1'b0;
            vld_r1 <= 1'b0;
            vld_r2 <= 1'b0;
            coarse_pick_pending <= 1'b0;
            for (ci = 0; ci < N_COARSE_CANDIDATES; ci = ci + 1) begin
                par_bit_phase[ci] <= ci * CAND_STEP;
                par_prev_sign[ci] <= 1'b0;
                par_metric[ci]    <= {METRIC_W{1'b0}};
            end
        end else begin
            g_bit_valid <= 1'b0;

            if (rds_en_rising || force_resync) begin
                // (Re)start acquisition from scratch. FIX-6: on a forced
                // resync the candidate grid is offset by half a step, so the
                // retry does not test exactly the phases that just failed.
                bitsync_state <= S_COARSE;
                scan_cnt <= {SCAN_CNT_W{1'b0}};
                costas_settled <= 1'b0;
                settle_cnt <= 17'd0;
                vld_trk_b <= 1'b0;
                vld_trk_b2 <= 1'b0;
                vld_trk_b3 <= 1'b0;
                vld_r1 <= 1'b0;
                vld_r2 <= 1'b0;
                coarse_pick_pending <= 1'b0;
                if (force_resync) resync_dither <= ~resync_dither;
                for (ci = 0; ci < N_COARSE_CANDIDATES; ci = ci + 1) begin
                    par_bit_phase[ci] <= ci * CAND_STEP
                                       + ((force_resync && !resync_dither) ? CAND_DITH : {BIT_ACC_W{1'b0}});
                    par_prev_sign[ci] <= 1'b0;
                    par_metric[ci]    <= {METRIC_W{1'b0}};
                end
            end else if (coarse_pick_pending) begin
                coarse_pick_pending <= 1'b0;
                best_phase    <= best_bitphase_scan_r;
                bit_phase     <= best_bitphase_scan_r;
                bitsync_state <= S_TRACK;
                half_a <= {HALFACC_W{1'b0}};
                half_b <= {HALFACC_W{1'b0}};
            end else if (vld_c2 && !costas_settled) begin
                // settling delay for the Costas loop AND the AGC before the
                // coarse search starts, so all candidates see the same
                // (converged) signal conditions
                if (settle_cnt == COSTAS_SETTLE_SAMPLES-1) costas_settled <= 1'b1;
                else                                       settle_cnt <= settle_cnt + 17'd1;
            end else if (vld_c2 && bitsync_state == S_COARSE) begin
                // -- parallel coarse search: all candidates process the same
                //    sample; FIX-3 accumulates a soft score (BIT_WIN - |err|)
                //    instead of counting hits, so the closest phase wins
                //    outright rather than tying with its neighbours. --
                par_cur_sign = slice_sign;
                for (ci = 0; ci < N_COARSE_CANDIDATES; ci = ci + 1) begin
                    if (par_cur_sign != par_prev_sign[ci]) begin
                        par_err_t     = $signed({1'b0,par_bit_phase[ci]}) - $signed({1'b0,BIT_HALF});
                        par_err_t_abs = par_err_t[BIT_ACC_W] ? (~par_err_t[BIT_ACC_W-1:0]+1'b1)
                                                             : par_err_t[BIT_ACC_W-1:0];
                        if (par_err_t_abs < BIT_WIN)
                            par_metric[ci] <= par_metric[ci] +
                                              {{(METRIC_W-BIT_ACC_W){1'b0}}, (BIT_WIN - par_err_t_abs)};
                    end
                    par_prev_sign[ci] <= par_cur_sign;
                    par_bit_phase[ci] <= par_bit_phase[ci] + BIT_FREQ_WORD;
                end

                if (scan_cnt == SCAN_DURATION_SAMPLES-1) begin
                    for (ti = 0; ti < 4; ti = ti + 1) begin
                        if (par_metric[2*ti] >= par_metric[2*ti+1]) begin
                            r1_count[ti] <= par_metric[2*ti];
                            r1_phase[ti] <= par_bit_phase[2*ti];
                        end else begin
                            r1_count[ti] <= par_metric[2*ti+1];
                            r1_phase[ti] <= par_bit_phase[2*ti+1];
                        end
                    end
                    vld_r1 <= 1'b1;
                end else begin
                    scan_cnt <= scan_cnt + 1'b1;
                end
            end else if (vld_c2) begin
                // -- TRACK stage A: fold this sample into half_a/half_b and
                //    compute the timing error; applied by B1..B3 below. --
                half_a_nxt = half_a;
                half_b_nxt = half_b;
                if (bit_phase < BIT_HALF) half_a_nxt = half_a + Ii_q;
                else                      half_b_nxt = half_b + Ii_q;
                diff_nxt = $signed({half_a_nxt[HALFACC_W-1],half_a_nxt})
                         - $signed({half_b_nxt[HALFACC_W-1],half_b_nxt});

                cur_sign_nxt = slice_sign;                 // FIX-4
                if (cur_sign_nxt != prev_sign) begin
                    err_t_nxt      = $signed({1'b0,bit_phase}) - $signed({1'b0,BIT_HALF})
                                                               - $signed({1'b0,BIT_BIAS});
                    apply_corr_nxt = 1'b1;
                end else begin
                    err_t_nxt      = {(BIT_ACC_W+1){1'b0}};
                    apply_corr_nxt = 1'b0;
                end
                prev_sign <= cur_sign_nxt;

                diff_a       <= diff_nxt;
                half_a_stage <= half_a_nxt;
                half_b_stage <= half_b_nxt;
                bit_phase_a  <= bit_phase;
                err_t_a      <= err_t_nxt;
                apply_corr_a <= apply_corr_nxt;
                vld_trk_b    <= 1'b1;
            end else begin
                vld_trk_b <= 1'b0;
            end

            // -- tournament round 2 --
            if (vld_r1) begin
                for (ti = 0; ti < 2; ti = ti + 1) begin
                    if (r1_count[2*ti] >= r1_count[2*ti+1]) begin
                        r2_count[ti] <= r1_count[2*ti];
                        r2_phase[ti] <= r1_phase[2*ti];
                    end else begin
                        r2_count[ti] <= r1_count[2*ti+1];
                        r2_phase[ti] <= r1_phase[2*ti+1];
                    end
                end
                vld_r2 <= 1'b1;
                vld_r1 <= 1'b0;
            end

            // -- tournament round 3 (final) --
            if (vld_r2) begin
                if (r2_count[0] >= r2_count[1]) best_bitphase_scan_r <= r2_phase[0];
                else                            best_bitphase_scan_r <= r2_phase[1];
                coarse_pick_pending <= 1'b1;
                vld_r2 <= 1'b0;
            end

            // -- TRACK stage B1: |err| + window compare + correction.
            //    With BIT_WIN <= 0.25 the correction can only be applied
            //    while bit_phase is well away from the wraparound, which
            //    also removes the bit-slip path that a correction crossing
            //    phase 0 would otherwise create in B2's wrap detection. --
            if (vld_trk_b && !coarse_pick_pending) begin
                err_t_abs_nxt = err_t_a[BIT_ACC_W] ? (~err_t_a[BIT_ACC_W-1:0]+1'b1)
                                                   : err_t_a[BIT_ACC_W-1:0];
                // FIX-7: the shift MUST be evaluated in a signed context of
                // its own. Written inline as
                //     bit_phase_a - (err_t_a >>> BIT_KP_SHIFT)
                // the unsigned bit_phase_a makes the whole expression
                // unsigned, so err_t_a is converted to unsigned first and
                // >>> degenerates into a LOGICAL shift: a negative timing
                // error of -0.05 bit produced a correction of -0.4875 bit
                // instead of +0.0125 bit. At BIT_KP_SHIFT=1 the spurious
                // -2^BIT_ACC_W term cancels exactly in the 20-bit
                // truncation, which is why the original code appeared to
                // work at that one gain setting and collapsed at every
                // other one.
                err_kp_nxt = err_t_a >>> BIT_KP_SHIFT;   // signed context: arithmetic
                if (apply_corr_a && (err_t_abs_nxt < BIT_WIN))
                    corr_bit_phase_b1 <= bit_phase_a - err_kp_nxt[BIT_ACC_W-1:0];
                else
                    corr_bit_phase_b1 <= bit_phase_a;
                diff_b1   <= diff_a;
                half_a_b1 <= half_a_stage;
                half_b_b1 <= half_b_stage;
                vld_trk_b2 <= 1'b1;
            end else begin
                vld_trk_b2 <= 1'b0;
            end

            // -- TRACK stage B2: advance the phase and detect the wrap --
            if (vld_trk_b2) begin
                bit_phase_nxt    = corr_bit_phase_b1 + BIT_FREQ_WORD;
                bit_phase_nxt_b2 <= bit_phase_nxt;
                wrap_b2          <= (bit_phase_nxt < corr_bit_phase_b1);
                diff_b2   <= diff_b1;
                half_a_b2 <= half_a_b1;
                half_b_b2 <= half_b_b1;
                vld_trk_b3 <= 1'b1;
            end else begin
                vld_trk_b3 <= 1'b0;
            end

            // -- TRACK stage B3: apply, and emit a channel bit on the wrap --
            if (vld_trk_b3) begin
                bit_phase <= bit_phase_nxt_b2;
                if (wrap_b2) begin
                    g_bit_q     <= ~diff_b2[HALFACC_W];   // half_a >= half_b -> 1
                    g_bit_valid <= 1'b1;
                    half_a <= {HALFACC_W{1'b0}};
                    half_b <= {HALFACC_W{1'b0}};
                end else begin
                    half_a <= half_a_b2;
                    half_b <= half_b_b2;
                end
            end
        end
    end

    // =========================================================================
    // 5. Differential decoding: b[k] = g[k]^g[k-1] -- removes the Costas
    //    loop's 180-degree ambiguity.
    // =========================================================================
    reg g_prev;
    reg b_bit, b_bit_valid;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            g_prev <= 1'b0; b_bit <= 1'b0; b_bit_valid <= 1'b0;
        end else begin
            b_bit_valid <= 1'b0;
            if (rds_en_rising || force_resync) begin
                g_prev <= 1'b0;
            end else if (g_bit_valid) begin
                b_bit       <= g_bit_q ^ g_prev;
                b_bit_valid <= 1'b1;
                g_prev      <= g_bit_q;
            end
        end
    end

    // =========================================================================
    // 6. Block/group synchronization (IEC 62106 Annex C).
    //    bit_history[0] is the newest bit, [25] the oldest, so a complete
    //    block reads out as data = [25:10], check = [9:0].
    // =========================================================================
    function [9:0] synd26_fn;
        input [25:0] x;
        begin
            synd26_fn[9] = x[1]^x[2]^x[3]^x[4]^x[5]^x[10]^x[11]^x[12]^x[13]^x[14]^x[18]^x[19]^x[24];
            synd26_fn[8] = x[0]^x[1]^x[2]^x[3]^x[4]^x[9]^x[10]^x[11]^x[12]^x[13]^x[17]^x[18]^x[23];
            synd26_fn[7] = x[0]^x[4]^x[5]^x[8]^x[9]^x[13]^x[14]^x[16]^x[17]^x[18]^x[19]^x[22]^x[24]^x[25];
            synd26_fn[6] = x[1]^x[2]^x[5]^x[7]^x[8]^x[10]^x[11]^x[14]^x[15]^x[16]^x[17]^x[19]^x[21]^x[23]^x[25];
            synd26_fn[5] = x[0]^x[1]^x[4]^x[6]^x[7]^x[9]^x[10]^x[13]^x[14]^x[15]^x[16]^x[18]^x[20]^x[22]^x[24];
            synd26_fn[4] = x[0]^x[1]^x[2]^x[4]^x[6]^x[8]^x[9]^x[10]^x[11]^x[15]^x[17]^x[18]^x[21]^x[23]^x[24]^x[25];
            synd26_fn[3] = x[0]^x[2]^x[4]^x[7]^x[8]^x[9]^x[11]^x[12]^x[13]^x[16]^x[17]^x[18]^x[19]^x[20]^x[22]^x[23]^x[25];
            synd26_fn[2] = x[2]^x[4]^x[5]^x[6]^x[7]^x[8]^x[13]^x[14]^x[15]^x[16]^x[17]^x[21]^x[22];
            synd26_fn[1] = x[1]^x[3]^x[4]^x[5]^x[6]^x[7]^x[12]^x[13]^x[14]^x[15]^x[16]^x[20]^x[21];
            synd26_fn[0] = x[0]^x[2]^x[3]^x[4]^x[5]^x[6]^x[11]^x[12]^x[13]^x[14]^x[15]^x[19]^x[20]^x[25];
        end
    endfunction

    function [9:0] crc16_fn;
        input [15:0] x;
        begin
            crc16_fn[9] = x[1]^x[2]^x[3]^x[4]^x[5]^x[10]^x[11]^x[12]^x[13]^x[14];
            crc16_fn[8] = x[0]^x[1]^x[2]^x[3]^x[4]^x[9]^x[10]^x[11]^x[12]^x[13];
            crc16_fn[7] = x[0]^x[4]^x[5]^x[8]^x[9]^x[13]^x[14];
            crc16_fn[6] = x[1]^x[2]^x[5]^x[7]^x[8]^x[10]^x[11]^x[14]^x[15];
            crc16_fn[5] = x[0]^x[1]^x[4]^x[6]^x[7]^x[9]^x[10]^x[13]^x[14]^x[15];
            crc16_fn[4] = x[0]^x[1]^x[2]^x[4]^x[6]^x[8]^x[9]^x[10]^x[11]^x[15];
            crc16_fn[3] = x[0]^x[2]^x[4]^x[7]^x[8]^x[9]^x[11]^x[12]^x[13];
            crc16_fn[2] = x[2]^x[4]^x[5]^x[6]^x[7]^x[8]^x[13]^x[14]^x[15];
            crc16_fn[1] = x[1]^x[3]^x[4]^x[5]^x[6]^x[7]^x[12]^x[13]^x[14]^x[15];
            crc16_fn[0] = x[0]^x[2]^x[3]^x[4]^x[5]^x[6]^x[11]^x[12]^x[13]^x[14]^x[15];
        end
    endfunction

    localparam [9:0] OFF_A=10'd252, OFF_B=10'd408, OFF_C=10'd360, OFF_D=10'd436, OFF_CP=10'd848;
    localparam [9:0] ES_A=10'd383,  ES_B=10'd14,   ES_C=10'd303,  ES_D=10'd663,  ES_CP=10'd748;

    reg  [25:0] bit_history;
    reg         block_synced;
    reg         presync_active;
    reg  [2:0]  presync_offset_idx;
    reg  [15:0] bits_since_presync;

    reg  [1:0]  block_number;
    reg  [4:0]  block_bit_counter;
    reg  [5:0]  blocks_counter;
    reg  [5:0]  wrong_blocks_counter;

    reg         group_assembly_started;
    reg  [2:0]  group_good_blocks_counter;
    reg  [15:0] group_A, group_B, group_C, group_D;
    reg         group_ready;

    function [2:0] match_idx_of;
        input [9:0] s;
        begin
            match_idx_of = 3'b111;
            if      (s == ES_A)  match_idx_of = 3'd0;
            else if (s == ES_B)  match_idx_of = 3'd1;
            else if (s == ES_C)  match_idx_of = 3'd2;
            else if (s == ES_D)  match_idx_of = 3'd3;
            else if (s == ES_CP) match_idx_of = 3'd4;
        end
    endfunction

    function [2:0] offset_pos_of;
        input [2:0] j;
        begin
            case (j)
                3'd0: offset_pos_of = 3'd0;
                3'd1: offset_pos_of = 3'd1;
                3'd2: offset_pos_of = 3'd2;
                3'd3: offset_pos_of = 3'd3;
                3'd4: offset_pos_of = 3'd2;   // C' shares position 2 with C
                default: offset_pos_of = 3'd0;
            endcase
        end
    endfunction

    reg  [25:0] bit_history_nxt;
    reg  [2:0]  match_idx_nxt;
    reg  [2:0]  block_distance_nxt;
    reg  [15:0] dataword_nxt;
    reg  [9:0]  checkword_nxt;
    reg  [9:0]  crc16_nxt;
    reg         good_block_nxt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_history <= 26'd0;
            block_synced <= 1'b0;
            presync_active <= 1'b0;
            presync_offset_idx <= 3'd0;
            bits_since_presync <= 16'd0;
            block_number <= 2'd0;
            block_bit_counter <= 5'd0;
            blocks_counter <= 6'd0;
            wrong_blocks_counter <= 6'd0;
            group_assembly_started <= 1'b0;
            group_good_blocks_counter <= 3'd0;
            group_ready <= 1'b0;
            rds_raw_block_valid <= 1'b0;
        end else begin
            group_ready <= 1'b0;
            rds_raw_block_valid <= 1'b0;

            if (rds_en_rising || force_resync) begin
                block_synced <= 1'b0;
                presync_active <= 1'b0;
                bits_since_presync <= 16'd0;
                group_assembly_started <= 1'b0;
            end else if (b_bit_valid) begin
                bit_history_nxt = {bit_history[24:0], b_bit};
                bit_history <= bit_history_nxt;

                if (!block_synced) begin
                    // sliding, one-bit-at-a-time syndrome search
                    match_idx_nxt = match_idx_of(synd26_fn(bit_history_nxt));
                    if (presync_active) bits_since_presync <= bits_since_presync + 16'd1;

                    if (match_idx_nxt != 3'b111) begin
                        if (!presync_active) begin
                            presync_active     <= 1'b1;
                            presync_offset_idx <= match_idx_nxt;
                            bits_since_presync <= 16'd0;
                        end else begin
                            if (offset_pos_of(presync_offset_idx) >= offset_pos_of(match_idx_nxt))
                                block_distance_nxt = offset_pos_of(match_idx_nxt) + 3'd4 - offset_pos_of(presync_offset_idx);
                            else
                                block_distance_nxt = offset_pos_of(match_idx_nxt) - offset_pos_of(presync_offset_idx);

                            // (bits_since_presync + 1): the counter update above
                            // is non-blocking, so at a genuine second match it
                            // still holds its pre-increment value.
                            if ({13'd0,block_distance_nxt}*16'd26 != (bits_since_presync + 16'd1)) begin
                                presync_active     <= 1'b1;
                                presync_offset_idx <= match_idx_nxt;
                                bits_since_presync <= 16'd0;
                            end else begin
                                block_synced   <= 1'b1;
                                presync_active <= 1'b0;
                                wrong_blocks_counter <= 6'd0;
                                blocks_counter <= 6'd0;
                                block_bit_counter <= 5'd0;
                                block_number <= (offset_pos_of(match_idx_nxt) + 2'd1);
                                group_assembly_started <= 1'b0;
                            end
                        end
                    end
                end else begin
                    if (block_bit_counter != 5'd25) begin
                        block_bit_counter <= block_bit_counter + 5'd1;
                    end else begin
                        dataword_nxt  = bit_history_nxt[25:10];
                        checkword_nxt = bit_history_nxt[9:0];
                        crc16_nxt     = crc16_fn(dataword_nxt);
                        if (block_number == 2'd2)
                            good_block_nxt = ((checkword_nxt ^ OFF_C) == crc16_nxt) || ((checkword_nxt ^ OFF_CP) == crc16_nxt);
                        else if (block_number == 2'd0)
                            good_block_nxt = (checkword_nxt ^ OFF_A) == crc16_nxt;
                        else if (block_number == 2'd1)
                            good_block_nxt = (checkword_nxt ^ OFF_B) == crc16_nxt;
                        else
                            good_block_nxt = (checkword_nxt ^ OFF_D) == crc16_nxt;

                        if (!good_block_nxt) wrong_blocks_counter <= wrong_blocks_counter + 6'd1;

                        rds_raw_block_valid <= 1'b1;
                        rds_raw_block_data  <= dataword_nxt;
                        rds_raw_block_good  <= good_block_nxt;
                        if (block_number == 2'd2 && ((checkword_nxt ^ OFF_CP) == crc16_nxt))
                            rds_raw_block_id <= 3'd4;               // C'
                        else
                            rds_raw_block_id <= {1'b0, block_number};

                        // -- group assembly --
                        if (block_number == 2'd0 && good_block_nxt) begin
                            group_assembly_started    <= 1'b1;
                            group_good_blocks_counter <= 3'd1;
                            group_A <= dataword_nxt;
                        end else if (group_assembly_started) begin
                            if (!good_block_nxt) begin
                                group_assembly_started <= 1'b0;
                            end else begin
                                case (block_number)
                                    2'd1: group_B <= dataword_nxt;
                                    2'd2: group_C <= dataword_nxt;
                                    2'd3: group_D <= dataword_nxt;
                                    default: ;
                                endcase
                                group_good_blocks_counter <= group_good_blocks_counter + 3'd1;
                                if (group_good_blocks_counter == 3'd3 && block_number == 2'd3)
                                    group_ready <= 1'b1;
                            end
                        end

                        block_bit_counter <= 5'd0;
                        block_number <= block_number + 2'd1;
                        blocks_counter <= blocks_counter + 6'd1;
                        if (blocks_counter == 6'd49) begin
                            blocks_counter <= 6'd0;
                            // FIX-5: a wrong bit-clock lock produces roughly
                            // 60% bad blocks, which the old 35/50 gate let
                            // through indefinitely (and, because block_synced
                            // stayed 1, the resync timer never ran).
                            if (wrong_blocks_counter > QUALITY_BAD_THRESH) begin
                                block_synced <= 1'b0;
                                presync_active <= 1'b0;
                                bits_since_presync <= 16'd0;
                                group_assembly_started <= 1'b0;
                            end
                            wrong_blocks_counter <= 6'd0;
                        end
                    end
                end
            end
        end
    end

    // =========================================================================
    // 7. Group parsing. Group 0 (either version) supplies PS; group 2A
    //    supplies RadioText. 0B/2B variants and AF/CT/TMC/EON/ODA are out of
    //    scope. Both sections assume RDS_PS_CHARS=8 / RDS_RT_CHARS=64.
    // =========================================================================
    wire [3:0] grp_type    = group_B[15:12];
    wire       grp_version = group_B[11];
    wire [1:0] ps_seg_addr = group_B[1:0];
    wire [3:0] rt_seg_addr = group_B[3:0];
    wire       rt_ab_field = group_B[4];

    reg rt_ab_prev;
    reg rt_ab_prev_valid;

    // rds_ps/rds_rt use their flip-flop INIT value rather than an explicit
    // reset, keeping 576 bits off the reset net. On a runtime reset the last
    // text is retained rather than blanked, matching the rds_en 0->1 behaviour.
    initial begin
        rds_ps = {(8*RDS_PS_CHARS){1'b0}};
        rds_rt = {(8*RDS_RT_CHARS){1'b0}};
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rds_pi <= 16'd0;
            rds_pty <= 5'd0;
            rds_tp <= 1'b0;
            rds_ta <= 1'b0;
            rds_ms <= 1'b0;
            rt_ab_prev <= 1'b0;
            rt_ab_prev_valid <= 1'b0;
        end else if (rds_en_rising) begin
            rt_ab_prev_valid <= 1'b0;
        end else if (group_ready) begin
            rds_pi  <= group_A;
            rds_pty <= group_B[9:5];
            rds_tp  <= group_B[10];

            if (grp_type == 4'd0) begin
                rds_ta <= group_B[4];
                rds_ms <= group_B[3];
                case (ps_seg_addr)
                    2'd0: rds_ps[8*RDS_PS_CHARS-1  -: 16] <= group_D;
                    2'd1: rds_ps[8*RDS_PS_CHARS-17 -: 16] <= group_D;
                    2'd2: rds_ps[8*RDS_PS_CHARS-33 -: 16] <= group_D;
                    2'd3: rds_ps[8*RDS_PS_CHARS-49 -: 16] <= group_D;
                endcase
            end else if (grp_type == 4'd2 && grp_version == 1'b0) begin
                if (rt_ab_prev_valid && rt_ab_field != rt_ab_prev)
                    rds_rt <= {RDS_RT_CHARS{8'h20}};
                rt_ab_prev       <= rt_ab_field;
                rt_ab_prev_valid <= 1'b1;
                case (rt_seg_addr)
                    4'd0:  rds_rt[8*RDS_RT_CHARS-1   -: 32] <= {group_C,group_D};
                    4'd1:  rds_rt[8*RDS_RT_CHARS-33  -: 32] <= {group_C,group_D};
                    4'd2:  rds_rt[8*RDS_RT_CHARS-65  -: 32] <= {group_C,group_D};
                    4'd3:  rds_rt[8*RDS_RT_CHARS-97  -: 32] <= {group_C,group_D};
                    4'd4:  rds_rt[8*RDS_RT_CHARS-129 -: 32] <= {group_C,group_D};
                    4'd5:  rds_rt[8*RDS_RT_CHARS-161 -: 32] <= {group_C,group_D};
                    4'd6:  rds_rt[8*RDS_RT_CHARS-193 -: 32] <= {group_C,group_D};
                    4'd7:  rds_rt[8*RDS_RT_CHARS-225 -: 32] <= {group_C,group_D};
                    4'd8:  rds_rt[8*RDS_RT_CHARS-257 -: 32] <= {group_C,group_D};
                    4'd9:  rds_rt[8*RDS_RT_CHARS-289 -: 32] <= {group_C,group_D};
                    4'd10: rds_rt[8*RDS_RT_CHARS-321 -: 32] <= {group_C,group_D};
                    4'd11: rds_rt[8*RDS_RT_CHARS-353 -: 32] <= {group_C,group_D};
                    4'd12: rds_rt[8*RDS_RT_CHARS-385 -: 32] <= {group_C,group_D};
                    4'd13: rds_rt[8*RDS_RT_CHARS-417 -: 32] <= {group_C,group_D};
                    4'd14: rds_rt[8*RDS_RT_CHARS-449 -: 32] <= {group_C,group_D};
                    4'd15: rds_rt[8*RDS_RT_CHARS-481 -: 32] <= {group_C,group_D};
                endcase
            end
        end
    end

    // -- rds_sync tracks block_synced directly: the block-sync algorithm is
    //    already hysteretic (two consistent syndrome matches to enter, a
    //    quality window to leave), so no extra debounce is needed. --
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rds_sync <= 1'b0;
        else        rds_sync <= block_synced;
    end

    // -- resync timeout: acts like rds_en_rising for the bit-sync and
    //    block-sync FSMs, but leaves the Costas loop and the AGC running. --
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            resync_timeout_cnt <= 22'd0;
            force_resync <= 1'b0;
        end else begin
            force_resync <= 1'b0;
            if (rds_en_rising) begin
                resync_timeout_cnt <= 22'd0;
            end else if (block_synced) begin
                resync_timeout_cnt <= 22'd0;
            end else if (vld_c2 && bitsync_state == S_TRACK) begin
                if (resync_timeout_cnt == RESYNC_TIMEOUT_SAMPLES-1) begin
                    resync_timeout_cnt <= 22'd0;
                    force_resync <= 1'b1;
                end else begin
                    resync_timeout_cnt <= resync_timeout_cnt + 22'd1;
                end
            end
        end
    end

endmodule