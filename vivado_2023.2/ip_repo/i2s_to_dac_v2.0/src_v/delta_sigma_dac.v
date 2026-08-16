// =============================================================================
// FILE  : delta_sigma_dac.v
// BRIEF : Multi-channel 1-bit Delta-Sigma DAC (Error Feedback topology).
//
//   Supports DS_ORDER = 1, 2, or 3.  All channels share the same parameters
//   and run at the full <clk> rate (oversampling ratio = f_clk / f_audio).
//
//   Channel mapping on the output bus:
//     dac_out[2*g]   = SDATA line g, LEFT  channel
//     dac_out[2*g+1] = SDATA line g, RIGHT channel
//
//   Input packing (left_data / right_data from audio_sample_buffer):
//     Lane g occupies bits [(g+1)*W-1 : g*W]   (same as i2s_receiver output)
//
// BIT-WIDTH BUDGET (W = AUDIO_DATA_WIDTH, e.g. 24)
//   ACC_W  = W + 4   (28) — accumulator guard bits prevent wrap-around
//   EXT_W  = ACC_W+3 (31) — arithmetic bus; accommodates 3rd-order sum peak
//                           (|u_max| ? 7.5 · 2^W, needs W+4 bits > margin OK)
//
// CLAMPING
//   Integrator states are clamped to ±2·MAX to keep the loop stable when the
//   input is near full-scale for extended periods.
//
// NOISE SHAPING TRANSFER FUNCTIONS (EFM topology)
//   Order 1 : H(z) = z??              > u = x + e?
//   Order 2 : H(z) = 2z?? ? z??      > u = x + 2·e? ? e?
//   Order 3 : H(z) = 3z?? ? 3z?? + z?? > u = x + 3·e? ? 3·e? + e?
//
// ZYNQ-7010 NOTES (NUM_SDATA_LINES=1, DS_ORDER=2, W=24)
//   • 2 channels ? ~52 FFs + ~80 LUTs each ? 104 FFs, 160 LUTs total.
//   • No DSP blocks inferred (shifts + adds synthesise to LUT fabric).
//   • IOB output registers: add (* IOB = "TRUE" *) to dac_out drivers or
//     constrain via XDC to reduce jitter on the PDM outputs.
// =============================================================================
`timescale 1ns / 1ps

module delta_sigma_dac #(
    parameter NUM_SDATA_LINES  = 1,
    parameter AUDIO_DATA_WIDTH = 24,
    parameter DS_ORDER         = 2    // 1, 2, or 3
)(
    input  wire clk,
    input  wire rst_n,

    // Audio input — packed flat buses from audio_sample_buffer
    input  wire [(NUM_SDATA_LINES*AUDIO_DATA_WIDTH)-1:0] left_data,
    input  wire [(NUM_SDATA_LINES*AUDIO_DATA_WIDTH)-1:0] right_data,

    // 1-bit PDM outputs
    output wire [(NUM_SDATA_LINES*2)-1:0] dac_out
);

  localparam TOTAL_CH = NUM_SDATA_LINES * 2;
  localparam W        = AUDIO_DATA_WIDTH;
  localparam ACC_W    = W + 4;      // accumulator width
  localparam EXT_W    = ACC_W + 3;  // arithmetic bus width

  // Quantiser reference levels (sign-extended to EXT_W)
  localparam signed [EXT_W-1:0] MAX_VAL   = (1 << (W-1)) - 1;
  localparam signed [EXT_W-1:0] MIN_VAL   = -(1 << (W-1));

  // Integrator clamp boundaries (±2 · MAX_VAL)
  localparam signed [EXT_W-1:0] CLAMP_POS = MAX_VAL <<< 1;
  localparam signed [EXT_W-1:0] CLAMP_NEG = MIN_VAL <<< 1;

  // ---------------------------------------------------------------------------
  // 1. Unpack left / right buses > per-channel array (sign-extend to ACC_W)
  //    ch = 2·g   > LEFT  of SDATA line g
  //    ch = 2·g+1 > RIGHT of SDATA line g
  // ---------------------------------------------------------------------------
  wire signed [ACC_W-1:0] din_ch [0:TOTAL_CH-1];

  genvar g;
  generate
    for (g = 0; g < NUM_SDATA_LINES; g = g + 1) begin : gen_unpack
      assign din_ch[2*g] = {
        {(ACC_W-W){left_data[(g+1)*W-1]}},
         left_data[(g+1)*W-1 : g*W]
      };
      assign din_ch[2*g+1] = {
        {(ACC_W-W){right_data[(g+1)*W-1]}},
         right_data[(g+1)*W-1 : g*W]
      };
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // 2. One modulator instance per channel
  // ---------------------------------------------------------------------------
  generate
    for (g = 0; g < TOTAL_CH; g = g + 1) begin : gen_mod

      wire signed [ACC_W-1:0] din   = din_ch[g];
      reg                     dac_r;         // registered 1-bit output

      // Sign-extend input and quantiser feedback to EXT_W for safe arithmetic
      wire signed [EXT_W-1:0] din_ext = {{(EXT_W-ACC_W){din[ACC_W-1]}}, din};
      wire signed [EXT_W-1:0] fb_val  = dac_r ? MAX_VAL : MIN_VAL;

      // -----------------------------------------------------------------------
      // ORDER 1 : u = x + e?
      // -----------------------------------------------------------------------
      if (DS_ORDER == 1) begin : ord1

        reg signed [ACC_W-1:0] e1;
        wire signed [EXT_W-1:0] e1e   = {{(EXT_W-ACC_W){e1[ACC_W-1]}}, e1};
        wire signed [EXT_W-1:0] u     = din_ext + e1e;
        wire signed [EXT_W-1:0] e_raw = u - fb_val;

        always @(posedge clk or negedge rst_n) begin
          if (!rst_n) begin
            e1    <= {ACC_W{1'b0}};
            dac_r <= 1'b0;
          end else begin
            dac_r <= (u >= 0);
            if      (e_raw > CLAMP_POS) e1 <= CLAMP_POS[ACC_W-1:0];
            else if (e_raw < CLAMP_NEG) e1 <= CLAMP_NEG[ACC_W-1:0];
            else                        e1 <= e_raw[ACC_W-1:0];
          end
        end

      // -----------------------------------------------------------------------
      // ORDER 2 : u = x + 2·e? ? e?
      // -----------------------------------------------------------------------
      end else if (DS_ORDER == 2) begin : ord2

        reg signed [ACC_W-1:0] e1, e2;
        wire signed [EXT_W-1:0] e1e   = {{(EXT_W-ACC_W){e1[ACC_W-1]}}, e1};
        wire signed [EXT_W-1:0] e2e   = {{(EXT_W-ACC_W){e2[ACC_W-1]}}, e2};
        wire signed [EXT_W-1:0] u     = din_ext + (e1e <<< 1) - e2e;
        wire signed [EXT_W-1:0] e_raw = u - fb_val;

        always @(posedge clk or negedge rst_n) begin
          if (!rst_n) begin
            e1 <= {ACC_W{1'b0}};
            e2 <= {ACC_W{1'b0}};
            dac_r <= 1'b0;
          end else begin
            dac_r <= (u >= 0);
            if      (e_raw > CLAMP_POS) e1 <= CLAMP_POS[ACC_W-1:0];
            else if (e_raw < CLAMP_NEG) e1 <= CLAMP_NEG[ACC_W-1:0];
            else                        e1 <= e_raw[ACC_W-1:0];
            e2 <= e1;
          end
        end

      // -----------------------------------------------------------------------
      // ORDER 3 (default) : u = x + 3·e? ? 3·e? + e?
      // -----------------------------------------------------------------------
      end else begin : ord3

        reg signed [ACC_W-1:0] e1, e2, e3;
        wire signed [EXT_W-1:0] e1e   = {{(EXT_W-ACC_W){e1[ACC_W-1]}}, e1};
        wire signed [EXT_W-1:0] e2e   = {{(EXT_W-ACC_W){e2[ACC_W-1]}}, e2};
        wire signed [EXT_W-1:0] e3e   = {{(EXT_W-ACC_W){e3[ACC_W-1]}}, e3};
        // 3·e = (e<<1) + e  >  two adders, no multiplier, maps to LUTs
        wire signed [EXT_W-1:0] u     = din_ext
                                        + (e1e <<< 1) + e1e
                                        - (e2e <<< 1) - e2e
                                        + e3e;
        wire signed [EXT_W-1:0] e_raw = u - fb_val;

        always @(posedge clk or negedge rst_n) begin
          if (!rst_n) begin
            e1 <= {ACC_W{1'b0}};
            e2 <= {ACC_W{1'b0}};
            e3 <= {ACC_W{1'b0}};
            dac_r <= 1'b0;
          end else begin
            dac_r <= (u >= 0);
            if      (e_raw > CLAMP_POS) e1 <= CLAMP_POS[ACC_W-1:0];
            else if (e_raw < CLAMP_NEG) e1 <= CLAMP_NEG[ACC_W-1:0];
            else                        e1 <= e_raw[ACC_W-1:0];
            e2 <= e1;
            e3 <= e2;
          end
        end

      end // DS_ORDER

      assign dac_out[g] = dac_r;

    end // gen_mod
  endgenerate

endmodule
