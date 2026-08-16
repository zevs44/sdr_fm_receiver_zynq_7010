`timescale 1ns / 1ps
// =============================================================================
// Module : rds_block_fifo
// Purpose: Single-clock synchronous FIFO for raw RDS blocks, backing the
//          AXI REG_RDS_FIFO_STAT / REG_RDS_FIFO_DATA registers (see the
//          register map in axi_sdr_fm.v).
//
//          The FIFO is synchronous, not asynchronous: the producer
//          (rds_decode, instantiated inside fm_stereo_demod.v) and the
//          consumer (the AXI read path in axi_sdr_fm.v) both run on
//          s_axi_aclk, so Gray-coded pointers and cross-domain
//          synchronization are not needed. If producer and consumer are
//          ever placed in different clock domains, this module must be
//          replaced with a true asynchronous FIFO -- as written, driving
//          wr_* and rd_* from different clocks is not safe.
//
//          The read interface is combinational: rd_data/rd_id/rd_good
//          always reflect the current head of the queue, with no extra
//          cycle of latency after rd_pop. This matches the AXI read
//          convention used in axi_sdr_fm.v (see axil_read_proc there): the
//          head value is captured into s_axil_rdata_r in the same cycle
//          the read request is accepted. rd_pop is a separate strobe
//          (generated from address decode in axi_sdr_fm.v) whose effect
//          (advancing rd_ptr) is applied on the following cycle, so it
//          never disturbs the head value already latched by the read that
//          triggered it.
// =============================================================================
module rds_block_fifo #(
    parameter DEPTH  = 32,      // must be a power of 2
    parameter ADDR_W = 5        // $clog2(DEPTH)
)(
    input  wire         clk,
    input  wire         rst_n,

    // ---- write side (from rds_decode -- raw block stream) ----
    input  wire         wr_en,
    input  wire [15:0]  wr_data,
    input  wire [2:0]   wr_id,
    input  wire         wr_good,

    // ---- read side (from AXI) ----
    input  wire          rd_pop,         // strobe: consume the current head of the queue
    output wire [15:0]   rd_data,        // combinational, head of queue (valid only when !empty)
    output wire [2:0]    rd_id,
    output wire          rd_good,

    output wire [ADDR_W:0] count,        // 0..DEPTH, number of entries currently queued
    output wire           empty,
    input  wire           clr_overflow,  // strobe: clear overflow_flag (clear-on-read semantics for REG_RDS_FIFO_STAT)
    output wire           overflow_flag
);

    reg [19:0] mem [0:DEPTH-1];     // {good(1), id(3), data(16)} = 20 bits/entry
    reg [ADDR_W:0] wr_ptr, rd_ptr;  // extra MSB gives the classic full/empty
                                     // distinction without a separate
                                     // occupancy counter (count is simply
                                     // the pointer difference below --
                                     // correct by modular arithmetic over
                                     // ADDR_W+1 bits)
    reg overflow_r;

    wire full = (wr_ptr[ADDR_W] != rd_ptr[ADDR_W]) &&
                (wr_ptr[ADDR_W-1:0] == rd_ptr[ADDR_W-1:0]);
    assign empty = (wr_ptr == rd_ptr);
    assign count = wr_ptr - rd_ptr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= {(ADDR_W+1){1'b0}};
        end else if (wr_en && !full) begin
            mem[wr_ptr[ADDR_W-1:0]] <= {wr_good, wr_id, wr_data};
            wr_ptr <= wr_ptr + 1'b1;
        end
    end

    // Overflow means strictly "a write arrived while the queue was full";
    // the incoming entry is dropped rather than overwriting the oldest one,
    // so the driver learns about the loss through this flag instead of a
    // silent data substitution. Cleared on read via the clr_overflow strobe
    // (generated in axi_sdr_fm.v when REG_RDS_FIFO_STAT is read). If a new
    // overflow and a clearing read land in the same cycle, the new overflow
    // wins (clr is applied first below, wr_en&&full second -- the later
    // non-blocking assignment wins on a tie), so the driver cannot miss an
    // overflow that happens in the same cycle as its own status read.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            overflow_r <= 1'b0;
        end else begin
            if (clr_overflow) overflow_r <= 1'b0;
            if (wr_en && full) overflow_r <= 1'b1;
        end
    end
    assign overflow_flag = overflow_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr <= {(ADDR_W+1){1'b0}};
        end else if (rd_pop && !empty) begin
            rd_ptr <= rd_ptr + 1'b1;
        end
    end

    wire [19:0] head = mem[rd_ptr[ADDR_W-1:0]];
    assign rd_data  = head[15:0];
    assign rd_id    = head[18:16];
    assign rd_good  = head[19];

endmodule