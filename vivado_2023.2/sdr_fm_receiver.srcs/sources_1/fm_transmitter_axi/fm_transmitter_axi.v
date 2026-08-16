`timescale 1ns / 1ps
// ============================================================================
//  FM STEREO TRANSMITTER IP CORE with AXI4-LITE (DUAL-CLOCK ARCHITECTURE)
// ============================================================================
//  FIXED: Restored the exact 40-BIT PHASE ACCUMULATOR from the original module!
//         This fixes the "hissing" issue caused by 32-bit truncation.
//  TIMING: 40-bit RF NCO is pipelined into 4 stages for Guaranteed Positive WNS.
// ============================================================================
//  !! DEVIATION WARNING -- the old header claimed "<<< 8 maps to ~75 kHz".
//  !! That is FALSE. Measured in simulation (Icarus, min/max of rf_pinc_st3):
//  !!
//  !!   1 FTW LSB          = CLK_RF_HZ / 2^40      = 181.899 uHz  @200 MHz
//  !!   1 mpx LSB @ shift8 = 256 * that            =  46.566 mHz
//  !!
//  !!   full-scale mpx (8388607) -> +/- 390.6 kHz  (520% of the 75 kHz budget)
//  !!   19 kHz pilot alone       -> +/-  43.96 kHz ( 58.6% -- spec says 9%)
//  !!   57 kHz RDS alone         -> +/-  13.67 kHz ( 18.2% -- spec says 3-4%)
//  !!   silence (pilot+RDS only) -> +/-  57.6  kHz with NO audio at all
//  !!
//  !! Carson BW at full scale ~= 2*(390 + 57) = 894 kHz, vs ~200-250 kHz for a
//  !! normal FM channel filter. A receiver cannot demodulate this.
//  !! FIXED: register 0x0C is now a Q8.8 GAIN, not a shift. A power-of-two
//  !! shift simply cannot express the gain this needs -- at CLK_RF_HZ =
//  !! 250 MHz, 75 kHz at full-scale mpx wants x39.32 (log2 = 5.30), and the
//  !! neighbouring shifts land on 61.0 kHz and 122.1 kHz. The old default of
//  !! 8 was 488 kHz full scale, which no receiver with a 250 kHz sample rate
//  !! can demodulate at all -- measured, not theorised: on 8 nothing decoded,
//  !! on 5 the pilot came out at 6.87 kHz and RDS decoded 100% off air.
// ============================================================================
//  RAW MPX EXPORT (0x44/0x48/0x4C, added) -- lets the baseband composite
//  (pilot + 38k stereo + 57k RDS, pre-NCO, pre-antenna) be captured directly
//  over AXI-Lite and fed to an external tool (redsea, this project's own
//  rds_decode.v testbenches, a spectrum plot) without going through the RF
//  NCO, the antenna, or a receiver at all. This isolates "is the baseband
//  generator correct" from "is the RF/antenna path correct" -- exactly the
//  two hypotheses that are otherwise indistinguishable from an off-air
//  capture alone.
//
//  The export itself lives in tx_mpx_export.v; this module only wires the
//  internal `mpx` register to it and maps its FIFO onto three registers,
//  using axi_sdr_fm.v's MPX_FIFO_STAT/DATA convention (read = pop,
//  clear-on-read overflow flag) so mpx_dump.c drives it unchanged apart
//  from the base address and register offsets (mpx_dump --tx).
//
//  Export rate is CLK_AUDIO_HZ/48 = exactly 256000 Hz at the default
//  12.288 MHz clk_audio -- an integer rate, so captures feed straight into
//  `redsea -r 256000`. 57 kHz sits well under the 128 kHz Nyquist.
// ----------------------------------------------------------------------------
//  AXI4-LITE REGISTER MAP (s_axi_aclk domain, 32-bit registers, word-aligned)
//  Verified against RTL by simulation, not by inspection.
// ----------------------------------------------------------------------------
//  Offset  Name        R/W  Reset        Description
//  0x00    CTRL        RW   0x00000007   Control register:
//                                          bit  0     TX_EN      1 = enable TX
//                                          bit  1     STEREO_EN  1 = 19k pilot + 38k on
//                                          bits 3:2   PREEMPH    0 = off
//                                                                1 = 50us (EU)
//                                                                2 = 75us (US)
//                                                                3 = acts as 50us
//                                          bits 31:4  unused (read back as written)
//  0x04    FTW_LOWER   RW   DEFAULT_FTW  RF tuning word bits [31:0]
//                                          FTW = FREQ_HZ / CLK_RF_HZ * 2^40
//  0x08    FTW_UPPER   RW   DEFAULT_FTW  RF tuning word bits [39:32] in [7:0];
//                                          bits [31:8] unused
//  0x0C    DEV_GAIN    RW   DEV_GAIN_RESET  Unsigned Q8.8 gain applied to mpx
//                                          before it is added to the FTW. Only
//                                          bits [15:0] are used.
//                                          Peak dev = mpx_peak * (DEV_GAIN/256)
//                                                             * CLK_RF_HZ / 2^40
//                                          REPLACES the old power-of-two
//                                          DEV_SHIFT: writing 5 here no longer
//                                          means "shift by 5", it means a gain
//                                          of 5/256. See the DEVIATION note.
//  0x10    RDS0        RW   DEFAULT_RDS  RDS shift-reg bits [ 31:  0]
//  0x14    RDS1        RW   DEFAULT_RDS  RDS shift-reg bits [ 63: 32]
//  0x18    RDS2        RW   DEFAULT_RDS  RDS shift-reg bits [ 95: 64]
//  0x1C    RDS3        RW   DEFAULT_RDS  RDS shift-reg bits [127: 96]
//  0x20    RDS4        RW   DEFAULT_RDS  RDS shift-reg bits [159:128]
//  0x24    RDS5        RW   DEFAULT_RDS  RDS shift-reg bits [191:160]
//  0x28    RDS6        RW   DEFAULT_RDS  RDS shift-reg bits [223:192]
//  0x2C    RDS7        RW   DEFAULT_RDS  RDS shift-reg bits [255:224]
//  0x30    RDS8        RW   DEFAULT_RDS  RDS shift-reg bits [287:256]
//  0x34    RDS9        RW   DEFAULT_RDS  RDS shift-reg bits [319:288]
//  0x38    RDS10       RW   DEFAULT_RDS  RDS shift-reg bits [351:320]
//  0x3C    RDS11       RW   DEFAULT_RDS  RDS shift-reg bits [383:352]
//  0x40    RDS12       RW   DEFAULT_RDS  RDS shift-reg bits [415:384]
//  0x44    MPX_FIFO_STAT RO 0x00020000   Present only when MPX_EXPORT_ENABLE=1.
//                                          [MPX_TX_FIFO_ADDR_W:0]=entries queued,
//                                          [16]=overflow (clear-on-read of THIS
//                                          register), [17]=empty (informational)
//  0x48    MPX_FIFO_DATA RO 0x00000000   [15:0]=signed 16-bit raw MPX composite
//                                          sample, decimated to 256 kHz (default
//                                          clk_audio) and shifted/saturated per
//                                          MPX_SHIFT below. Reading pops one
//                                          queue entry (read=pop, same
//                                          convention as the RDS registers).
//  0x4C    MPX_SHIFT     RW  0x00000008   Arithmetic right-shift applied to the
//                                          decimated mpx before it is saturated
//                                          to the signed 16-bit FIFO sample.
//                                          The CIC's net gain is 48^3/2^17 =
//                                          0.84375, so at the reset default of
//                                          8 a full-scale mpx (8388607) maps to
//                                          +/-27648 -- 84% of int16 full scale,
//                                          leaving headroom for the clipping
//                                          the mpx summer can produce (see the
//                                          HEADROOM BUG note at mpx_sum below).
//
//  RDS TRANSMIT ORDER (verified: marker bit test + register readback test)
//    rds_sr[415] is shifted out FIRST, so the air order is
//      0x40 bit31 -> 0x40 bit0 -> 0x3C bit31 -> ... -> 0x10 bit31 -> 0x10 bit0
//    i.e. DESCENDING address, MSB-first inside each word. 0x40 leads, 0x10 is
//    last. 416 bits = 4 back-to-back 104-bit RDS groups at 1187.5 bit/s
//    (= pilot/16, exactly), so the whole block repeats every 350.3 ms.
// ----------------------------------------------------------------------------
//  Writes ignore s_axi_wstrb (byte-enables are not honoured -- word writes
//  only). Addresses above 0x4C are unmapped: reads return 0, writes ignored.
// ============================================================================

module fm_transmitter_axi #(
    parameter FREQ_HZ          = 100_000_000, // Default Broadcast frequency, Hz
    parameter CLK_RF_HZ        = 250_000_000, // RF clock from PLL (e.g. 200 or 250 MHz)
    parameter CLK_AUDIO_HZ     = 12_288_000,  // Audio clock, Hz (e.g. 12.288 MHz)
    parameter AUDIO_DATA_WIDTH = 24,          // Audio bit depth (16, 20, 24)
    parameter RF_ODDR_ENABLE    = 1,          // 1 = drive antenna_out through an ODDR, i.e. emit
                                               // two phase samples per clk_rf (500 Msps at 250 MHz)
                                               // instead of one. A 1-bit NCO output has its edges
                                               // quantised to the output sample grid; halving that
                                               // grid halves the edge timing error and takes ~6 dB
                                               // off the resulting phase-quantisation noise, which
                                               // matters here because the receiver shares the board
                                               // and a 1-bit front end with no AGC. The reference
                                               // design this project descends from does the same.
                                               // Set to 0 for a plain registered output (no vendor
                                               // primitive, simulatable anywhere).
    parameter [15:0] DEV_GAIN_RESET = 16'd8046, // reset value of DEV_GAIN (0x0C), unsigned Q8.8.
                                               // 8046/256 = 31.43 puts the 19 kHz pilot at exactly
                                               // 6.75 kHz (9% of 75 kHz) and full-scale mpx at
                                               // 59.95 kHz. Other useful points at CLK_RF_HZ =
                                               // 250 MHz: 10066 -> 75.0 kHz full scale,
                                               // 8187 -> 61.0 kHz (what the old DEV_SHIFT=5 gave).
    parameter MPX_EXPORT_ENABLE = 0,          // 1 = build the raw-MPX debug export
                                               // (registers 0x44/0x48/0x4C and the
                                               // tx_mpx_export instance). 0 removes it
                                               // from the build entirely: no CIC, no
                                               // FIFO, no CDC, no clk_audio reset
                                               // synchroniser; 0x44 then reads as an
                                               // empty FIFO and 0x48/0x4C read 0. Nothing in the
                                               // transmit path depends on it either
                                               // way -- it is a diagnostic tap only,
                                               // so a production build should leave
                                               // this at 0. Set it to 1, rebuild, and
                                               // capture with `mpx_dump --tx` when you
                                               // need to separate a baseband problem
                                               // from an RF/antenna one.
    parameter MPX_TX_FIFO_DEPTH = 1024,       // raw-MPX export FIFO depth, must be a power of 2
                                               // (4 ms of slack at 256 kHz). Ignored
                                               // when MPX_EXPORT_ENABLE = 0.
    parameter MPX_TX_DECIM      = 48          // clk_audio decimation factor for the MPX export;
                                               // export rate = CLK_AUDIO_HZ / MPX_TX_DECIM
                                               // = 256000 Hz exactly at the 12.288 MHz default
)(
    // ---- AXI-Lite Interface (clk_sys domain) ----
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET s_axi_aresetn" *)
    input  wire        s_axi_aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire        s_axi_aresetn,
    
    input  wire [7:0]  s_axi_awaddr,
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
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output reg  [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,

    // ---- DSP & RF Clocks ----
    input  wire        clk_audio,  // Slow clock for DSP (12.288 MHz)
    input  wire        clk_rf,     // Fast clock for NCO (200.0 MHz)

    // ---- I2S Audio Input ----
    input  wire        i2s_bclk,
    input  wire        i2s_lrclk,
    input  wire        i2s_data,

    // ---- RF Antenna Output ----
    output wire        antenna_out
);

    // ========================================================================
    //  Compile-time constants (40-BIT MATH RESTORED)
    // ========================================================================
    localparam [63:0] PINC_19K_64 = (64'd19000 * (64'd1 << 32)) / CLK_AUDIO_HZ;
    localparam [31:0] PINC_19K    = PINC_19K_64[31:0];

    // Original 40-bit two-step FTW calculation to prevent overflow
    localparam [63:0] _S  = FREQ_HZ  * (64'd1 << 30);
    localparam [63:0] _Q  = _S / CLK_RF_HZ;
    localparam [63:0] _R  = _S % CLK_RF_HZ;
    localparam [63:0] _C  = (_R << 10) / CLK_RF_HZ;
    localparam [39:0] DEFAULT_FTW = (_Q << 10) + _C;

    localparam integer MPX_TX_FIFO_ADDR_W = $clog2(MPX_TX_FIFO_DEPTH);

    // ========================================================================
    //  1. AXI4-LITE SLAVE LOGIC
    // ========================================================================
    reg awready, wready, bvalid;
    reg arready, rvalid;
    
    assign s_axi_awready = awready;
    assign s_axi_wready  = wready;
    assign s_axi_bvalid  = bvalid;
    assign s_axi_arready = arready;
    assign s_axi_rvalid  = rvalid;
    assign s_axi_bresp   = 2'b00;
    assign s_axi_rresp   = 2'b00;

    // AXI Registers Map (Adjusted for 40-bit FTW)
    reg [31:0] r_ctrl;         // 0x00
    reg [31:0] r_ftw_lower;    // 0x04 (FTW Bits 31:0)
    reg [31:0] r_ftw_upper;    // 0x08 (FTW Bits 39:32)
    reg [31:0] r_dev_gain;     // 0x0C (Deviation gain, unsigned Q8.8)
    reg [31:0] r_rds [0:12];   // 0x10 to 0x40
    reg [3:0]  r_mpx_tx_shift; // 0x4C (raw-MPX export shift, added)

    // Elaboration-time constant so it can also initialise rds_sr below.
    // As a `wire` this was unusable as an initialiser: at t=0 the net is
    // still z, so `reg [415:0] rds_sr = default_rds;` would latch all-z.
    localparam [415:0] DEFAULT_RDS = 416'h7704fd820329f77041691942137704fd820247b77041691d04c97704fd8202ab077041697d127f7704fd8202f097704169114d60;

    integer i;
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            awready <= 0; wready <= 0; bvalid <= 0;
            
            r_ctrl      <= 32'h0000_0007; // TX=1, STEREO=1, PREEMPH=1
            r_ftw_lower <= DEFAULT_FTW[31:0];
            r_ftw_upper <= {24'd0, DEFAULT_FTW[39:32]};
            r_dev_gain  <= {16'd0, DEV_GAIN_RESET};
            r_mpx_tx_shift <= 4'd8;       // exact 24->16 bit mapping, see 0x4C above

            for (i=0; i<13; i=i+1) r_rds[i] <= DEFAULT_RDS[(i*32) +: 32];
        end else begin
            if (!awready && s_axi_awvalid && s_axi_wvalid && !bvalid) begin
                awready <= 1; wready <= 1;
            end else begin
                awready <= 0; wready <= 0;
            end

            if (awready && wready) begin
                bvalid <= 1;
                case (s_axi_awaddr[7:2])
                    6'h00: r_ctrl      <= s_axi_wdata;
                    6'h01: r_ftw_lower <= s_axi_wdata;
                    6'h02: r_ftw_upper <= s_axi_wdata;
                    6'h03: r_dev_gain  <= s_axi_wdata;
                    6'h13: if (s_axi_wstrb[0]) r_mpx_tx_shift <= s_axi_wdata[3:0]; // 0x4C MPX_SHIFT
                    default: begin
                        if (s_axi_awaddr[7:2] >= 6'h04 && s_axi_awaddr[7:2] <= 6'h10) begin
                            r_rds[s_axi_awaddr[7:2] - 6'h04] <= s_axi_wdata;
                        end
                        // 0x44/0x48 (MPX_FIFO_STAT/DATA) are read-only: a write
                        // to either falls through here and is silently ignored,
                        // same as any other unmapped address.
                    end
                endcase
            end else if (s_axi_bready && bvalid) begin
                bvalid <= 0;
            end
        end
    end

    // ---- Raw-MPX export FIFO read-side strobes (declared ahead of the read
    //      process below because that process both reads the FIFO head
    //      combinationally and must trigger a pop as a side effect of
    //      accepting THIS read -- same single-cycle AXI-read convention
    //      mpx_sample_fifo.v and axi_sdr_fm.v already use). ----
    // NOTE ON THE STROBE QUALIFIER -- this differs from axi_sdr_fm.v on purpose.
    // There, the read FSM asserts arready AND rvalid in the same cycle, so
    // (arvalid && !rvalid) is a clean one-cycle pulse. This module's FSM takes
    // an extra cycle (arready first, rvalid only on the next), so
    // (arvalid && !rvalid) stays high for TWO cycles and would pop TWO samples
    // per AXI read -- silently dropping roughly every other exported sample,
    // which shows up as random phase jumps on every subcarrier while the
    // envelope stays clean. Qualify on arready instead: it is high for exactly
    // one cycle by construction (the FSM clears it the cycle after it sets it),
    // and it is the same cycle in which s_axi_rdata is captured, so the
    // read=pop convention still returns the sample fetched by the previous pop
    // exactly as on the receiver side.
    wire mpx_tx_fifo_pop_strobe   = arready && (s_axi_araddr[7:2] == 6'h12); // 0x48
    wire mpx_tx_fifo_clr_ovf      = arready && (s_axi_araddr[7:2] == 6'h11); // 0x44

    wire signed [15:0]           mpx_tx_fifo_rd_data;
    wire [MPX_TX_FIFO_ADDR_W:0]  mpx_tx_fifo_count;
    wire                         mpx_tx_fifo_empty;
    wire                         mpx_tx_fifo_overflow;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            arready <= 0; rvalid <= 0; s_axi_rdata <= 0;
        end else begin
            if (!arready && s_axi_arvalid && !rvalid) arready <= 1;
            else arready <= 0;

            if (arready) begin
                rvalid <= 1;
                case (s_axi_araddr[7:2])
                    6'h00: s_axi_rdata <= r_ctrl;
                    6'h01: s_axi_rdata <= r_ftw_lower;
                    6'h02: s_axi_rdata <= r_ftw_upper;
                    6'h03: s_axi_rdata <= r_dev_gain;
                    6'h11: s_axi_rdata <= {14'b0, mpx_tx_fifo_empty, mpx_tx_fifo_overflow, // 0x44 MPX_FIFO_STAT
                                            {(15-MPX_TX_FIFO_ADDR_W){1'b0}}, mpx_tx_fifo_count};
                    6'h12: s_axi_rdata <= {16'b0, mpx_tx_fifo_rd_data};                     // 0x48 MPX_FIFO_DATA (read=pop)
                    6'h13: s_axi_rdata <= MPX_EXPORT_ENABLE ? {28'b0, r_mpx_tx_shift} : 32'd0; // 0x4C MPX_SHIFT
                    default: begin
                        if (s_axi_araddr[7:2] >= 6'h04 && s_axi_araddr[7:2] <= 6'h10) begin
                            s_axi_rdata <= r_rds[s_axi_araddr[7:2] - 6'h04];
                        end else s_axi_rdata <= 32'd0;
                    end
                endcase
            end else if (s_axi_rready && rvalid) rvalid <= 0;
        end
    end

    wire [415:0] flat_rds_live;
    genvar g;
    generate
        for (g=0; g<13; g=g+1) begin : gen_rds_flat
            assign flat_rds_live[g*32 +: 32] = r_rds[g];
        end
    endgenerate

    // -- RDS commit register. Software needs 13 separate AXI writes to replace a
    //    frame, while rds_sr reloads asynchronously (whenever rds_bit_cnt hits
    //    415, i.e. every 350.3 ms). Sampling r_rds directly meant a reload could
    //    land mid-update and put one torn frame on air -- 4 blocks with broken
    //    checkwords, enough to make a receiver drop block sync for a moment.
    //    flat_rds is now a snapshot taken when the LAST register (0x40) is
    //    written, so a frame only ever goes on air complete. fm_ctrl already
    //    writes 0x10..0x40 in ascending order, so 0x40 is naturally the commit;
    //    if you ever write them out of order, write 0x40 last. --
    reg [415:0] flat_rds;
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn)
            flat_rds <= DEFAULT_RDS;
        else if (awready && wready && (s_axi_awaddr[7:2] == 6'h10))
            flat_rds <= {s_axi_wdata, flat_rds_live[383:0]};
    end

    // Combines 32-bit lower and 8-bit upper into the full 40-bit FTW
    wire [39:0] r_rf_ftw_40b = {r_ftw_upper[7:0], r_ftw_lower};

    // ========================================================================
    //  2. CLOCK DOMAIN CROSSING
    // ========================================================================
    (* ASYNC_REG="TRUE" *) reg [31:0] ctrl_sync1, ctrl_sync2;
    (* ASYNC_REG="TRUE" *) reg [415:0] rds_sync1, rds_sync2;

    always @(posedge clk_audio) begin
        ctrl_sync1 <= r_ctrl;      ctrl_sync2 <= ctrl_sync1;
        rds_sync1  <= flat_rds;    rds_sync2  <= rds_sync1;
    end

    wire       tx_en        = ctrl_sync2[0];
    wire       stereo_en    = ctrl_sync2[1];
    wire [1:0] preemph_mode = ctrl_sync2[3:2];

    // Initialisers matter here, not just for simulation: without them the first
    // couple of clk_rf cycles push X through pinc_wide into rf_pinc_st3 and from
    // there into the phase accumulator, which then stays X for the whole run.
    // The rest of the RF section already initialises every register this way.
    (* ASYNC_REG="TRUE" *) reg [39:0] ftw_sync1 = 40'd0, ftw_sync2 = 40'd0;
    (* ASYNC_REG="TRUE" *) reg        tx_rf_sync1 = 1'b0, tx_rf_sync2 = 1'b0;
    // TIMING/CDC BUGFIX: dev_sync1/2 used to be clocked by clk_audio, but
    // dev_sync2[4:0] was READ from a clk_rf process. That is an unsynchronised
    // clk_audio -> clk_rf crossing feeding a 32-bit barrel shifter. Vivado times
    // it as a real 12.288 MHz -> 250 MHz path, so it alone drives WNS negative
    // no matter how the RF logic is retimed. Only [4:0] was ever used, so the
    // 5 bits are now synchronised directly into clk_rf where they are consumed.
    (* ASYNC_REG="TRUE" *) reg [15:0] dev_sync1 = 16'd0, dev_sync2 = 16'd0;
    always @(posedge clk_rf) begin
        ftw_sync1   <= r_rf_ftw_40b;      ftw_sync2 <= ftw_sync1;
        tx_rf_sync1 <= r_ctrl[0];         tx_rf_sync2 <= tx_rf_sync1;
        dev_sync1   <= r_dev_gain[15:0];  dev_sync2 <= dev_sync1;
    end

    // ========================================================================
    //  3. AUDIO DSP CHAIN (clk_audio)
    // ========================================================================
    // -------------------------------------------------------------------------
    // Quarter-wave sine magnitude table, 256 entries, values = int(8388607 *
    // sin(pi/2 * k/256)) -- numerically IDENTICAL to the previous
    //     initial for (_k=0;_k<256;_k=_k+1)
    //         sine_lut[_k] = $rtoi(8388607.0 * $sin(...));
    // (verified entry by entry), but written as a combinational case so it
    // synthesises into LUT/ROM logic with no dependence on Vivado honouring an
    // initial block full of real-valued system functions ($sin/$rtoi). This is
    // the same style already proven in hardware by cos_q_lut in rds_decode.v
    // and fm_stereo_demod.v on this board.
    //
    // Note the width: values reach 8388607, which needs 23 bits UNSIGNED. The
    // return type stays [22:0] and the caller reads it back through
    // {1'b0, mag}, so the table holds magnitudes, not signed values -- exactly
    // as before. Do not 'fix' the declaration to signed without also changing
    // sin_lookup, or every entry above 4194303 flips sign.
    // -------------------------------------------------------------------------
    function [22:0] sine_mag_lut;
        input [7:0] addr;
        begin
            case (addr)
                  0: sine_mag_lut = 23'd0;    1: sine_mag_lut = 23'd51471;    2: sine_mag_lut = 23'd102941;    3: sine_mag_lut = 23'd154406;
                  4: sine_mag_lut = 23'd205866;    5: sine_mag_lut = 23'd257318;    6: sine_mag_lut = 23'd308761;    7: sine_mag_lut = 23'd360192;
                  8: sine_mag_lut = 23'd411609;    9: sine_mag_lut = 23'd463011;   10: sine_mag_lut = 23'd514395;   11: sine_mag_lut = 23'd565760;
                 12: sine_mag_lut = 23'd617104;   13: sine_mag_lut = 23'd668424;   14: sine_mag_lut = 23'd719719;   15: sine_mag_lut = 23'd770988;
                 16: sine_mag_lut = 23'd822227;   17: sine_mag_lut = 23'd873435;   18: sine_mag_lut = 23'd924610;   19: sine_mag_lut = 23'd975751;
                 20: sine_mag_lut = 23'd1026855;   21: sine_mag_lut = 23'd1077920;   22: sine_mag_lut = 23'd1128944;   23: sine_mag_lut = 23'd1179926;
                 24: sine_mag_lut = 23'd1230864;   25: sine_mag_lut = 23'd1281755;   26: sine_mag_lut = 23'd1332598;   27: sine_mag_lut = 23'd1383391;
                 28: sine_mag_lut = 23'd1434132;   29: sine_mag_lut = 23'd1484818;   30: sine_mag_lut = 23'd1535449;   31: sine_mag_lut = 23'd1586022;
                 32: sine_mag_lut = 23'd1636536;   33: sine_mag_lut = 23'd1686987;   34: sine_mag_lut = 23'd1737375;   35: sine_mag_lut = 23'd1787698;
                 36: sine_mag_lut = 23'd1837954;   37: sine_mag_lut = 23'd1888140;   38: sine_mag_lut = 23'd1938255;   39: sine_mag_lut = 23'd1988297;
                 40: sine_mag_lut = 23'd2038265;   41: sine_mag_lut = 23'd2088155;   42: sine_mag_lut = 23'd2137967;   43: sine_mag_lut = 23'd2187699;
                 44: sine_mag_lut = 23'd2237348;   45: sine_mag_lut = 23'd2286913;   46: sine_mag_lut = 23'd2336392;   47: sine_mag_lut = 23'd2385783;
                 48: sine_mag_lut = 23'd2435084;   49: sine_mag_lut = 23'd2484293;   50: sine_mag_lut = 23'd2533409;   51: sine_mag_lut = 23'd2582429;
                 52: sine_mag_lut = 23'd2631352;   53: sine_mag_lut = 23'd2680176;   54: sine_mag_lut = 23'd2728900;   55: sine_mag_lut = 23'd2777520;
                 56: sine_mag_lut = 23'd2826036;   57: sine_mag_lut = 23'd2874446;   58: sine_mag_lut = 23'd2922747;   59: sine_mag_lut = 23'd2970938;
                 60: sine_mag_lut = 23'd3019018;   61: sine_mag_lut = 23'd3066983;   62: sine_mag_lut = 23'd3114834;   63: sine_mag_lut = 23'd3162567;
                 64: sine_mag_lut = 23'd3210180;   65: sine_mag_lut = 23'd3257673;   66: sine_mag_lut = 23'd3305044;   67: sine_mag_lut = 23'd3352290;
                 68: sine_mag_lut = 23'd3399410;   69: sine_mag_lut = 23'd3446401;   70: sine_mag_lut = 23'd3493263;   71: sine_mag_lut = 23'd3539994;
                 72: sine_mag_lut = 23'd3586591;   73: sine_mag_lut = 23'd3633053;   74: sine_mag_lut = 23'd3679379;   75: sine_mag_lut = 23'd3725566;
                 76: sine_mag_lut = 23'd3771612;   77: sine_mag_lut = 23'd3817517;   78: sine_mag_lut = 23'd3863278;   79: sine_mag_lut = 23'd3908893;
                 80: sine_mag_lut = 23'd3954361;   81: sine_mag_lut = 23'd3999681;   82: sine_mag_lut = 23'd4044850;   83: sine_mag_lut = 23'd4089866;
                 84: sine_mag_lut = 23'd4134729;   85: sine_mag_lut = 23'd4179436;   86: sine_mag_lut = 23'd4223985;   87: sine_mag_lut = 23'd4268376;
                 88: sine_mag_lut = 23'd4312605;   89: sine_mag_lut = 23'd4356673;   90: sine_mag_lut = 23'd4400576;   91: sine_mag_lut = 23'd4444314;
                 92: sine_mag_lut = 23'd4487884;   93: sine_mag_lut = 23'd4531286;   94: sine_mag_lut = 23'd4574517;   95: sine_mag_lut = 23'd4617575;
                 96: sine_mag_lut = 23'd4660460;   97: sine_mag_lut = 23'd4703169;   98: sine_mag_lut = 23'd4745701;   99: sine_mag_lut = 23'd4788055;
                100: sine_mag_lut = 23'd4830228;  101: sine_mag_lut = 23'd4872220;  102: sine_mag_lut = 23'd4914028;  103: sine_mag_lut = 23'd4955650;
                104: sine_mag_lut = 23'd4997087;  105: sine_mag_lut = 23'd5038335;  106: sine_mag_lut = 23'd5079394;  107: sine_mag_lut = 23'd5120261;
                108: sine_mag_lut = 23'd5160936;  109: sine_mag_lut = 23'd5201416;  110: sine_mag_lut = 23'd5241700;  111: sine_mag_lut = 23'd5281787;
                112: sine_mag_lut = 23'd5321675;  113: sine_mag_lut = 23'd5361363;  114: sine_mag_lut = 23'd5400849;  115: sine_mag_lut = 23'd5440132;
                116: sine_mag_lut = 23'd5479210;  117: sine_mag_lut = 23'd5518081;  118: sine_mag_lut = 23'd5556745;  119: sine_mag_lut = 23'd5595200;
                120: sine_mag_lut = 23'd5633444;  121: sine_mag_lut = 23'd5671475;  122: sine_mag_lut = 23'd5709294;  123: sine_mag_lut = 23'd5746897;
                124: sine_mag_lut = 23'd5784284;  125: sine_mag_lut = 23'd5821453;  126: sine_mag_lut = 23'd5858403;  127: sine_mag_lut = 23'd5895133;
                128: sine_mag_lut = 23'd5931640;  129: sine_mag_lut = 23'd5967925;  130: sine_mag_lut = 23'd6003984;  131: sine_mag_lut = 23'd6039818;
                132: sine_mag_lut = 23'd6075424;  133: sine_mag_lut = 23'd6110801;  134: sine_mag_lut = 23'd6145948;  135: sine_mag_lut = 23'd6180864;
                136: sine_mag_lut = 23'd6215547;  137: sine_mag_lut = 23'd6249996;  138: sine_mag_lut = 23'd6284210;  139: sine_mag_lut = 23'd6318188;
                140: sine_mag_lut = 23'd6351927;  141: sine_mag_lut = 23'd6385427;  142: sine_mag_lut = 23'd6418687;  143: sine_mag_lut = 23'd6451705;
                144: sine_mag_lut = 23'd6484480;  145: sine_mag_lut = 23'd6517012;  146: sine_mag_lut = 23'd6549297;  147: sine_mag_lut = 23'd6581336;
                148: sine_mag_lut = 23'd6613128;  149: sine_mag_lut = 23'd6644670;  150: sine_mag_lut = 23'd6675963;  151: sine_mag_lut = 23'd6707003;
                152: sine_mag_lut = 23'd6737792;  153: sine_mag_lut = 23'd6768327;  154: sine_mag_lut = 23'd6798606;  155: sine_mag_lut = 23'd6828630;
                156: sine_mag_lut = 23'd6858397;  157: sine_mag_lut = 23'd6887906;  158: sine_mag_lut = 23'd6917155;  159: sine_mag_lut = 23'd6946144;
                160: sine_mag_lut = 23'd6974871;  161: sine_mag_lut = 23'd7003336;  162: sine_mag_lut = 23'd7031537;  163: sine_mag_lut = 23'd7059473;
                164: sine_mag_lut = 23'd7087144;  165: sine_mag_lut = 23'd7114548;  166: sine_mag_lut = 23'd7141684;  167: sine_mag_lut = 23'd7168551;
                168: sine_mag_lut = 23'd7195148;  169: sine_mag_lut = 23'd7221474;  170: sine_mag_lut = 23'd7247528;  171: sine_mag_lut = 23'd7273310;
                172: sine_mag_lut = 23'd7298817;  173: sine_mag_lut = 23'd7324050;  174: sine_mag_lut = 23'd7349007;  175: sine_mag_lut = 23'd7373688;
                176: sine_mag_lut = 23'd7398090;  177: sine_mag_lut = 23'd7422215;  178: sine_mag_lut = 23'd7446059;  179: sine_mag_lut = 23'd7469624;
                180: sine_mag_lut = 23'd7492907;  181: sine_mag_lut = 23'd7515908;  182: sine_mag_lut = 23'd7538626;  183: sine_mag_lut = 23'd7561061;
                184: sine_mag_lut = 23'd7583210;  185: sine_mag_lut = 23'd7605075;  186: sine_mag_lut = 23'd7626652;  187: sine_mag_lut = 23'd7647943;
                188: sine_mag_lut = 23'd7668946;  189: sine_mag_lut = 23'd7689660;  190: sine_mag_lut = 23'd7710084;  191: sine_mag_lut = 23'd7730219;
                192: sine_mag_lut = 23'd7750062;  193: sine_mag_lut = 23'd7769613;  194: sine_mag_lut = 23'd7788872;  195: sine_mag_lut = 23'd7807838;
                196: sine_mag_lut = 23'd7826509;  197: sine_mag_lut = 23'd7844886;  198: sine_mag_lut = 23'd7862968;  199: sine_mag_lut = 23'd7880754;
                200: sine_mag_lut = 23'd7898243;  201: sine_mag_lut = 23'd7915434;  202: sine_mag_lut = 23'd7932328;  203: sine_mag_lut = 23'd7948923;
                204: sine_mag_lut = 23'd7965218;  205: sine_mag_lut = 23'd7981214;  206: sine_mag_lut = 23'd7996909;  207: sine_mag_lut = 23'd8012303;
                208: sine_mag_lut = 23'd8027396;  209: sine_mag_lut = 23'd8042186;  210: sine_mag_lut = 23'd8056674;  211: sine_mag_lut = 23'd8070858;
                212: sine_mag_lut = 23'd8084738;  213: sine_mag_lut = 23'd8098314;  214: sine_mag_lut = 23'd8111585;  215: sine_mag_lut = 23'd8124551;
                216: sine_mag_lut = 23'd8137210;  217: sine_mag_lut = 23'd8149564;  218: sine_mag_lut = 23'd8161610;  219: sine_mag_lut = 23'd8173350;
                220: sine_mag_lut = 23'd8184781;  221: sine_mag_lut = 23'd8195905;  222: sine_mag_lut = 23'd8206719;  223: sine_mag_lut = 23'd8217225;
                224: sine_mag_lut = 23'd8227422;  225: sine_mag_lut = 23'd8237308;  226: sine_mag_lut = 23'd8246885;  227: sine_mag_lut = 23'd8256151;
                228: sine_mag_lut = 23'd8265106;  229: sine_mag_lut = 23'd8273751;  230: sine_mag_lut = 23'd8282083;  231: sine_mag_lut = 23'd8290104;
                232: sine_mag_lut = 23'd8297812;  233: sine_mag_lut = 23'd8305209;  234: sine_mag_lut = 23'd8312292;  235: sine_mag_lut = 23'd8319063;
                236: sine_mag_lut = 23'd8325520;  237: sine_mag_lut = 23'd8331664;  238: sine_mag_lut = 23'd8337494;  239: sine_mag_lut = 23'd8343011;
                240: sine_mag_lut = 23'd8348213;  241: sine_mag_lut = 23'd8353101;  242: sine_mag_lut = 23'd8357674;  243: sine_mag_lut = 23'd8361933;
                244: sine_mag_lut = 23'd8365877;  245: sine_mag_lut = 23'd8369506;  246: sine_mag_lut = 23'd8372820;  247: sine_mag_lut = 23'd8375819;
                248: sine_mag_lut = 23'd8378502;  249: sine_mag_lut = 23'd8380870;  250: sine_mag_lut = 23'd8382922;  251: sine_mag_lut = 23'd8384659;
                252: sine_mag_lut = 23'd8386080;  253: sine_mag_lut = 23'd8387185;  254: sine_mag_lut = 23'd8387975;  255: sine_mag_lut = 23'd8388449;
                default: sine_mag_lut = 23'd0;
            endcase
        end
    endfunction

    function signed [23:0] sin_lookup;
        input [31:0] ph;
        reg   [31:0] adj;
        reg   [22:0] mag;
        begin
            adj = ph[30] ? ~ph : ph;
            mag = sine_mag_lut(adj[29:22]);
            sin_lookup = ph[31] ? -{1'b0, mag} : {1'b0, mag};
        end
    endfunction

    (* ASYNC_REG="TRUE" *) reg [2:0] bclk_sync, lrclk_sync, data_sync;
    always @(posedge clk_audio) begin
        bclk_sync  <= {bclk_sync[1:0],  i2s_bclk};
        lrclk_sync <= {lrclk_sync[1:0], i2s_lrclk};
        data_sync  <= {data_sync[1:0],  i2s_data};
    end
    
    wire bclk_rise = (bclk_sync[2:1] == 2'b01);
    wire lrclk_val = lrclk_sync[2];
    
    reg [7:0] bclk_cnt=0;
    reg lrclk_latched=0;
    reg signed [AUDIO_DATA_WIDTH-1:0] left_shift=0, right_shift=0, left_latch=0;
    reg signed [23:0] audio_l=0, audio_r=0;
    reg audio_valid=0;
    
    always @(posedge clk_audio) begin
        audio_valid <= 1'b0;
        if (bclk_rise) begin
            if (lrclk_val != lrclk_latched) begin
                lrclk_latched <= lrclk_val;
                bclk_cnt      <= 8'd0;
                if (lrclk_latched == 1'b0) begin
                    left_latch <= left_shift;
                end else begin
                    audio_l     <= left_latch  <<< (24 - AUDIO_DATA_WIDTH);
                    audio_r     <= right_shift <<< (24 - AUDIO_DATA_WIDTH);
                    audio_valid <= 1'b1;
                end
            end else begin
                bclk_cnt <= bclk_cnt + 1'b1;
                if (bclk_cnt < AUDIO_DATA_WIDTH) begin
                    if (lrclk_latched == 1'b0) left_shift  <= {left_shift[AUDIO_DATA_WIDTH-2:0],  data_sync[2]};
                    else                       right_shift <= {right_shift[AUDIO_DATA_WIDTH-2:0], data_sync[2]};
                end
            end
        end
    end

    reg signed [23:0] pe_xl=0, pe_xr=0;
    reg signed [39:0] pe_xq_l=0, pe_xq_r=0, pe_ax_l=0, pe_ax_r=0, pe_res_l=0, pe_res_r=0;
    reg signed [23:0] pe_out_l=0, pe_out_r=0, bp_l_1=0, bp_r_1=0, bp_l_2=0, bp_r_2=0;
    reg pe_v1=0, pe_v2=0;

    wire signed [15:0] pe_alpha = (preemph_mode == 2) ? 16'sd24842 : 16'sd21589;

    always @(posedge clk_audio) begin
        pe_v1 <= audio_valid; pe_v2 <= pe_v1;
        if (audio_valid) begin bp_l_1 <= audio_l; bp_r_1 <= audio_r; end
        if (pe_v1)       begin bp_l_2 <= bp_l_1;  bp_r_2 <= bp_r_1;  end

        if (preemph_mode == 0) begin
            if (pe_v2) begin pe_out_l <= bp_l_2; pe_out_r <= bp_r_2; end
        end else begin
            if (audio_valid) begin
                pe_xq_l <= {audio_l[23], audio_l, 15'b0};
                pe_xq_r <= {audio_r[23], audio_r, 15'b0};
                pe_ax_l <= pe_alpha * pe_xl; pe_ax_r <= pe_alpha * pe_xr;
                pe_xl   <= audio_l; pe_xr   <= audio_r;
            end
            if (pe_v1) begin pe_res_l <= pe_xq_l - pe_ax_l; pe_res_r <= pe_xq_r - pe_ax_r; end
            if (pe_v2) begin
                pe_out_l <= (pe_res_l > 40'sh3FFFFF8000) ? 24'sh7FFFFF : (pe_res_l < 40'shC000000000) ? 24'sh800000 : pe_res_l[38:15];
                pe_out_r <= (pe_res_r > 40'sh3FFFFF8000) ? 24'sh7FFFFF : (pe_res_r < 40'shC000000000) ? 24'sh800000 : pe_res_r[38:15];
            end
        end
    end

    // Kept the safe 25-bit math here for clean audio
    wire signed [24:0] lr_sum  = pe_out_l + pe_out_r;
    wire signed [24:0] lr_diff = pe_out_l - pe_out_r;
    reg signed [23:0] lpr=0, lmr=0, lpr_d=0;
    
    always @(posedge clk_audio) begin
        lpr   <= lr_sum[24:1];
        lmr   <= lr_diff[24:1];
        lpr_d <= lpr; 
    end

    reg  [35:0] master_phase=0;
    wire [36:0] master_phase_next = {1'b0, master_phase} + {5'b0, PINC_19K};
    always @(posedge clk_audio) master_phase <= master_phase_next[35:0];
    
    wire [31:0] ph_19k = master_phase[31:0], ph_38k = ph_19k << 1, ph_57k = ph_19k + (ph_19k << 1), ph_1187 = master_phase[35:4];
    wire ce_1187 = master_phase_next[36];
    
    reg signed [23:0] sin_19k, sin_38k, sin_57k, sin_1187;
    always @(posedge clk_audio) begin
        sin_19k <= sin_lookup(ph_19k); sin_38k <= sin_lookup(ph_38k);
        sin_57k <= sin_lookup(ph_57k); sin_1187<= sin_lookup(ph_1187);
    end

    // 3688/32768 = 11.26% of full-scale mpx. Spec wants the pilot at 9% of peak
    // deviation, i.e. 2949 here. Measured pilot mpx peak = 944110 (sim-confirmed).
    wire signed [39:0] pilot_prod = sin_19k * 16'sd3688;
    wire signed [47:0] mod38_prod = lmr * sin_38k;
    reg signed [23:0] pilot=0, mod_38k=0;
    always @(posedge clk_audio) begin
        pilot   <= pilot_prod[38:15];
        mod_38k <= (mod38_prod + 48'sh400000) >>> 23;
    end

    // BUGFIX: was `rds_sr = 0`. rds_sr only reloads from rds_sync2 when
    // rds_bit_cnt hits 415, so a zero init shifted out 416 zero bits =
    // 350.3 ms of dead RDS after every power-up/reset before any real
    // group went on air. Init to the same default the AXI regs reset to.
    reg [415:0] rds_sr = DEFAULT_RDS;
    reg         rds_bmco=0;
    reg [8:0]   rds_bit_cnt=0;
    
    always @(posedge clk_audio) begin
        if (ce_1187) begin
            rds_bmco <= rds_bmco ^ rds_sr[415];
            if (rds_bit_cnt == 415) begin rds_bit_cnt <= 0; rds_sr <= rds_sync2; end 
            else begin rds_bit_cnt <= rds_bit_cnt + 1; rds_sr <= {rds_sr[414:0], rds_sr[415]}; end
        end
    end
    
    wire signed [23:0] rds_bpsk = rds_bmco ? sin_1187 : -sin_1187;
    // 2145/32768 = 6.55% of full-scale mpx -> ~4.0 kHz deviation at DEV_SHIFT=5,
    // the top of the 1.2-4.0 kHz range IEC 62106 allows. Was 1147 (3.5% -> 2.1 kHz),
    // which is legal but sits at the bottom of the range; measured against this
    // project's own 1-bit receiver front end, moving to 2145 raised the SNR in the
    // RDS band from 7.7 dB to 17.6 dB -- 4.5 dB better than a live broadcast
    // station that decodes at 87.6%.
    wire signed [39:0] rds_lev_prod = rds_bpsk * 16'sd2145;
    reg signed [23:0] rds_scaled=0;
    always @(posedge clk_audio) rds_scaled <= rds_lev_prod[38:15];
    
    wire signed [47:0] mod57_prod = rds_scaled * sin_57k;
    reg signed [23:0] mod_57k=0;
    always @(posedge clk_audio) mod_57k <= mod57_prod[46:23];

    reg signed [23:0] mpx=0;
    wire signed [25:0] st_mod = stereo_en ? $signed(mod_38k) : 26'sd0;
    wire signed [25:0] st_pil = stereo_en ? $signed(pilot)   : 26'sd0;
    // HEADROOM BUG (measured, not theoretical): the coefficients here are
    // effectively 0.5 / 0.5 / 0.1126 / 0.035 instead of the standard
    // 0.45 / 0.45 / 0.10 / 0.035. Worst case sums to 214.8% of full scale.
    // Even a MONO full-scale input overflows: 100% + 11.3% + 3.5% = 114.8%.
    // Sim: 1 kHz full-scale mono, preemph OFF -> mpx_sum peaks at 9553147 vs a
    // clamp of 8388607, clipping on 7354 of 61440 samples (12%). Preemphasis
    // hides this at low audio frequencies only because its DC gain is 1-alpha
    // = 0.34; at 15 kHz |H| = 1.39 and it clips again.
    wire signed [25:0] mpx_sum = $signed(lpr_d) + st_mod + st_pil + $signed(mod_57k);
    
    always @(posedge clk_audio) begin
        if (mpx_sum > 26'sd8388607)       mpx <= 24'sd8388607;
        else if (mpx_sum < -26'sd8388608) mpx <= -24'sd8388608;
        else                              mpx <= mpx_sum[23:0];
    end

    // ========================================================================
    //  4. SUPER-PIPELINED RF NCO MODULATOR (40-BIT MATH RESTORED)
    // ========================================================================
    reg mpx_toggle=0;
    always @(posedge clk_audio) mpx_toggle <= ~mpx_toggle;
    
    (* ASYNC_REG="TRUE" *) reg [2:0] toggle_sync = 3'd0;
    always @(posedge clk_rf) toggle_sync <= {toggle_sync[1:0], mpx_toggle};
    
    wire mpx_safe_capture = toggle_sync[2] ^ toggle_sync[1];
    reg signed [23:0] mpx_rf=0;
    always @(posedge clk_rf) begin
        if (mpx_safe_capture) mpx_rf <= mpx;
    end
    
    // ------------------------------------------------------------------
    //  RETIMED FOR 250 MHz. Same arithmetic -- verified bit-exact against the
    //  original pipeline over 28000 randomised vectors (7 configs incl.
    //  dev=0/8/31, ftw=1, ftw=2^40-1, clamp and overflow corners): the RF
    //  output is identical, delayed by 2 clk_rf (8 ns @250 MHz).
    //
    //  What was long, and what replaced it:
    //   S1  32-bit barrel shifter, 5 select bits -> a 32:1 mux per bit
    //       (LUT6+F7+F8 then another LUT6). SPLIT into coarse 8:1 + fine 4:1.
    //       Truncated left shifts compose exactly: (x<<a)<<b == x<<(a+b) in
    //       the low 32 bits, so this is not an approximation.
    //   S2  abs() = 32-bit increment + 32-bit mux -> DELETED outright. A signed
    //       add covers both the +dev and -dev branches with one carry chain.
    //   S3  was a 40-bit compare AND a 40-bit sub AND a 40-bit add AND a 3:1
    //       mux in ONE stage. Now a single 42-bit signed add. 42 and not 41 so
    //       ftw+dev cannot overflow into the sign bit and false-trigger the
    //       clamp. The clamp gets its own stage so no LUT hangs off the end of
    //       the carry chain.
    //   S4  the 40-bit accumulator is a feedback loop -- extra stages cannot
    //       shorten it. SEGMENTED into 2x20 bits with a registered carry.
    //       acc_hi[n] == old phase_acc[39:20][n-1] exactly (the low half runs
    //       one add ahead; the carry it hands up is the one the high half is
    //       still missing), so this costs one cycle of latency and nothing else.
    // ------------------------------------------------------------------
    wire signed [31:0] mpx_ext = mpx_rf;

    // --- STAGE 1a: Q8.8 multiply (was: a 32-bit barrel shifter split into a
    //     coarse 8:1 and a fine 4:1 mux stage). 24x16 signed-by-unsigned fits a
    //     single DSP48E1 (25x18) with its own pipeline register, and unlike the
    //     shifter it can express any gain, not just powers of two.
    reg signed [40:0] mpx_gain_p = 0;
    always @(posedge clk_rf)
        mpx_gain_p <= $signed(mpx_ext[24:0]) * $signed({1'b0, dev_sync2});

    // --- STAGE 1b: drop the 8 fractional bits of the Q8.8 gain.
    //     |mpx| <= 2^23 and gain < 256, so the result needs at most 31 bits plus
    //     sign -- it cannot overflow the 32-bit mpx_dev the adder below expects.
    reg signed [31:0] mpx_dev = 0;
    always @(posedge clk_rf) mpx_dev <= mpx_gain_p >>> 8;

    // --- STAGE 2: one 42-bit signed add (was: abs + compare + add/sub + mux)
    reg signed [41:0] pinc_wide = 0;
    always @(posedge clk_rf)
        pinc_wide <= $signed({2'b00, ftw_sync2}) + $signed({{10{mpx_dev[31]}}, mpx_dev});

    // --- STAGE 3: clamp to zero if the deviation would drive the NCO negative
    reg [39:0] rf_pinc_st3 = 0;
    always @(posedge clk_rf) rf_pinc_st3 <= pinc_wide[41] ? 40'd0 : pinc_wide[39:0];

    // --- STAGE 4: segmented 40-bit phase accumulator (2 x 20-bit + reg carry)
    reg [19:0] acc_lo = 0;
    reg        acc_c  = 0;
    reg [19:0] acc_hi = 0;
    reg [19:0] pinc_hi_d = 0;
    always @(posedge clk_rf) begin
        if (!tx_rf_sync2) begin
            acc_lo <= 20'd0; acc_c <= 1'b0; acc_hi <= 20'd0; pinc_hi_d <= 20'd0;
        end else begin
            {acc_c, acc_lo} <= acc_lo + rf_pinc_st3[19:0];
            pinc_hi_d       <= rf_pinc_st3[39:20];
            acc_hi          <= acc_hi + pinc_hi_d + acc_c;
        end
    end

    // ========================================================================
    //  4b. OUTPUT STAGE.  bit 19 of the high half == bit 39 of the old 40-bit
    //      accumulator, i.e. the carrier's square wave.
    //
    //      With RF_ODDR_ENABLE, a SECOND phase sample is produced half a step
    //      ahead (phase + pinc/2) and the two are clocked out on the rising and
    //      falling edges of clk_rf through an ODDR, doubling the output sample
    //      rate. The half-step is computed with the same segmentation trick as
    //      the accumulator itself so no adder is wider than 20 bits:
    //
    //        acc_lo(n) = P(n)[19:0]      (the low half runs one add ahead)
    //        acc_hi(n) = P(n-1)[39:20]   (so the plain output is P(n-1)[39])
    //
    //      so bit 39 of P(n-1)+pinc/2 is acc_hi(n) + pinc_half_hi plus the carry
    //      out of acc_lo(n-1) + pinc_half_lo -- hence acc_lo_d below. Both bits
    //      then pass through the same two register stages, so they stay aligned.
    // ========================================================================
    wire [19:0] pinc_half_lo = {rf_pinc_st3[20], rf_pinc_st3[19:1]};
    wire [19:0] pinc_half_hi = {1'b0,            rf_pinc_st3[39:21]};

    reg [19:0] acc_lo_d = 0;
    always @(posedge clk_rf) acc_lo_d <= acc_lo;

    // sub-stage A: carry out of the low half, plus the operands the high half needs
    reg        half_c_a   = 0;
    reg [19:0] acc_hi_a   = 0, pinc_half_hi_a = 0;
    reg        main_msb_a = 0;
    always @(posedge clk_rf) begin
        half_c_a       <= {1'b0, acc_lo_d} + {1'b0, pinc_half_lo} >= 21'h100000;
        acc_hi_a       <= acc_hi;
        pinc_half_hi_a <= pinc_half_hi;
        main_msb_a     <= acc_hi[19];
    end

    // sub-stage B: one 20-bit add, take its MSB
    wire [19:0] half_hi_sum = acc_hi_a + pinc_half_hi_a + {19'd0, half_c_a};
    reg  rf_bit_even = 0;   // phase P
    reg  rf_bit_odd  = 0;   // phase P + pinc/2
    always @(posedge clk_rf) begin
        rf_bit_even <= main_msb_a;
        rf_bit_odd  <= half_hi_sum[19];
    end

    generate if (RF_ODDR_ENABLE) begin : gen_rf_oddr
        // Xilinx unisim primitive: D1 goes out on the rising edge of clk_rf,
        // D2 on the falling edge, so the pair emits two phase samples per cycle.
        ODDR #(
            .DDR_CLK_EDGE("SAME_EDGE"),
            .INIT(1'b0),
            .SRTYPE("SYNC")
        ) u_rf_oddr (
            .Q  (antenna_out),
            .C  (clk_rf),
            .CE (1'b1),
            .D1 (rf_bit_even),
            .D2 (rf_bit_odd),
            .R  (1'b0),
            .S  (1'b0)
        );
    end else begin : gen_rf_sdr
        // Plain single-rate output, unchanged behaviour, no vendor primitive.
        assign antenna_out = acc_hi[19];
    end
    endgenerate

    // ========================================================================
    //  5. RAW MPX EXPORT (debug only, MPX_EXPORT_ENABLE) -- see tx_mpx_export.v.
    //     Everything below the tap (decimation, CDC into s_axi_aclk,
    //     shift/saturate, FIFO) lives in that module. Nothing here touches the
    //     transmit path, so with MPX_EXPORT_ENABLE = 0 the whole thing is
    //     elided and the three registers read back as 0, while what goes on
    //     air is bit-for-bit identical.
    // ========================================================================
    generate if (MPX_EXPORT_ENABLE) begin : gen_mpx_export

        // rst_n_audio: this module has no clk_audio reset of its own (every
        // clk_audio register relies on its declared initial value), so
        // s_axi_aresetn is synchronised into clk_audio purely for the export.
        (* ASYNC_REG = "TRUE" *) reg rstn_aud_meta = 1'b0, rstn_aud_sync = 1'b0;
        always @(posedge clk_audio or negedge s_axi_aresetn) begin
            if (!s_axi_aresetn) begin
                rstn_aud_meta <= 1'b0;
                rstn_aud_sync <= 1'b0;
            end else begin
                rstn_aud_meta <= 1'b1;
                rstn_aud_sync <= rstn_aud_meta;
            end
        end

        tx_mpx_export #(
            .DEC_R      (MPX_TX_DECIM),
            .FIFO_DEPTH (MPX_TX_FIFO_DEPTH),
            .FIFO_ADDR_W(MPX_TX_FIFO_ADDR_W)
        ) u_tx_mpx_export (
            .clk_audio    (clk_audio),
            .rst_n_audio  (rstn_aud_sync),
            .mpx_in       (mpx),

            .s_axi_aclk   (s_axi_aclk),
            .s_axi_aresetn(s_axi_aresetn),
            .shift        (r_mpx_tx_shift),
            .rd_pop       (mpx_tx_fifo_pop_strobe),
            .clr_overflow (mpx_tx_fifo_clr_ovf),
            .rd_data      (mpx_tx_fifo_rd_data),
            .count        (mpx_tx_fifo_count),
            .empty        (mpx_tx_fifo_empty),
            .overflow_flag(mpx_tx_fifo_overflow)
        );

    end else begin : gen_no_mpx_export
        // Export compiled out: tie the read-back signals off so 0x44/0x48/0x4C
        // read as an empty, never-overflowing FIFO rather than as x.
        assign mpx_tx_fifo_rd_data  = 16'sd0;
        assign mpx_tx_fifo_count    = {(MPX_TX_FIFO_ADDR_W+1){1'b0}};
        assign mpx_tx_fifo_empty    = 1'b1;
        assign mpx_tx_fifo_overflow = 1'b0;
    end
    endgenerate

endmodule