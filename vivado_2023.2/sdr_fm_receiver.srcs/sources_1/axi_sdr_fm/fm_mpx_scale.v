`timescale 1ns / 1ps
// =============================================================================
// Module : fm_mpx_scale
// Purpose: Conditions the demodulated MPX composite for the raw-MPX export
//          FIFO: a runtime arithmetic right-shift followed by a saturating
//          narrow to a signed 16-bit sample.
//
//          Like fm_stereo_demod and rds_decode, this module takes the MPX
//          composite already demodulated by the shared fm_cordic_discrim
//          instance in axi_sdr_fm.v rather than demodulating for itself.
//          Earlier revisions did their own arctan-free cross-product
//          discrimination here, which compressed badly at high deviation
//          (at 250 kHz, full +/-75 kHz deviation gives dphi = 1.885 rad,
//          where sin(dphi) = 0.951 against a linear ideal of 1.885 -- some
//          49% compression right at the peaks) and so did not match what
//          the receiver's own audio and RDS paths were seeing. Sharing one
//          true phase-difference CORDIC removes both the discrepancy and
//          the redundant hardware: the exported samples are now exactly
//          the composite the rest of the design demodulates from.
//
//          What remains here is purely the export-side conditioning:
//
//   SHIFT: mpx_in is a signed 18-bit phase difference whose peak magnitude
//          depends on the deviation actually being received, so it must be
//          scaled to make good use of the 16-bit export sample. `shift` is
//          driven from the MPX_SHIFT register (0x34) in axi_sdr_fm.v.
//          Useful values are small: at 250 kHz, full +/-75 kHz deviation
//          reaches roughly +/-39000, so shift=1 fits worst-case peaks
//          inside signed 16-bit with no clipping, and shift=0 gives 6 dB
//          more resolution at the cost of clipping the loudest peaks. Tune
//          against a live signal.
//
//   SATURATION: values that still exceed signed 16-bit range after the
//          shift are clamped to +/-full-scale rather than wrapped -- a
//          wrap would turn a loud peak into a full-amplitude sign
//          inversion, which is far more destructive to anything analyzing
//          the exported stream than flat-topping is.
// =============================================================================
module fm_mpx_scale (
    input  wire                clk,
    input  wire                rst_n,

    input  wire signed [17:0]  mpx_in,      // MPX composite from fm_cordic_discrim
    input  wire                valid_in,    // strobe for mpx_in

    input  wire [3:0]          shift,       // 0-15, runtime gain (MPX_SHIFT register)

    output reg  signed [15:0]  mpx_out,     // saturated signed 16-bit export sample
    output reg                 mpx_valid    // one-cycle pulse, one cycle after valid_in
);

    wire signed [17:0] mpx_shifted = mpx_in >>> shift;

    localparam signed [17:0] MPX_POS_MAX =  18'sd32767;
    localparam signed [17:0] MPX_NEG_MIN = -18'sd32768;

    wire signed [15:0] mpx_sat = (mpx_shifted > MPX_POS_MAX) ?  16'sd32767 :
                                  (mpx_shifted < MPX_NEG_MIN) ? -16'sd32768 :
                                  mpx_shifted[15:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mpx_out   <= 16'sd0;
            mpx_valid <= 1'b0;
        end else begin
            mpx_valid <= valid_in;
            if (valid_in)
                mpx_out <= mpx_sat;
        end
    end

endmodule
