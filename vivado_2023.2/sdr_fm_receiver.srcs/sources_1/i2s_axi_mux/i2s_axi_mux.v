`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 10.07.2026 12:23:03
// Design Name: 
// Module Name: i2s_axi_mux
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: N-to-1 I2S mux, active channel selected via a single AXI4-Lite register,
//              plus a permanently attached I2S SLAVE output port that re-clocks one
//              fixed input channel onto an external master's BCLK/LRCLK.
// 
// Dependencies: i2s_slave_bridge.v
// 
// Revision:
// Revision 0.01 - File Created
// Revision 0.02 - Prepared for release: comments translated to English and unified
// Revision 0.03 - Added the slave-mode output port (SLAVE_PORT_ENABLE / SLAVE_SRC_CH)
//                 for feeding axi_i2s_adi's SDATA_I, since that core is master-only
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


// I2S mux (N inputs -> 1 output) controlled via AXI4-Lite
// Designed by Claude Sonnet 5

module i2s_axi_mux #(
    parameter integer NUM_INPUTS = 4,                                          // number of input I2S channels
    parameter integer SEL_WIDTH  = (NUM_INPUTS <= 1) ? 1 : $clog2(NUM_INPUTS),  // channel select field width (do not override manually)

    // --- Slave-mode output port (for axi_i2s_adi, which is master-only) ---
    parameter integer SLAVE_PORT_ENABLE = 1,   // 1 = instantiate the slave bridge
    parameter integer SLAVE_SRC_CH      = 1,   // input channel permanently routed to the slave port
    parameter integer SLAVE_DATA_WIDTH  = 32   // bits per slot, MSB-first (>= axi_i2s_adi SLOT_WIDTH)
) (
    // --- Global Signals ---
    input  wire                   axi_aclk,
    input  wire                   axi_aresetn,

    // --- I2S Interface (NUM_INPUTS Inputs, 1 Output) ---
    input  wire [NUM_INPUTS-1:0]  i2s_sclk_in,
    input  wire [NUM_INPUTS-1:0]  i2s_lrclk_in,
    input  wire [NUM_INPUTS-1:0]  i2s_sdata_in,

    output wire                   i2s_sclk_out,
    output wire                   i2s_lrclk_out,
    output wire                   i2s_sdata_out,

    // --- I2S Slave Output Port (clocks driven by the external master) ---
    // Hard-wired to input channel SLAVE_SRC_CH, independent of the AXI mux
    // selection. Connect slv_bclk_in/slv_lrclk_in to axi_i2s_adi's BCLK_O/LRCLK_O
    // and slv_sdata_out to its SDATA_I.
    input  wire                   slv_bclk_in,
    input  wire                   slv_lrclk_in,
    output wire                   slv_sdata_out,

    // --- AXI4-Lite Slave Interface ---
    input  wire [3:0]  s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [3:0]  s_axi_araddr,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,
    output reg  [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready
);

    // Active-channel select register (axi_aclk domain) - the only control register
    reg [SEL_WIDTH-1:0] reg_channel_select;

    // AXI response constants
    assign s_axi_bresp = 2'b00; // OKAY
    assign s_axi_rresp = 2'b00; // OKAY

    // --- AXI4-Lite: Write logic ---
    always @(posedge axi_aclk) begin
        if (!axi_aresetn) begin
            reg_channel_select <= {SEL_WIDTH{1'b0}};
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
        end else begin
            // Ready to accept address and data
            s_axi_awready <= !s_axi_awready && s_axi_awvalid && s_axi_wvalid;
            s_axi_wready  <= !s_axi_wready  && s_axi_awvalid && s_axi_wvalid;

            if (s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid) begin
                if (s_axi_awaddr[3:0] == 4'h0) begin
                    reg_channel_select <= s_axi_wdata[SEL_WIDTH-1:0];
                end
                s_axi_bvalid <= 1'b1;
            end else if (s_axi_bready && s_axi_bvalid) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    // --- AXI4-Lite: Read logic ---
    always @(posedge axi_aclk) begin
        if (!axi_aresetn) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rdata   <= 32'h0;
        end else begin
            s_axi_arready <= !s_axi_arready && s_axi_arvalid;
            if (s_axi_arvalid && !s_axi_rvalid) begin
                s_axi_rvalid <= 1'b1;
                s_axi_rdata  <= (s_axi_araddr[3:0] == 4'h0) ?
                                 {{(32-SEL_WIDTH){1'b0}}, reg_channel_select} : 32'hDEADBEEF;
            end else if (s_axi_rready && s_axi_rvalid) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

    // --- Clock domain crossing (CDC), separate for each input channel ---
    // In the original switch module there was a single i2s_sclk_in domain
    // fanned out to N outputs. Here it's the reverse: N inputs, each
    // potentially on its own asynchronous SCLK. So reg_channel_select is
    // synchronized independently into every input's domain, and the "am I
    // active" decision is made locally and glitch-free at the audio-word
    // boundary (LRCLK edge) of that input's domain.
    //
    // NOTE (CDC): reg_channel_select is a multi-bit (SEL_WIDTH-bit) bus,
    // synchronized with a simple per-bit 2-FF synchronizer (as in the
    // original switch module). If several bits change at once (e.g.
    // 01->10), a brief incoherent sample at the LRCLK boundary is
    // theoretically possible -> the wrong channel gets routed for one word
    // period, self-correcting at the next boundary. A fully coherent
    // transition would require a handshake between domains instead of a
    // plain synchronizer.
    wire [NUM_INPUTS-1:0] channel_active;

    genvar gi;
    generate
        for (gi = 0; gi < NUM_INPUTS; gi = gi + 1) begin : gen_ch
            reg [SEL_WIDTH-1:0] sync_pipe [1:0];
            reg                 lrclk_sync_d;
            reg                 active_r;

            // Transfer reg_channel_select from the AXI domain into the i2s_sclk_in[gi] domain
            always @(posedge i2s_sclk_in[gi]) begin
                sync_pipe[0] <= reg_channel_select;
                sync_pipe[1] <= sync_pipe[0];
            end

            // Glitch-free update of "is this channel active", only at the
            // start of a new audio word
            always @(posedge i2s_sclk_in[gi]) begin
                lrclk_sync_d <= i2s_lrclk_in[gi];
                if (i2s_lrclk_in[gi] && !lrclk_sync_d) begin
                    active_r <= (sync_pipe[1] == gi[SEL_WIDTH-1:0]);
                end
            end

            assign channel_active[gi] = active_r;
        end
    endgenerate

    // --- Output multiplexer ---
    // channel_active is a one-hot vector (at most one active bit) or all
    // zeros (invalid/transient index). The AND + OR reduction correctly
    // selects the active channel's input; if no channel is selected, the
    // output is silence.
    assign i2s_sclk_out  = |(i2s_sclk_in  & channel_active);
    assign i2s_lrclk_out = |(i2s_lrclk_in & channel_active);
    assign i2s_sdata_out = |(i2s_sdata_in & channel_active);

    // --- Slave-mode output port -------------------------------------------
    // The mux above is a "pass the clocks through" router: whatever sink it
    // feeds must be an I2S slave. axi_i2s_adi cannot do that - it only works
    // as a master and expects SDATA_I to be synchronous to the BCLK/LRCLK it
    // generates itself. So this second, independent port re-clocks channel
    // SLAVE_SRC_CH into the axi_i2s_adi clock domain: the incoming stream is
    // deserialized in its own domain, the L/R pair is passed across the
    // boundary with a double buffer, and is re-serialized on the foreign
    // BCLK/LRCLK. The mux selection does NOT affect this port.
    generate
        if (SLAVE_PORT_ENABLE != 0) begin : gen_slave_port
            i2s_slave_bridge #(
                .DATA_WIDTH (SLAVE_DATA_WIDTH)
            ) u_slave_bridge (
                .aresetn   (axi_aresetn),
                .src_bclk  (i2s_sclk_in [SLAVE_SRC_CH]),
                .src_lrclk (i2s_lrclk_in[SLAVE_SRC_CH]),
                .src_sdata (i2s_sdata_in[SLAVE_SRC_CH]),
                .slv_bclk  (slv_bclk_in),
                .slv_lrclk (slv_lrclk_in),
                .slv_sdata (slv_sdata_out)
            );
        end else begin : gen_no_slave_port
            assign slv_sdata_out = 1'b0;
        end
    endgenerate

endmodule