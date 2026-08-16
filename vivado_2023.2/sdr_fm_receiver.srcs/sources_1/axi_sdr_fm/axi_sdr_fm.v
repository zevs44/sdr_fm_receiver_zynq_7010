`timescale 1ns / 1ps
// =============================================================================
//  axi_sdr_fm - FM SDR Receiver, AXI IP (No DMA, RX Control Only)
// =============================================================================
//   AXI4-Lite register map. The address bus is [7:0] (was [5:0]): the RDS
//   decoder already recovered PTY/TP/TA/M-S and the full 64-character
//   RadioText internally, but only PI and PS were brought out, and the old
//   16-slot map (0x00-0x3C) had no room left. RadioText alone needs 16
//   registers, so the bus was widened rather than packed. Everything at
//   0x00-0x3C keeps its old address and meaning, so existing software that
//   only touches those registers is unaffected.
//
//   !! BLOCK-DESIGN NOTE: widening s_axi_awaddr/s_axi_araddr changes the IP's
//   !! AXI4-Lite interface. After re-packaging, the address segment for this
//   !! peripheral must be at least 256 bytes (it was 64). In Vivado's Address
//   !! Editor set the range to 4K (the usual minimum for a PS-attached slave)
//   !! -- if it is left at 64 bytes, reads above 0x3C return the interconnect's
//   !! decode error instead of the new registers.
//
//    0x00 - TUNING_WORD [31:0]      RW  NCO tuning word
//    0x04 - RDS_PS_0 [31:0]         RO  RDS Program Service name (chars 1-4)
//    0x08 - RDS_PS_1 [31:0]         RO  RDS Program Service name (chars 5-8)
//    0x0C - reserved
//    0x10 - STATUS [31:0]           RO  [0]=stereo_lock, [1]=station_found,
//                                       [19:2]=18-bit raw RSSI, [20]=rds_sync
//    0x14 - VOLUME [3:0]            RW  Volume level 0-15
//    0x18 - CONTROLS [31:0]         RW  [0]=MUTE_EN, [1]=BASS_BOOST_EN,
//                                       [2]=RDS_EN, [3]=DEEMPH, [4]=MONO,
//                                       [31:5]=reserved. Cleared to 0 on
//                                       reset.
//    0x1C - RDS_PI [31:0]           RO  [15:0]=last known PI (latched from
//                                       a Block A group that passed the
//                                       checkword)
//    0x20 - RDS_FIFO_STAT [31:0]    RO  [7:0]=entries queued,
//                                       [8]=overflow (clear-on-read),
//                                       [9]=FIFO empty (informational)
//    0x24 - RDS_FIFO_DATA [31:0]    RO  [15:0]=raw 16-bit RDS info word,
//                                       [18:16]=block id (0=A,1=B,2=C,3=D),
//                                       [19]=corrected (passed checkword),
//                                       [20]=uncorrectable (failed
//                                       checkword). Reading pops one queue
//                                       entry.
//    0x28 - RDS_ERR_STATS [31:0]    RO  [15:0]=corrected-block counter
//                                       (free-running, wraps),
//                                       [31:16]=uncorrectable-block counter
//                                       (free-running, wraps) -- counted
//                                       directly from the raw block stream
//                                       (rds_raw_block_valid/good), not
//                                       from any decoder-internal counter
//                                       that resets on resynchronization,
//                                       so this stays free-running.
//    0x2C - MPX_FIFO_STAT [31:0]    RO  [MPX_FIFO_ADDR_W:0]=entries queued
//                                       (bits[10:0] for the default
//                                       1024-deep FIFO; width tracks
//                                       MPX_FIFO_DEPTH), [16]=overflow
//                                       (clear-on-read of THIS register),
//                                       [17]=FIFO empty (informational).
//    0x30 - MPX_FIFO_DATA [31:0]    RO  [15:0]=signed 16-bit raw MPX
//                                       composite sample (the same tap
//                                       point fm_stereo_demod's input
//                                       already uses -- L+R baseband +
//                                       19kHz pilot + 38kHz L-R DSB-SC +
//                                       57kHz RDS subcarrier, still
//                                       undecoded). Reading pops one queue
//                                       entry (read=pop, same convention
//                                       as RDS_FIFO_DATA). Check
//                                       MPX_FIFO_STAT first -- reading
//                                       while empty does not underflow but
//                                       returns stale data, not a fresh
//                                       sample.
//    0x34 - MPX_SHIFT [3:0]         RW  Arithmetic right-shift applied to
//                                       the demodulated MPX composite
//                                       before it's saturated to the
//                                       signed 16-bit FIFO sample (see
//                                       fm_mpx_scale.v). Useful values
//                                       are small: the composite is a
//                                       signed 18-bit phase difference
//                                       reaching roughly +/-39000 at full
//                                       +/-75 kHz deviation, so shift=1
//                                       (the reset value) fits worst-case
//                                       peaks with no clipping, and
//                                       shift=0 gives 6 dB more resolution
//                                       while clipping the loudest peaks.
//                                       Tune against a live signal.
//    0x38 - AUDIO_FIFO_STAT [31:0]  RO  [AUDIO_FIFO_ADDR_W:0]=entries
//                                       queued -- counts individual L/R
//                                       samples, NOT stereo pairs (each
//                                       pair pushes 2 entries), [16]=
//                                       overflow (clear-on-read of THIS
//                                       register), [17]=FIFO empty.
//    0x3C - AUDIO_FIFO_DATA [31:0]  RO  One sample, sign-extended from
//                                       AUDIO_DATA_WIDTH (24 by default)
//                                       to fill the 32-bit register --
//                                       i.e. AUDIO_DATA_WIDTH significant
//                                       bits, right-justified in 32 (ALSA's
//                                       S24_LE for the default width, NOT
//                                       S32_LE -- that would read 48 dB
//                                       too quiet -- and not the packed
//                                       3-byte S24_3LE). Software must
//                                       either declare S24_LE or left-shift
//                                       by (32-AUDIO_DATA_WIDTH) to get
//                                       true full-scale 32-bit PCM.
//                                       Entries alternate L, R, L, R...
//                                       Reading pops one entry (read=pop);
//                                       check AUDIO_FIFO_STAT first, same
//                                       convention as the MPX/RDS FIFOs.
//                                       This is the same signal path
//                                       already feeding fm_ds_dac and
//                                       i2s_tx (post volume/mute, post
//                                       resampling to 48 kHz) -- not a
//                                       raw/pre-volume tap, so the VOLUME
//                                       register (0x14) and MUTE_EN
//                                       (0x18[0]) affect what comes out
//                                       here too.
//    0x40 - RDS_FLAGS [31:0]        RO  Programme-wide RDS fields the decoder
//                                       already extracts from block B of every
//                                       group. All four are latched together
//                                       when a group completes, so one 32-bit
//                                       read of this register is inherently a
//                                       consistent snapshot.
//                                         [4:0]  PTY  Programme Type (0-31)
//                                         [5]    TP   Traffic Programme
//                                         [6]    TA   Traffic Announcement
//                                         [7]    M/S  1 = Music, 0 = Speech
//                                         [31:8] reserved, read as 0
//                                       TP is carried by every group type;
//                                       TA and M/S only appear in group 0, so
//                                       they hold their last received value
//                                       between group-0 transmissions.
//    0x44 - RDS_RT_0 [31:0]         RO  RadioText (group 2A), chars 1-4.
//    0x48 .. 0x80 - RDS_RT_1..15    RO  RadioText, 4 characters per register,
//                                       most-significant byte = earliest
//                                       character, 64 characters total.
//
//                                       COHERENCY: the decoder rewrites 4
//                                       characters at a time as groups arrive,
//                                       so reading 16 registers one by one
//                                       could otherwise straddle an update and
//                                       return a mix of the old and new text.
//                                       Reading RDS_RT_0 latches all 64
//                                       characters into a shadow register and
//                                       returns chars 1-4 from the live value
//                                       at that same instant; RDS_RT_1..15
//                                       then read out of that shadow. So:
//                                       ALWAYS READ 0x44 FIRST, then 0x48
//                                       upwards, and the 64 characters are
//                                       guaranteed to come from one moment in
//                                       time. Re-reading 0x44 takes a fresh
//                                       snapshot.
//
//                                       RadioText is padded with spaces and, if
//                                       the station sends a message shorter than
//                                       64 characters, terminated with 0x0D per
//                                       IEC 62106. Software should stop at the
//                                       0x0D rather than printing the padding.
//
//   Compatibility note: 0x2C, 0x30, 0x34, 0x38 and 0x3C previously read
//   back as zero (reserved/undecoded). Software that relied on that should
//   be updated before targeting this register map. The same applies to
//   0x40-0x80, which were outside the old address bus entirely.
// -----------------------------------------------------------------------------
//   SIGNAL FLOW: the RF front end (fm_rf_input -> fm_ddc_mixer -> I/Q CIC
//   decimators, all in clk_rf) produces decimated baseband I/Q, which
//   crosses into s_axi_aclk and is demodulated ONCE by a single shared
//   fm_cordic_discrim instance. Its MPX composite output then fans out to
//   three mutually independent consumers:
//
//     - fm_stereo_demod   -> stereo/mono audio, RSSI, pilot lock
//     - rds_decode        -> RDS (registers 0x04/0x08/0x10/0x1C-0x28,
//                            0x40-0x80)
//     - fm_mpx_scale    -> shift/saturate for the raw-MPX export FIFO
//                            (registers 0x2C/0x30/0x34)
//
//   None of the three reads anything produced by another, and any of them
//   can be removed or compiled out without affecting the rest -- they only
//   share the one demodulation all three would otherwise duplicate. This
//   matters most for RDS, which is broadcast on mono stations too and so
//   must not depend on the stereo demodulator. It also means the raw-MPX
//   export carries exactly the composite the receiver's own audio and RDS
//   paths see, rather than a separately-derived approximation of it.
//
//   Post-resampler stereo audio export (0x38/0x3C above) taps
//   audio_48k_l/r/valid -- the same s_axi_aclk-domain signal already
//   feeding fm_ds_dac and i2s_tx, i.e. after volume/mute and resampling,
//   the same content that comes out the analog/I2S outputs. A small
//   serializing FSM (see its instantiation site below) turns each L/R
//   pair into two back-to-back single-sample writes into
//   mpx_sample_fifo (reused generically here -- nothing MPX-specific
//   about that FIFO despite the name), since it has a single write port.
//   No additional CDC either -- audio_48k_* are already native to
//   s_axi_aclk.
// -----------------------------------------------------------------------------
// TWO CLOCK DOMAINS:
//   clk_rf (200-250 MHz)     -- fm_rf_input, fm_ddc_mixer, cic_inst_i/q only.
//                                These are the only blocks that need the
//                                full RF sample rate: the CIC decimators
//                                take ddc_i/ddc_q from the mixer at full
//                                rate and cannot decimate a stream that
//                                does not arrive at full rate.
//   s_axi_aclk (~50 MHz)     -- fm_cordic_discrim, fm_stereo_demod,
//                                rds_decode, audio_resampler, fm_ds_dac,
//                                i2s_tx, fm_mpx_scale, and the sample
//                                FIFOs. The actual sample rate into the
//                                shared discriminator is fixed at 250 kHz
//                                by CIC_R_DEC regardless of clk_rf --
//                                these blocks are throughput-, not
//                                latency-, bound, and comfortably meet
//                                timing at 50 MHz (200 cycles between
//                                samples).
//
//   The only clock-domain crossing is cic_i/cic_q/cic_valid_i (clk_rf ->
//   s_axi_aclk), using the same toggle-handshake scheme already used for
//   tuning_word (in the opposite direction). This is the sole CDC boundary
//   in the design between the RF front end and everything downstream --
//   the shared discriminator sits on the s_axi_aclk side of it, so every
//   MPX consumer is already in that domain. Every control signal into
//   fm_stereo_demod and rds_decode (mute_en, bass_boost_en, rds_en,
//   deemph, mono, cur_vol) and every status signal out of them
//   (pilot_locked, station_found, rds_sync, signal_level) are native
//   s_axi_aclk signals and need no synchronizer of their own.
// =============================================================================
module axi_sdr_fm #(
    parameter integer CLK_RF_HZ          = 250_000_000,
    parameter integer S_AXI_ACLK_HZ      = 50_000_000,
    parameter integer AUDIO_DATA_WIDTH   = 24,
    parameter         RSSI_THRESH_HI     = 18'd2000,
    parameter         RSSI_THRESH_LO     = 18'd1200,

    // ---- fm_stereo_demod feature parameters, exposed at the top level and
    //      forwarded to u_stereo_demod below. Defaults match
    //      fm_stereo_demod.v's own defaults. These are elaboration-time
    //      (synthesis) options, not runtime controls -- disabling a stage
    //      here removes its hardware from the build entirely rather than
    //      just idling it. ----
    parameter DEEMPH_SHIFT      = 8,   // de-emphasis IIR pole shift
    parameter DEEMPH_ENABLE     = 1,   // 1 = include the de-emphasis filter
    parameter STEREO_ENABLE     = 1,   // 1 = include the stereo (pilot PLL + L-R) path
    parameter RDS_ENABLE        = 1,   // 1 = include the RDS decoder
    parameter BASS_BOOST_ENABLE = 1,   // 1 = include the bass-boost filter

    // ---- Raw-MPX and post-resampler-audio export FIFO depths, each must
    //      be a power of 2. Tune against measured AXI4-Lite polling
    //      throughput on the PS side -- too shallow and a slow poller will
    //      see overflow, too deep costs BRAM/registers for no benefit. ----
    parameter integer MPX_FIFO_DEPTH   = 1024,
    parameter integer AUDIO_FIFO_DEPTH = 1024  // counts individual L/R entries, not stereo pairs (each pair = 2 entries)
) (
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET s_axi_aresetn" *)
    input  wire        s_axi_aclk,
    input  wire        s_axi_aresetn,
    input  wire [7:0]  s_axi_awaddr,
    input  wire [2:0]  s_axi_awprot,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [7:0]  s_axi_araddr,
    input  wire [2:0]  s_axi_arprot,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,
    input  wire        clk_rf,
    input  wire        rst_n,
    input  wire        lvds_p,
    input  wire        lvds_n,
    output wire        audio_out_l,
    output wire        audio_out_r,
    output wire        i2s_bclk,
    output wire        i2s_lrclk,
    output wire        i2s_sdata,
    output wire        led_stereo_lock,
    output wire        led_station_found,
    output wire        led_rds_sync,        // Lit while synchronized to RDS blocks.
                                             // rds_sync is already a native
                                             // s_axi_aclk signal (fm_stereo_demod
                                             // runs in this domain), so this is a
                                             // direct assignment, the same as
                                             // led_stereo_lock/led_station_found.
    output wire        led_audio_heartbeat  // Blinks at ~1 Hz, but only while
                                             // audio samples are actually flowing
                                             // (audio_48k_valid, genuine 48 kHz
                                             // after the resampler). Counted
                                             // directly in s_axi_aclk. If the
                                             // stream stops, the counter freezes
                                             // and the LED holds its current
                                             // state (neither fully off nor
                                             // fully on) -- visibly different
                                             // from "blinking".
    // The MPX/audio export path is register-map only -- no additional
    // ports (e.g. a dedicated heartbeat or interrupt) were added, so the
    // existing port list, and anything already wired to it in a block
    // design, does not need to change. Straightforward to add if wanted.
);

    localparam integer CIC_R_DEC  = CLK_RF_HZ / 250_000;
    // I2S_DIV is derived from S_AXI_ACLK_HZ, since i2s_tx runs in this domain.
    localparam integer I2S_DIV = (S_AXI_ACLK_HZ + (48000*2*32*2)/2) / (48000*2*32*2);
    localparam integer MPX_FIFO_ADDR_W   = $clog2(MPX_FIFO_DEPTH);
    localparam integer AUDIO_FIFO_ADDR_W = $clog2(AUDIO_FIFO_DEPTH);

    // Register indices (address[7:2]) for the RDS text block added below.
    localparam [5:0] IDX_RDS_FLAGS = 6'd16;   // 0x40
    localparam [5:0] IDX_RDS_RT0   = 6'd17;   // 0x44
    localparam [5:0] IDX_RDS_RT15  = 6'd32;   // 0x80

    reg [31:0] reg_tuning_word;
    reg [3:0]  reg_volume;
    reg [31:0] reg_controls;
    reg [3:0]  reg_mpx_shift;

    wire mute_en       = reg_controls[0];
    wire [3:0] cur_vol = reg_volume[3:0];
    wire bass_boost_en = reg_controls[1];
    wire rds_en        = reg_controls[2];
    wire deemph        = reg_controls[3];
    wire mono          = reg_controls[4];

    reg s_axil_awready_r, s_axil_wready_r, s_axil_bvalid_r;
    reg [1:0] s_axil_bresp_r;
    assign s_axi_awready = s_axil_awready_r;
    assign s_axi_wready  = s_axil_wready_r;
    assign s_axi_bvalid  = s_axil_bvalid_r;
    assign s_axi_bresp   = s_axil_bresp_r;

    reg [7:0] axil_aw_addr_lat;
    reg       axil_aw_valid_lat;

    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin : axil_write_proc
        if (!s_axi_aresetn) begin
            s_axil_awready_r  <= 1'b0;  s_axil_wready_r   <= 1'b0;
            s_axil_bvalid_r   <= 1'b0;  s_axil_bresp_r    <= 2'b00;
            axil_aw_addr_lat  <= 8'd0;  axil_aw_valid_lat <= 1'b0;
            reg_tuning_word   <= 32'd0;
            reg_volume        <= 4'd0;
            reg_controls      <= 32'd0;
            reg_mpx_shift     <= 4'd1;  // fits full-deviation peaks -- see the MPX_SHIFT register note above
        end else begin
            s_axil_awready_r <= 1'b0;
            s_axil_wready_r  <= 1'b0;
            if (s_axi_awvalid && !axil_aw_valid_lat) begin
                s_axil_awready_r  <= 1'b1;
                axil_aw_addr_lat  <= s_axi_awaddr;
                axil_aw_valid_lat <= 1'b1;
            end
            if (axil_aw_valid_lat && s_axi_wvalid) begin
                s_axil_wready_r   <= 1'b1;
                axil_aw_valid_lat <= 1'b0;
                case (axil_aw_addr_lat[7:2])
                    6'd0: begin
                        if (s_axi_wstrb[0]) reg_tuning_word[7:0]   <= s_axi_wdata[7:0];
                        if (s_axi_wstrb[1]) reg_tuning_word[15:8]  <= s_axi_wdata[15:8];
                        if (s_axi_wstrb[2]) reg_tuning_word[23:16] <= s_axi_wdata[23:16];
                        if (s_axi_wstrb[3]) reg_tuning_word[31:24] <= s_axi_wdata[31:24];
                    end
                    6'd5: begin
                        if (s_axi_wstrb[0]) reg_volume             <= s_axi_wdata[3:0];
                    end
                    6'd6: begin
                        if (s_axi_wstrb[0]) reg_controls[7:0]      <= s_axi_wdata[7:0];
                        if (s_axi_wstrb[1]) reg_controls[15:8]     <= s_axi_wdata[15:8];
                        if (s_axi_wstrb[2]) reg_controls[23:16]    <= s_axi_wdata[23:16];
                        if (s_axi_wstrb[3]) reg_controls[31:24]    <= s_axi_wdata[31:24];
                    end
                    6'd13: begin  // MPX_SHIFT (0x34)
                        if (s_axi_wstrb[0]) reg_mpx_shift          <= s_axi_wdata[3:0];
                    end
                    default: ;   // everything else is read-only or unmapped
                endcase
                s_axil_bvalid_r <= 1'b1;
                s_axil_bresp_r  <= 2'b00;
            end
            if (s_axil_bvalid_r && s_axi_bready)
                s_axil_bvalid_r <= 1'b0;
        end
    end

    // ---------------------------------------------------------------------
    // Reset synchronizer for the clk_rf domain -- needed by fm_rf_input,
    // fm_ddc_mixer, cic_inst_i/q, and the tuning_word receive side, all of
    // which live in this domain.
    // ---------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg rst_n_rf_meta, rst_n_rf_sync;

    always @(posedge clk_rf or negedge rst_n) begin
        if (!rst_n) begin
            rst_n_rf_meta <= 1'b0;
            rst_n_rf_sync <= 1'b0;
        end else begin
            rst_n_rf_meta <= 1'b1;
            rst_n_rf_sync <= rst_n_rf_meta;
        end
    end

    wire        pilot_locked;
    wire        station_found;
    wire [17:0] signal_level;
    wire        audio_valid;
    wire        rds_sync;
    wire [63:0] rds_ps;
    // Declared here (used below by the audio heartbeat block, ahead of
    // where u_resampler is instantiated).
    wire signed [AUDIO_DATA_WIDTH-1:0] audio_48k_l, audio_48k_r;
    wire        audio_48k_valid;

    // ---- Functional data from the RDS decoder (instantiated at this level,
    //      see the register map above). ----
    wire [15:0]  rds_pi_w;
    wire [4:0]   rds_pty_w;
    wire         rds_tp_w;
    wire         rds_ta_w;
    wire         rds_ms_w;
    wire [511:0] rds_rt_w;
    wire        rds_raw_block_valid_w;
    wire [15:0] rds_raw_block_data_w;
    wire [2:0]  rds_raw_block_id_w;
    wire        rds_raw_block_good_w;

    // -- rds_ps stability check: rds_ps only latches into rds_ps_stable
    //    once the same 64-bit value has held for 255 consecutive cycles on
    //    s_axi_aclk (the same domain rds_ps itself lives in), guarding
    //    against reading it mid-update from inside the decoder's own
    //    multi-cycle PS assembly. --
    reg [63:0] rds_ps_stable;
    reg [63:0] rds_ps_candidate;
    reg [7:0]  rds_ps_stable_cnt;

    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            rds_ps_stable     <= 64'd0;
            rds_ps_candidate  <= 64'd0;
            rds_ps_stable_cnt <= 8'd0;
        end else begin
            if (rds_ps == rds_ps_candidate) begin
                if (rds_ps_stable_cnt < 8'd255) begin
                    rds_ps_stable_cnt <= rds_ps_stable_cnt + 1'b1;
                end else if (rds_ps_stable != rds_ps_candidate) begin
                    rds_ps_stable <= rds_ps_candidate;
                end
            end else begin
                rds_ps_candidate  <= rds_ps;
                rds_ps_stable_cnt <= 8'd0;
            end
        end
    end

    assign led_stereo_lock   = ~pilot_locked;
    assign led_station_found = ~station_found;
    assign led_rds_sync      = ~rds_sync;

    // ---- Audio heartbeat (see led_audio_heartbeat port comment above):
    //      counts genuine audio_48k_valid samples (already true 48 kHz,
    //      post-resampler) -- toggles once every 24000 samples (=0.5 s at
    //      48 kHz). If samples stop arriving the counter simply stops,
    //      leaving the heartbeat frozen in its last state. ----
    localparam integer HEARTBEAT_SAMPLES = 24000;   // 0.5 s at 48 kHz
    reg [15:0] heartbeat_cnt;
    reg        heartbeat_r;
    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            heartbeat_cnt <= 16'd0;
            heartbeat_r   <= 1'b0;
        end else if (audio_48k_valid) begin
            if (heartbeat_cnt == HEARTBEAT_SAMPLES-1) begin
                heartbeat_cnt <= 16'd0;
                heartbeat_r   <= ~heartbeat_r;
            end else begin
                heartbeat_cnt <= heartbeat_cnt + 1'b1;
            end
        end
    end
    assign led_audio_heartbeat = ~heartbeat_r;

    reg s_axil_arready_r, s_axil_rvalid_r;
    reg [31:0] s_axil_rdata_r;
    assign s_axi_arready = s_axil_arready_r;
    assign s_axi_rvalid  = s_axil_rvalid_r;
    assign s_axi_rdata   = s_axil_rdata_r;
    assign s_axi_rresp   = 2'b00;

    // ---------------------------------------------------------------------
    // Raw-RDS-block FIFO + AXI read-side strobes (RDS_FIFO_STAT/DATA, see
    // the register map above). A SYNCHRONOUS (not async) FIFO -- rds_decode
    // and this AXI read logic are both in the s_axi_aclk domain (see the
    // clock-domain architecture note above), so no cross-domain FIFO is
    // needed. read_accepted/fifo_pop_strobe/fifo_clr_ovf_strobe are
    // combinational and declared here (ahead of the read mux below) because
    // the read mux both reads the FIFO head combinationally
    // (rd_data/rd_id/rd_good) and must trigger a pop as a side effect of
    // accepting THIS read -- see rds_block_fifo.v for the single-cycle AXI
    // read convention this relies on. The MPX and post-resampler-audio
    // FIFOs below follow the same convention.
    //
    // NOTE the convention only works because this FSM asserts arready AND
    // rvalid in the same cycle, which makes read_accepted a one-cycle pulse.
    // ---------------------------------------------------------------------
    wire read_accepted = s_axi_arvalid && !s_axil_rvalid_r;
    wire fifo_pop_strobe      = read_accepted && (s_axi_araddr[7:2] == 6'd9);  // RDS_FIFO_DATA (0x24)
    wire fifo_clr_ovf_strobe  = read_accepted && (s_axi_araddr[7:2] == 6'd8);  // RDS_FIFO_STAT  (0x20)

    wire mpx_fifo_pop_strobe     = read_accepted && (s_axi_araddr[7:2] == 6'd12);  // MPX_FIFO_DATA (0x30)
    wire mpx_fifo_clr_ovf_strobe = read_accepted && (s_axi_araddr[7:2] == 6'd11);  // MPX_FIFO_STAT (0x2C)

    wire audio_fifo_pop_strobe     = read_accepted && (s_axi_araddr[7:2] == 6'd15);  // AUDIO_FIFO_DATA (0x3C)
    wire audio_fifo_clr_ovf_strobe = read_accepted && (s_axi_araddr[7:2] == 6'd14);  // AUDIO_FIFO_STAT (0x38)

    // -- RadioText snapshot strobe: reading RDS_RT_0 (0x44) freezes all 64
    //    characters so the remaining 15 registers come from one instant. --
    wire rds_rt_snap_strobe = read_accepted && (s_axi_araddr[7:2] == IDX_RDS_RT0);

    reg [511:0] rds_rt_snap;
    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) rds_rt_snap <= 512'd0;
        else if (rds_rt_snap_strobe) rds_rt_snap <= rds_rt_w;
    end

    wire [15:0] fifo_rd_data_w;
    wire [2:0]  fifo_rd_id_w;
    wire        fifo_rd_good_w;
    wire [5:0]  fifo_count_w;
    wire        fifo_empty_w;
    wire        fifo_overflow_w;

    rds_block_fifo #(.DEPTH(32), .ADDR_W(5)) u_rds_fifo (
        .clk  (s_axi_aclk),
        .rst_n(s_axi_aresetn),
        .wr_en  (rds_raw_block_valid_w),
        .wr_data(rds_raw_block_data_w),
        .wr_id  (rds_raw_block_id_w),
        .wr_good(rds_raw_block_good_w),
        .rd_pop (fifo_pop_strobe),
        .rd_data(fifo_rd_data_w),
        .rd_id  (fifo_rd_id_w),
        .rd_good(fifo_rd_good_w),
        .count  (fifo_count_w),
        .empty  (fifo_empty_w),
        .clr_overflow (fifo_clr_ovf_strobe),
        .overflow_flag(fifo_overflow_w)
    );

    // ---- RDS_ERR_STATS: free-running (wrapping) counters, driven
    //      directly from the raw block stream (see the register map note
    //      above for why these are separate from any decoder-internal
    //      error counter). ----
    reg [15:0] rds_corrected_count, rds_uncorrectable_count;
    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            rds_corrected_count     <= 16'd0;
            rds_uncorrectable_count <= 16'd0;
        end else if (rds_raw_block_valid_w) begin
            if (rds_raw_block_good_w) rds_corrected_count     <= rds_corrected_count + 16'd1;
            else                      rds_uncorrectable_count <= rds_uncorrectable_count + 16'd1;
        end
    end

    // ---- Raw MPX composite export FIFO. Its write side is driven by
    //      fm_mpx_scale (shift + saturate), which is fed the shared
    //      discriminator's MPX composite -- both are instantiated further
    //      down; Verilog resolves the forward reference fine regardless of
    //      textual order. ----
    wire signed [15:0] mpx_sample_w;
    wire               mpx_valid_out_w;
    wire signed [15:0]       mpx_fifo_rd_data_w;
    wire [MPX_FIFO_ADDR_W:0] mpx_fifo_count_w;
    wire                     mpx_fifo_empty_w;
    wire                     mpx_fifo_overflow_w;

    mpx_sample_fifo #(.DEPTH(MPX_FIFO_DEPTH), .DATA_W(16)) u_mpx_fifo (
        .clk  (s_axi_aclk),
        .rst_n(s_axi_aresetn),
        .wr_en  (mpx_valid_out_w),
        .wr_data(mpx_sample_w),
        .rd_pop (mpx_fifo_pop_strobe),
        .rd_data(mpx_fifo_rd_data_w),
        .count  (mpx_fifo_count_w),
        .empty  (mpx_fifo_empty_w),
        .clr_overflow (mpx_fifo_clr_ovf_strobe),
        .overflow_flag(mpx_fifo_overflow_w)
    );

    // ---- Post-resampler audio export: audio_48k_l/r arrive together (one
    //      pair per audio_48k_valid pulse, at 48 kHz -- roughly every 1042
    //      s_axi_aclk cycles at 50 MHz), but the FIFO below (reusing
    //      mpx_sample_fifo generically) has a single write port, so this
    //      small FSM serializes each pair into two back-to-back
    //      single-sample writes, L then R -- giving a plain interleaved
    //      L,R,L,R... stream on readout, matching standard
    //      interleaved-stereo PCM ordering with no further work needed in
    //      software. 2-3 cycles to drain a pair vs. ~1042 before the next
    //      one arrives is a large margin; a second pair arriving before
    //      the first has finished draining is not a realistic scenario and
    //      is not specially handled (it would simply be missed) -- the
    //      same "producer must not outrun the consumer" assumption the CDC
    //      toggle synchronizers elsewhere in this design already make
    //      about their own margins. ----
    localparam AP_IDLE = 2'd0, AP_EMIT_L = 2'd1, AP_EMIT_R = 2'd2;
    reg [1:0] audio_pack_state;
    reg signed [AUDIO_DATA_WIDTH-1:0] audio_l_hold, audio_r_hold;

    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            audio_pack_state <= AP_IDLE;
            audio_l_hold     <= {AUDIO_DATA_WIDTH{1'b0}};
            audio_r_hold     <= {AUDIO_DATA_WIDTH{1'b0}};
        end else begin
            case (audio_pack_state)
                AP_IDLE: if (audio_48k_valid) begin
                    audio_l_hold     <= audio_48k_l;
                    audio_r_hold     <= audio_48k_r;
                    audio_pack_state <= AP_EMIT_L;
                end
                AP_EMIT_L: audio_pack_state <= AP_EMIT_R;
                AP_EMIT_R: audio_pack_state <= AP_IDLE;
                default:   audio_pack_state <= AP_IDLE;
            endcase
        end
    end

    wire audio_fifo_wr_en   = (audio_pack_state == AP_EMIT_L) || (audio_pack_state == AP_EMIT_R);
    wire signed [AUDIO_DATA_WIDTH-1:0] audio_fifo_wr_data = (audio_pack_state == AP_EMIT_L) ? audio_l_hold : audio_r_hold;

    wire signed [AUDIO_DATA_WIDTH-1:0] audio_fifo_rd_data_w;
    wire [AUDIO_FIFO_ADDR_W:0]         audio_fifo_count_w;
    wire                               audio_fifo_empty_w;
    wire                               audio_fifo_overflow_w;

    mpx_sample_fifo #(.DEPTH(AUDIO_FIFO_DEPTH), .DATA_W(AUDIO_DATA_WIDTH)) u_audio_fifo (
        .clk  (s_axi_aclk),
        .rst_n(s_axi_aresetn),
        .wr_en  (audio_fifo_wr_en),
        .wr_data(audio_fifo_wr_data),
        .rd_pop (audio_fifo_pop_strobe),
        .rd_data(audio_fifo_rd_data_w),
        .count  (audio_fifo_count_w),
        .empty  (audio_fifo_empty_w),
        .clr_overflow (audio_fifo_clr_ovf_strobe),
        .overflow_flag(audio_fifo_overflow_w)
    );

    // -- RadioText read helper: register index -> which 32-bit slice.
    //    rds_rt_w[511:504] is the FIRST character, so register k holds
    //    bits [(15-k)*32 +: 32]. --
    wire [5:0] ar_idx     = s_axi_araddr[7:2];
    wire [3:0] rds_rt_sel = ar_idx[3:0] - IDX_RDS_RT0[3:0];   // 0..15 within the RT block
    wire       rds_rt_hit = (ar_idx >= IDX_RDS_RT0) && (ar_idx <= IDX_RDS_RT15);

    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin : axil_read_proc
        if (!s_axi_aresetn) begin
            s_axil_arready_r <= 1'b0;
            s_axil_rvalid_r  <= 1'b0;
            s_axil_rdata_r   <= 32'd0;
        end else begin
            s_axil_arready_r <= 1'b0;
            if (read_accepted) begin
                s_axil_arready_r <= 1'b1;
                s_axil_rvalid_r  <= 1'b1;
                case (ar_idx)
                    6'd0: s_axil_rdata_r <= reg_tuning_word;
                    6'd1: s_axil_rdata_r <= rds_ps_stable[63:32];        // chars 1-4
                    6'd2: s_axil_rdata_r <= rds_ps_stable[31:0];         // chars 5-8
                    6'd4: s_axil_rdata_r <= {11'b0, rds_sync, signal_level, station_found, pilot_locked};
                    6'd5: s_axil_rdata_r <= {28'b0, reg_volume};
                    6'd6: s_axil_rdata_r <= reg_controls;
                    6'd7: s_axil_rdata_r <= {16'b0, rds_pi_w};                                         // RDS_PI
                    6'd8: s_axil_rdata_r <= {22'b0, fifo_empty_w, fifo_overflow_w, 2'b0, fifo_count_w}; // RDS_FIFO_STAT
                    6'd9: s_axil_rdata_r <= {11'b0, ~fifo_rd_good_w, fifo_rd_good_w,                    // RDS_FIFO_DATA (read = pop, see fifo_pop_strobe above)
                                              fifo_rd_id_w, fifo_rd_data_w};
                    6'd10: s_axil_rdata_r <= {rds_uncorrectable_count, rds_corrected_count};            // RDS_ERR_STATS
                    6'd11: s_axil_rdata_r <= {14'b0, mpx_fifo_empty_w, mpx_fifo_overflow_w,
                                               {(15-MPX_FIFO_ADDR_W){1'b0}}, mpx_fifo_count_w};          // MPX_FIFO_STAT (0x2C)
                    6'd12: s_axil_rdata_r <= {16'b0, mpx_fifo_rd_data_w};                                // MPX_FIFO_DATA (0x30, read = pop, see mpx_fifo_pop_strobe above)
                    6'd13: s_axil_rdata_r <= {28'b0, reg_mpx_shift};                                     // MPX_SHIFT (0x34)
                    6'd14: s_axil_rdata_r <= {14'b0, audio_fifo_empty_w, audio_fifo_overflow_w,
                                               {(15-AUDIO_FIFO_ADDR_W){1'b0}}, audio_fifo_count_w};      // AUDIO_FIFO_STAT (0x38)
                    6'd15: s_axil_rdata_r <= {{(32-AUDIO_DATA_WIDTH){audio_fifo_rd_data_w[AUDIO_DATA_WIDTH-1]}},
                                               audio_fifo_rd_data_w};                                     // AUDIO_FIFO_DATA (0x3C, read = pop, sign-extended to 32 bits)
                    IDX_RDS_FLAGS:                                                                        // RDS_FLAGS (0x40)
                           s_axil_rdata_r <= {24'b0, rds_ms_w, rds_ta_w, rds_tp_w, rds_pty_w};
                    IDX_RDS_RT0:                                                                          // RDS_RT_0 (0x44)
                           // Taken from the LIVE value, not the shadow: the shadow
                           // is being loaded from the same rds_rt_w on this very
                           // edge, so reading it here would return the PREVIOUS
                           // snapshot's first word and desynchronise it from the
                           // 15 registers that follow.
                           s_axil_rdata_r <= rds_rt_w[511 -: 32];
                    default: begin
                        if (rds_rt_hit)
                            s_axil_rdata_r <= rds_rt_snap[(4'd15 - rds_rt_sel)*32 +: 32];   // RDS_RT_1..15 (0x48-0x80)
                        else
                            s_axil_rdata_r <= 32'd0;
                    end
                endcase
            end
            if (s_axil_rvalid_r && s_axi_rready)
                s_axil_rvalid_r <= 1'b0;
        end
    end

    // -- tuning_word: s_axi_aclk -> clk_rf, toggle-handshake CDC
    //    (fm_ddc_mixer lives in clk_rf).
    wire cdc_tw_wr = (axil_aw_valid_lat && s_axi_wvalid &&
                      (axil_aw_addr_lat[7:2] == 6'd0));
    reg  cdc_tw_wr_d;
    reg [31:0] tw_data_hold;
    reg        tw_req_toggle;

    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            cdc_tw_wr_d   <= 1'b0;
            tw_data_hold  <= 32'd0;
            tw_req_toggle <= 1'b0;
        end else begin
            cdc_tw_wr_d <= cdc_tw_wr;
            if (cdc_tw_wr_d) begin
                tw_data_hold  <= reg_tuning_word;
                tw_req_toggle <= ~tw_req_toggle;
            end
        end
    end

    (* ASYNC_REG = "TRUE" *) reg tw_req_rf0, tw_req_rf1;
    reg tw_req_rf2;
    reg [31:0] tuning_word_rf;

    always @(posedge clk_rf or negedge rst_n_rf_sync) begin
        if (!rst_n_rf_sync) begin
            tw_req_rf0     <= 1'b0;
            tw_req_rf1     <= 1'b0;
            tw_req_rf2     <= 1'b0;
            tuning_word_rf <= 32'd0;
        end else begin
            tw_req_rf0 <= tw_req_toggle;
            tw_req_rf1 <= tw_req_rf0;
            tw_req_rf2 <= tw_req_rf1;
            if (tw_req_rf2 ^ tw_req_rf1)
                tuning_word_rf <= tw_data_hold;
        end
    end

    wire rf_bit;
    wire signed [8:0]  ddc_i, ddc_q;
    wire               ddc_valid;
    wire signed [15:0] cic_i, cic_q;
    wire               cic_valid_i;

    fm_rf_input u_input (
        .clk(clk_rf),
        .rst_n(rst_n_rf_sync),
        .lvds_p(lvds_p),
        .lvds_n(lvds_n),
        .rf_bit(rf_bit)
    );

    fm_ddc_mixer u_ddc (
        .clk(clk_rf), .rst_n(rst_n_rf_sync), .rf_bit(rf_bit), .tuning_word(tuning_word_rf),
        .i_out(ddc_i), .q_out(ddc_q), .valid_out(ddc_valid)
    );

    cic_decimator #(.B_IN(9), .N_STAGES(4), .R_DEC(CIC_R_DEC), .B_OUT(16)) cic_inst_i (
        .clk(clk_rf), .rst_n(rst_n_rf_sync), .data_in(ddc_i), .valid_in(ddc_valid), .data_out(cic_i), .valid_out(cic_valid_i)
    );

    cic_decimator #(.B_IN(9), .N_STAGES(4), .R_DEC(CIC_R_DEC), .B_OUT(16)) cic_inst_q (
        .clk(clk_rf), .rst_n(rst_n_rf_sync), .data_in(ddc_q), .valid_in(ddc_valid), .data_out(cic_q), .valid_out()
    );

    reg signed [15:0] cic_i_hold, cic_q_hold;
    reg                cic_vld_toggle_rf;

    always @(posedge clk_rf or negedge rst_n_rf_sync) begin
        if (!rst_n_rf_sync) begin
            cic_i_hold        <= 16'sd0;
            cic_q_hold        <= 16'sd0;
            cic_vld_toggle_rf <= 1'b0;
        end else if (cic_valid_i) begin
            cic_i_hold        <= cic_i;
            cic_q_hold        <= cic_q;
            cic_vld_toggle_rf <= ~cic_vld_toggle_rf;
        end
    end

    (* ASYNC_REG = "TRUE" *) reg cic_vld_axi0, cic_vld_axi1;
    reg                cic_vld_axi2;
    reg signed [15:0] cic_i_axi, cic_q_axi;
    reg                cic_valid_axi_r;

    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            cic_vld_axi0    <= 1'b0;
            cic_vld_axi1    <= 1'b0;
            cic_vld_axi2    <= 1'b0;
            cic_i_axi       <= 16'sd0;
            cic_q_axi       <= 16'sd0;
            cic_valid_axi_r <= 1'b0;
        end else begin
            cic_vld_axi0    <= cic_vld_toggle_rf;
            cic_vld_axi1    <= cic_vld_axi0;
            cic_vld_axi2    <= cic_vld_axi1;
            cic_valid_axi_r <= (cic_vld_axi2 ^ cic_vld_axi1);
            if (cic_vld_axi2 ^ cic_vld_axi1) begin
                cic_i_axi <= cic_i_hold;
                cic_q_axi <= cic_q_hold;
            end
        end
    end
    wire cic_valid_axi = cic_valid_axi_r;

    wire signed [AUDIO_DATA_WIDTH-1:0] audio_l, audio_r;

    // ---- Shared FM discriminator: ONE instance, fanned out to every
    //      consumer of the MPX composite (the stereo demodulator, the RDS
    //      decoder, and the raw-MPX export path below). Each consumer is
    //      independent of the others -- none reads any signal produced by
    //      another, and any of them can be compiled out without affecting
    //      the rest; they simply share the single demodulation that all
    //      three would otherwise duplicate. In particular RDS decoding
    //      does not depend on fm_stereo_demod at all, which matters
    //      because RDS is broadcast on mono stations too. ----
    wire signed [17:0] mpx_w;
    wire               mpx_valid_w;
    wire signed [17:0] mpx_mag_w;
    wire               mpx_mag_valid_w;

    fm_cordic_discrim #(.IQ_W(16)) u_discrim (
        .clk      (s_axi_aclk),
        .rst_n    (s_axi_aresetn),
        .i_in     (cic_i_axi),
        .q_in     (cic_q_axi),
        .valid_in (cic_valid_axi),
        .mpx_out  (mpx_w),
        .mpx_valid(mpx_valid_w),
        .mag_out  (mpx_mag_w),
        .mag_valid(mpx_mag_valid_w)
    );

    fm_stereo_demod #(
        .MAG_W(18),
        .DEEMPH_SHIFT(DEEMPH_SHIFT),
        .DEEMPH_ENABLE(DEEMPH_ENABLE),
        .STEREO_ENABLE(STEREO_ENABLE),
        .BASS_BOOST_ENABLE(BASS_BOOST_ENABLE),
        .RSSI_THRESH_HI(RSSI_THRESH_HI), .RSSI_THRESH_LO(RSSI_THRESH_LO),
        .PILOT_LOCK_THRESH(24'sd200000), .PILOT_LOCK_THRESH_HI(24'sd400000)
    ) u_stereo_demod (
        .clk(s_axi_aclk), .rst_n(s_axi_aresetn),
        .mpx_in(mpx_w), .mpx_valid(mpx_valid_w),
        .mag_in(mpx_mag_w), .mag_valid(mpx_mag_valid_w),
        .bass_boost_en(bass_boost_en), .deemph_sel(deemph), .mono_sel(mono),
        .volume(4'd15), .mute_en(mute_en),
        .audio_l(audio_l), .audio_r(audio_r), .audio_valid(audio_valid),
        .pilot_locked(pilot_locked), .station_found(station_found), .signal_level(signal_level)
    );

    // ---- RDS decoder, fed the same shared MPX composite. Nothing here
    //      comes from fm_stereo_demod, so RDS decoding works whether or not
    //      the stereo demodulator is present or enabled. Compiled out
    //      entirely when RDS_ENABLE=0.
    //
    //      rds_pty/tp/ta/ms and rds_rt feed registers 0x40-0x80 (see the
    //      register map above). ----
    generate if (RDS_ENABLE) begin : gen_rds
        rds_decode u_rds (
            .clk      (s_axi_aclk),
            .rst_n    (s_axi_aresetn),
            .rds_en   (rds_en),
            .mpx_in   (mpx_w),
            .mpx_valid(mpx_valid_w),
            .rds_sync (rds_sync),
            .rds_ps   (rds_ps),
            .rds_pi   (rds_pi_w),
            .rds_pty  (rds_pty_w),
            .rds_tp   (rds_tp_w),
            .rds_ta   (rds_ta_w),
            .rds_ms   (rds_ms_w),
            .rds_rt   (rds_rt_w),
            .rds_raw_block_valid (rds_raw_block_valid_w),
            .rds_raw_block_data  (rds_raw_block_data_w),
            .rds_raw_block_id    (rds_raw_block_id_w),
            .rds_raw_block_good  (rds_raw_block_good_w)
        );
    end else begin : gen_rds_bypass
        // Nothing to decode with the RDS path elided -- tie the status/data
        // signals off so the RDS registers and FIFO read back as idle.
        // rds_en is unused in this branch.
        assign rds_sync              = 1'b0;
        assign rds_ps                = 64'd0;
        assign rds_pi_w              = 16'd0;
        assign rds_pty_w             = 5'd0;
        assign rds_tp_w              = 1'b0;
        assign rds_ta_w              = 1'b0;
        assign rds_ms_w              = 1'b0;
        assign rds_rt_w              = 512'd0;
        assign rds_raw_block_valid_w = 1'b0;
        assign rds_raw_block_data_w  = 16'd0;
        assign rds_raw_block_id_w    = 3'd0;
        assign rds_raw_block_good_w  = 1'b0;
    end
    endgenerate

    audio_resampler #(
        .AUDIO_W(AUDIO_DATA_WIDTH),
        .FS_IN(50000), .FS_OUT(48000),
        .FILTER_EN(0),
        .EQ_EN(0)
    ) u_resampler (
          .clk(s_axi_aclk), .rst_n(s_axi_aresetn), .in_l(audio_l), .in_r(audio_r), .valid_in(audio_valid),
          .eq_gain(15'b0),
          .volume(cur_vol), .mute_en(mute_en),
          .out_l(audio_48k_l), .out_r(audio_48k_r), .valid_out(audio_48k_valid)
    );

    fm_ds_dac #(.AUDIO_WIDTH(AUDIO_DATA_WIDTH)) u_stereo_dac (
        .clk(s_axi_aclk), .rst_n(s_axi_aresetn), .audio_l(audio_48k_l), .audio_r(audio_48k_r), .audio_valid(audio_48k_valid),
        .volume(4'd15), .mute_en(mute_en), .dac_out_l(audio_out_l), .dac_out_r(audio_out_r)
    );

    i2s_tx #(.DATA_WIDTH(AUDIO_DATA_WIDTH), .SLOT_WIDTH(32), .BCLK_DIV(I2S_DIV[7:0])) u_i2s (
        .clk(s_axi_aclk), .rst_n(s_axi_aresetn), .audio_l(audio_48k_l), .audio_r(audio_48k_r), .audio_valid(audio_48k_valid),
        .volume(4'd15), .mute_en(mute_en),
        .i2s_bclk(i2s_bclk), .i2s_lrclk(i2s_lrclk), .i2s_sdata(i2s_sdata)
    );

    // ---- Raw-MPX export conditioning (shift + saturate to 16 bits), fed
    //      the same shared MPX composite as the stereo and RDS paths, so
    //      what software reads out of MPX_FIFO_DATA is exactly the
    //      composite the receiver itself demodulates from. ----
    fm_mpx_scale u_mpx_scale (
        .clk(s_axi_aclk), .rst_n(s_axi_aresetn),
        .mpx_in(mpx_w), .valid_in(mpx_valid_w),
        .shift(reg_mpx_shift),
        .mpx_out(mpx_sample_w), .mpx_valid(mpx_valid_out_w)
    );

endmodule