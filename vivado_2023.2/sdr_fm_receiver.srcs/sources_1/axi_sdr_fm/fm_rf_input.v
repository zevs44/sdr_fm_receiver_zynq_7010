`timescale 1ns / 1ps
// =============================================================================
// Module : fm_rf_input
// Purpose: Direct RF sampling front end for FM broadcast reception -- a
//          1-bit hard limiter (comparator), captured in the I/O block at
//          the RF sample clock.
//
//          The differential input pins are not used as true LVDS logic
//          inputs here: lvds_p/lvds_n are the two ends of a passive analog
//          LC tank (see the antenna coupling network below), and the
//          FPGA's IBUFDS differential input buffer is used purely as a
//          fast analog comparator. Its output toggles at the RF signal's
//          zero crossings, giving a 1-bit representation of the RF
//          waveform that preserves enough phase/frequency information for
//          the digital mixer/decimator chain downstream (fm_ddc_mixer,
//          cic_decimator) to recover the tuned station. All frequency
//          selectivity beyond the passive analog network below is done
//          digitally, by the tunable NCO and CIC filtering -- this module
//          contributes no tuning of its own.
// =============================================================================
module fm_rf_input (
    input  wire clk,         // 250 MHz
    input  wire rst_n,
    input  wire lvds_p,      // to the coil
    input  wire lvds_n,      // to the coil
    output reg  rf_bit       // 1-bit RF sample stream
);
    wire comp_out;
    // LVDS input buffer used as a comparator, not a logic input --
    // termination is disabled since this is an analog signal, not a real
    // differential logic pair.
    IBUFDS #(
        .IOSTANDARD("LVDS_25"),
        .DIFF_TERM("FALSE")
    ) ibufds_inst (
        .I (lvds_p),
        .IB(lvds_n),
        .O (comp_out)
    );
    // Captured directly in the I/O block to minimize jitter, with a second
    // register providing a pipeline stage into fabric.
    (* IOB = "TRUE" *) reg iob_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            iob_reg <= 1'b0;
            rf_bit  <= 1'b0;
        end else begin
            iob_reg <= comp_out;
            rf_bit  <= iob_reg; // fabric-side pipeline stage
        end
    end
endmodule

// -----------------------------------------------------------------------------
// Antenna coupling network (passive, off-chip -- see README for a fuller
// explanation of the operating principle):
//
//   FPGA (lvds_p) ---+-------------------+
//                     |                   |
//                    ---                 _|_
//                    --- C1             (   )  Coil L1 (hand-wound from
//                     |  22n            (   )  twisted-pair wire, ~6-7 turns)
//                     |                   |
//                     |                   |  <---- tap at 1.5 turns from the bottom
//                     |                   +---------+-----> Antenna (~75 cm wire)
//                     |                 (   )
//                     |                 (   )
//   FPGA (lvds_n) ---+-------------------+
//
// L1 and C1 form a parallel resonant tank across the FPGA's differential
// input pair; the antenna feeds in through a tap near the bottom of the
// coil, acting as an autotransformer that steps the antenna's lower
// impedance up to match the tank, boosting the RF signal purely passively
// (no amplifying devices) before it reaches the comparator above. L1
// should be tuned so the tank resonates within the FM broadcast band.
// -----------------------------------------------------------------------------