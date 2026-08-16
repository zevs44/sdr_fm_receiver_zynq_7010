`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 15.07.2026 19:48:40
// Design Name: 
// Module Name: i2s_axi_mux_top
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: Fixed 3-channel I2S AXI4-Lite mux (system-level instantiation of i2s_axi_mux)
// 
// Dependencies: i2s_axi_mux.v, i2s_slave_bridge.v
// 
// Revision:
// Revision 0.01 - File Created
// Revision 0.02 - Renamed to i2s_axi_mux_top; comments translated to English and unified for release
// Revision 0.03 - Added the slave-mode I2S port (adi_*) permanently tied to channel 1,
//                 intended for axi_i2s_adi's SDATA_I input (that core is master-only)
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


// Fixed 3-channel instantiation of i2s_axi_mux for system integration

module i2s_axi_mux_top #(
    // --- Slave-mode output port ---
    parameter integer SLAVE_PORT_ENABLE = 1,   // 1 = instantiate the slave bridge
    parameter integer SLAVE_SRC_CH      = 1,   // input channel permanently routed to the slave port (0..2)
    parameter integer SLAVE_DATA_WIDTH  = 32   // bits per slot, MSB-first (>= axi_i2s_adi SLOT_WIDTH)
) (
    // --- Global Signals ---
    input  wire                   axi_aclk,
    input  wire                   axi_aresetn,

    // --- I2S Input Ports (3 Channels) ---
    // Channel 0
    input  wire                   ch0_i2s_bclk,
    input  wire                   ch0_i2s_lrclk,
    input  wire                   ch0_i2s_sdata,

    // Channel 1
    input  wire                   ch1_i2s_bclk,
    input  wire                   ch1_i2s_lrclk,
    input  wire                   ch1_i2s_sdata,

    // Channel 2
    input  wire                   ch2_i2s_bclk,
    input  wire                   ch2_i2s_lrclk,
    input  wire                   ch2_i2s_sdata,

    // --- I2S Output Ports (master-style: clocks are passed through) ---
    output wire                   i2s_bclk_out,
    output wire                   i2s_lrclk_out,
    output wire                   i2s_sdata_out,

    // --- I2S Slave Port (clocks supplied by axi_i2s_adi acting as master) ---
    // adi_bclk_in   <- axi_i2s_adi BCLK_O
    // adi_lrclk_in  <- axi_i2s_adi LRCLK_O
    // adi_sdata_out -> axi_i2s_adi SDATA_I
    // Permanently sourced from channel SLAVE_SRC_CH (default 1), regardless
    // of the AXI mux selection.
    input  wire                   adi_bclk_in,
    input  wire                   adi_lrclk_in,
    output wire                   adi_sdata_out,

    // --- AXI4-Lite Slave Interface ---
    input  wire [3:0]             s_axi_awaddr,
    input  wire                   s_axi_awvalid,
    output wire                   s_axi_awready,
    input  wire [31:0]            s_axi_wdata,
    input  wire                   s_axi_wvalid,
    output wire                   s_axi_wready,
    output wire [1:0]             s_axi_bresp,
    output wire                   s_axi_bvalid,
    input  wire                   s_axi_bready,
    input  wire [3:0]             s_axi_araddr,
    input  wire                   s_axi_arvalid,
    output wire                   s_axi_arready,
    output wire [31:0]            s_axi_rdata,
    output wire [1:0]             s_axi_rresp,
    output wire                   s_axi_rvalid,
    input  wire                   s_axi_rready
);

    // Fixed channel count for this instantiation
    localparam integer NUM_INPUTS = 3;

    // Connect external ports to the mux's vector inputs.
    // In Verilog concatenation {MSB, ..., LSB}, the leftmost element maps to the most-significant bit.
    // Index mapping: [2] -> Channel 2, [1] -> Channel 1, [0] -> Channel 0.
    i2s_axi_mux #(
        .NUM_INPUTS        (NUM_INPUTS),
        .SLAVE_PORT_ENABLE (SLAVE_PORT_ENABLE),
        .SLAVE_SRC_CH      (SLAVE_SRC_CH),
        .SLAVE_DATA_WIDTH  (SLAVE_DATA_WIDTH)
    ) u_i2s_mux (
        // Global Signals
        .axi_aclk       (axi_aclk),
        .axi_aresetn    (axi_aresetn),

        // I2S Inputs (packed into buses)
        .i2s_sclk_in    ({ch2_i2s_bclk,  ch1_i2s_bclk,  ch0_i2s_bclk}),
        .i2s_lrclk_in   ({ch2_i2s_lrclk, ch1_i2s_lrclk, ch0_i2s_lrclk}),
        .i2s_sdata_in   ({ch2_i2s_sdata, ch1_i2s_sdata, ch0_i2s_sdata}),

        // I2S Outputs
        .i2s_sclk_out   (i2s_bclk_out),
        .i2s_lrclk_out  (i2s_lrclk_out),
        .i2s_sdata_out  (i2s_sdata_out),

        // I2S Slave Port
        .slv_bclk_in    (adi_bclk_in),
        .slv_lrclk_in   (adi_lrclk_in),
        .slv_sdata_out  (adi_sdata_out),

        // AXI4-Lite Interface
        .s_axi_awaddr   (s_axi_awaddr),
        .s_axi_awvalid  (s_axi_awvalid),
        .s_axi_awready  (s_axi_awready),
        .s_axi_wdata    (s_axi_wdata),
        .s_axi_wvalid   (s_axi_wvalid),
        .s_axi_wready   (s_axi_wready),
        .s_axi_bresp    (s_axi_bresp),
        .s_axi_bvalid   (s_axi_bvalid),
        .s_axi_bready   (s_axi_bready),
        .s_axi_araddr   (s_axi_araddr),
        .s_axi_arvalid  (s_axi_arvalid),
        .s_axi_arready  (s_axi_arready),
        .s_axi_rdata    (s_axi_rdata),
        .s_axi_rresp    (s_axi_rresp),
        .s_axi_rvalid   (s_axi_rvalid),
        .s_axi_rready   (s_axi_rready)
    );

endmodule