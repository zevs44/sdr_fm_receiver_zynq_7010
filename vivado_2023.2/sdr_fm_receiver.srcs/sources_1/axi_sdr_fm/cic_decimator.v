`timescale 1ns / 1ps
// =============================================================================
// Module : cic_decimator
// Purpose: Parametric CIC (Cascaded Integrator-Comb) decimator, operates at
//          up to 250 MHz (T = 4.0 ns).
//
//          Integrators and combs use a plain ripple adder/subtractor chain
//          rather than a carry-select structure: on 7-series devices CARRY4
//          is already a dedicated fast carry path (roughly 0.114 ns/bit of
//          hop rate), so splitting the adder into segments only adds a
//          multiplexer and inter-segment routing between them, which costs
//          more than the parallel precomputation saves. For B_MAX <= 48
//          bits the integrator width fits the DSP48E1 P-register exactly,
//          so it is left to infer into a DSP slice (accumulate pattern,
//          UG901); the `(* use_dsp = "no" *)` attribute only applies to
//          keep it out of fabric logic when a slice is not warranted. For
//          B_MAX > 48 bits (e.g. the RDS configuration, B_IN=18/N=3/R=10,
//          which needs GUARD_BITS and yields B_MAX=59), a single DSP48E1
//          cannot hold the accumulator, so the same plain adder chain is
//          used directly in fabric logic.
//
//          `use_dsp` is a synthesis hint, not a guarantee -- after
//          synthesis, confirm actual DSP48E1 usage and timing closure in
//          the Vivado utilization and timing reports for the target
//          placement.
// =============================================================================

module cic_decimator #(
    parameter B_IN     = 5,    // input width (signed)
    parameter N_STAGES = 4,    // CIC order
    parameter R_DEC    = 200,  // decimation factor
    parameter B_OUT    = 16,   // output width (signed)
    parameter GUARD_BITS = 0   // extra headroom on top of the Hogenauer bit-
                                // growth formula, needed when the input is
                                // not strictly zero-mean over intervals on
                                // the order of R_DEC^N samples. For the RDS
                                // configuration (B_IN=18/N=3/R=10/B_OUT=58)
                                // use GUARD_BITS=30 (B_MAX=59, DISCARD=1).
                                // GUARD_BITS=0 reproduces the plain
                                // Hogenauer formula.
)(
    input  wire                      clk,       // up to 250 MHz
    input  wire                      rst_n,
    input  wire signed [B_IN-1:0]    data_in,
    input  wire                      valid_in,
    output reg  signed [B_OUT-1:0]   data_out,
    output reg                       valid_out
);

    // =========================================================================
    // Derived parameters
    // =========================================================================
    localparam CLOG2_R = $clog2(R_DEC);
    localparam R_IS_POW2 = ((R_DEC & (R_DEC - 1)) == 0) ? 1 : 0;
    localparam B_MAX   = B_IN + N_STAGES * CLOG2_R - (R_IS_POW2 ? 0 : 1) + GUARD_BITS;
    localparam DISCARD = B_MAX - B_OUT;
    localparam CNT_W   = $clog2(R_DEC);
    localparam [CNT_W-1:0] DEC_MAX = R_DEC - 1;
    // Guards against DISCARD == 0 (output width equals the internal width,
    // so there is no rounding bit to read); the index is unused in that
    // case since round_bit_r is forced to 0 below.
    localparam ROUND_BIT_IDX = (DISCARD > 0) ? (DISCARD - 1) : 0;

    // =========================================================================
    // Sign-extend the input
    // =========================================================================
    wire signed [B_MAX-1:0] data_in_ext = {{(B_MAX-B_IN){data_in[B_IN-1]}}, data_in};

    // =========================================================================
    // Section 1: Integrators
    // =========================================================================
    // integ[i] for i>0 reads the OLD (pre-edge) value of integ[i-1] -- the
    // usual CIC integrator cascade, one cycle of latency per stage.

    (* use_dsp = "no" *) reg signed [B_MAX-1:0] integ [0:N_STAGES-1];

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < N_STAGES; i = i + 1)
                integ[i] <= {B_MAX{1'b0}};
        end else if (valid_in) begin
            integ[0] <= integ[0] + data_in_ext;
            for (i = 1; i < N_STAGES; i = i + 1)
                integ[i] <= integ[i] + integ[i-1];
        end
    end

    // =========================================================================
    // Section 2: Decimator
    // =========================================================================

    reg  [CNT_W-1:0]       dec_cnt;
    reg                     dec_valid;

    (* KEEP = "TRUE" *)
    reg signed [B_MAX-1:0] dec_data;

    always @(posedge clk) begin
        if (!rst_n) begin
            dec_cnt   <= {CNT_W{1'b0}};
            dec_valid <= 1'b0;
            dec_data  <= {B_MAX{1'b0}};
        end else if (valid_in) begin
            if (dec_cnt == DEC_MAX) begin
                dec_cnt   <= {CNT_W{1'b0}};
                dec_valid <= 1'b1;
                dec_data  <= integ[N_STAGES-1];
            end else begin
                dec_cnt   <= dec_cnt + 1'b1;
                dec_valid <= 1'b0;
            end
        end else begin
            dec_valid <= 1'b0;
        end
    end

    // =========================================================================
    // Section 3: Combs -- 2 sub-stages per cascade, direct subtraction
    // =========================================================================
    // Sub-stage A: latches both full operands (minuend and the previous
    // delay-line value) and updates the delay line.
    // Sub-stage B: subtracts the latched operands.
    // Cascade latency is 2 cycles per comb stage.

    (* use_dsp = "no" *) reg signed [B_MAX-1:0] comb_data  [0:N_STAGES-1];
    reg signed [B_MAX-1:0] comb_delay [0:N_STAGES-1];
    reg signed [B_MAX-1:0] opA_r      [0:N_STAGES-1];
    reg signed [B_MAX-1:0] opB_r      [0:N_STAGES-1];

    (* SHREG_EXTRACT = "NO" *)
    reg [N_STAGES-1:0] comb_mid_valid;
    (* SHREG_EXTRACT = "NO" *)
    reg [N_STAGES-1:0] comb_valid;

    // -- Cascade 0 -- sub-stage A --
    always @(posedge clk) begin
        if (!rst_n) begin
            opA_r[0]          <= {B_MAX{1'b0}};
            opB_r[0]          <= {B_MAX{1'b0}};
            comb_delay[0]     <= {B_MAX{1'b0}};
            comb_mid_valid[0] <= 1'b0;
        end else begin
            comb_mid_valid[0] <= dec_valid;
            if (dec_valid) begin
                opA_r[0]      <= dec_data;
                opB_r[0]      <= comb_delay[0];  // OLD value (non-blocking read)
                comb_delay[0] <= dec_data;       // update (non-blocking write)
            end
        end
    end

    // -- Cascade 0 -- sub-stage B --
    always @(posedge clk) begin
        if (!rst_n) begin
            comb_data[0]  <= {B_MAX{1'b0}};
            comb_valid[0] <= 1'b0;
        end else begin
            comb_valid[0] <= comb_mid_valid[0];
            if (comb_mid_valid[0])
                comb_data[0] <= opA_r[0] - opB_r[0];
        end
    end

    // -- Cascades 1..N_STAGES-1 --
    genvar g;
    generate
        for (g = 1; g < N_STAGES; g = g + 1) begin : gen_comb

            // Sub-stage gA
            always @(posedge clk) begin
                if (!rst_n) begin
                    opA_r[g]          <= {B_MAX{1'b0}};
                    opB_r[g]          <= {B_MAX{1'b0}};
                    comb_delay[g]     <= {B_MAX{1'b0}};
                    comb_mid_valid[g] <= 1'b0;
                end else begin
                    comb_mid_valid[g] <= comb_valid[g-1];
                    if (comb_valid[g-1]) begin
                        opA_r[g]      <= comb_data[g-1];
                        opB_r[g]      <= comb_delay[g];   // OLD value
                        comb_delay[g] <= comb_data[g-1];  // update
                    end
                end
            end

            // Sub-stage gB
            always @(posedge clk) begin
                if (!rst_n) begin
                    comb_data[g]  <= {B_MAX{1'b0}};
                    comb_valid[g] <= 1'b0;
                end else begin
                    comb_valid[g] <= comb_mid_valid[g];
                    if (comb_mid_valid[g])
                        comb_data[g] <= opA_r[g] - opB_r[g];
                end
            end

        end
    endgenerate

    // =========================================================================
    // Section 4A: Pre-registration ahead of rounding
    // =========================================================================

    reg signed [B_OUT-1:0] comb_top_r;
    reg                     round_bit_r;
    reg                     valid_trunc;

    always @(posedge clk) begin
        if (!rst_n) begin
            comb_top_r  <= {B_OUT{1'b0}};
            round_bit_r <= 1'b0;
            valid_trunc <= 1'b0;
        end else begin
            comb_top_r  <= $signed(comb_data[N_STAGES-1][B_MAX-1 -: B_OUT]);
            round_bit_r <= (DISCARD > 0) ? comb_data[N_STAGES-1][ROUND_BIT_IDX] : 1'b0;
            valid_trunc <= comb_valid[N_STAGES-1];
        end
    end

    // =========================================================================
    // Section 4B: Output -- round by adding the discarded MSB back in.
    // round_bit_r is an unsigned reg, so it zero-extends (not sign-extends)
    // into the addition -- a signed 1-bit version would read '1' as -1
    // instead of +1.
    // =========================================================================

    always @(posedge clk) begin
        if (!rst_n) begin
            data_out  <= {B_OUT{1'b0}};
            valid_out <= 1'b0;
        end else begin
            data_out  <= comb_top_r + round_bit_r;
            valid_out <= valid_trunc;
        end
    end

endmodule