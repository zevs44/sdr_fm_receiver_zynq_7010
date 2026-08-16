`timescale 1ns / 1ps
// =============================================================================
//  mpx_sample_fifo - Synchronous FIFO for raw sample export (BRAM-backed)
// =============================================================================
//  Single clock domain: the producer (fm_mpx_scale for the raw-MPX
//  instance, or the audio-packing FSM for the post-resampler-audio
//  instance) and the AXI4-Lite read logic that pops entries both live in
//  s_axi_aclk in axi_sdr_fm, so -- like rds_block_fifo -- no CDC is
//  needed. Despite the name, this module is generic: nothing about it is
//  MPX-specific, and axi_sdr_fm.v instantiates it twice (raw MPX export
//  and post-resampler stereo audio export) with different DATA_W.
//
//  Storage lives in BLOCK RAM (ram_style="block"). At 1024x16 the array is
//  16 Kib, fitting one 18 Kb block (RAMB18), freeing the ~250-400 LUTs the
//  distributed-RAM version spent on LUTRAM + its address mux.
//
//  FF economy: the BRAM read register (bram_dout) sits in its OWN reset-free
//  clocked block, so Vivado packs it into the block's built-in output register
//  (part of the RAMB primitive, 0 fabric FFs) instead of spilling to the fabric.
//  Only the presented-head register (head) is a fabric register. Giving the read
//  register an asynchronous reset would prevent that packing and force it (and,
//  in a 2-stage design, a second copy) into fabric FFs -- the usual cause of an
//  FF-utilisation blowup on this pattern.
//
//  Correctness under any pop timing: block RAM has a 1-cycle registered read, so
//  a single output register cannot sustain reads on consecutive cycles -- the
//  read register lags the read pointer by one clock and returns a stale/duplicate
//  sample on back-to-back pops. That fault is invisible with AXI4-Lite single
//  reads (which are always spaced by the address/data handshakes) but is a real
//  latent bug. This module carries TWO buffered stages -- bram_dout (stage 1, in
//  the BRAM output register) and head (stage 2) -- whose depth exactly covers the
//  1-cycle BRAM latency, so it is correct for arbitrary pop timing, including a
//  pop every clock, at no extra fabric-FF cost versus a single output register.
//
//  Write side is NEVER backpressured: on a write while full the new sample is
//  dropped (older queued samples preserved in order) and overflow_flag is set,
//  sticky until clr_overflow pulses (tied by the instantiating top level to a
//  read of its status register -- MPX_FIFO_STAT or AUDIO_FIFO_STAT in
//  axi_sdr_fm.v). Full is measured on total occupancy (BRAM + both stages), so
//  capacity is exactly DEPTH, unchanged from the distributed-RAM version.
//
//  count/empty are gated on the head stage: count>0 <=> !empty <=> head ready.
//  A written sample not yet propagated to the head stage is briefly not reflected
//  in count (reads 0 / empty=1) until it is actually poppable -- so polling the
//  status register (e.g. MPX_FIFO_STAT) before the data register (e.g.
//  MPX_FIFO_DATA) never returns a sample before rd_data can supply it. The only
//  behavioural difference vs. distributed RAM is a few extra clocks of latency
//  from a write into an empty FIFO to visibility (~3 vs 1); on a
//  continuously-fed, polled FIFO this is invisible. (A write-through bypass of
//  wr_data straight into the head stage on empty would restore ~1-cycle latency,
//  at the cost of one DATA_W-wide mux -- LUTs, which is why it is deliberately
//  omitted here.)
//
//  Popping an empty FIFO is a no-op on the pointers (no underflow); rd_data then
//  shows stale data -- software must check count/empty via the status register
//  before reading the data register.
// =============================================================================
module mpx_sample_fifo #(
    parameter integer DEPTH  = 1024,   // must be a power of 2
    parameter integer DATA_W = 16
) (
    input  wire                     clk,
    input  wire                     rst_n,

    input  wire                     wr_en,
    input  wire signed [DATA_W-1:0] wr_data,

    input  wire                     rd_pop,
    output wire signed [DATA_W-1:0] rd_data,

    output wire [$clog2(DEPTH):0]   count,
    output wire                     empty,

    input  wire                     clr_overflow,
    output reg                      overflow_flag
);

    localparam integer ADDR_W = $clog2(DEPTH);

    (* ram_style = "block" *)
    reg signed [DATA_W-1:0] mem [0:DEPTH-1];
    reg signed [DATA_W-1:0] bram_dout;          // stage 1: BRAM output register (reset-free)

    reg [ADDR_W-1:0] wr_ptr, rd_ptr;
    reg [ADDR_W:0]   mem_cnt;                    // words resident in BRAM (behind rd_ptr)
    reg signed [DATA_W-1:0] head;               // stage 2: presented head
    reg              d1_vld, head_vld;          // stage-1 / stage-2 valid (head_vld == !empty)

    wire [ADDR_W:0] occ = mem_cnt + {{ADDR_W{1'b0}}, d1_vld}
                                  + {{ADDR_W{1'b0}}, head_vld};
    wire full = (occ == DEPTH[ADDR_W:0]);

    assign rd_data = head;
    assign empty   = ~head_vld;
    assign count   = head_vld ? occ : {(ADDR_W+1){1'b0}};   // count>0 <=> !empty

    wire do_write   = wr_en && !full;
    wire pop        = rd_pop && head_vld;                    // real head pop
    wire load_head  = d1_vld && (!head_vld || pop);          // stage1 -> stage2
    wire do_bram_rd = (mem_cnt != {(ADDR_W+1){1'b0}}) && (!d1_vld || load_head);

    // Reset-free BRAM block: keeps bram_dout in the RAMB output register.
    always @(posedge clk) begin
        if (do_write)   mem[wr_ptr] <= wr_data;
        if (do_bram_rd) bram_dout   <= mem[rd_ptr];
    end

    // Control / pointers / output stage (async reset, but does NOT touch bram_dout).
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr        <= {ADDR_W{1'b0}};
            rd_ptr        <= {ADDR_W{1'b0}};
            mem_cnt       <= {(ADDR_W+1){1'b0}};
            d1_vld        <= 1'b0;
            head_vld      <= 1'b0;
            overflow_flag <= 1'b0;
        end else begin
            if (do_write)   wr_ptr <= wr_ptr + 1'b1;
            if (do_bram_rd) rd_ptr <= rd_ptr + 1'b1;

            case ({do_write, do_bram_rd})
                2'b10:   mem_cnt <= mem_cnt + 1'b1;
                2'b01:   mem_cnt <= mem_cnt - 1'b1;
                default: mem_cnt <= mem_cnt;
            endcase

            if (do_bram_rd)     d1_vld <= 1'b1;
            else if (load_head) d1_vld <= 1'b0;

            if (load_head) begin
                head     <= bram_dout;
                head_vld <= 1'b1;
            end else if (pop) begin
                head_vld <= 1'b0;
            end

            if (wr_en && full)
                overflow_flag <= 1'b1;
            else if (clr_overflow)
                overflow_flag <= 1'b0;
        end
    end

endmodule