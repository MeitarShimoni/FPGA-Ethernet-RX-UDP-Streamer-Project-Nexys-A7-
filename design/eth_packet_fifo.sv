`timescale 1ns/1ps
//=============================================================================
// eth_packet_fifo.sv
//
// Packet FIFO with commit/rewind -- the "frame quarantine" between
// eth_frame_rx and the protocol parsers (ARP/ICMP/UDP).
//
// Problem it solves:
//   eth_frame_rx streams bytes out *speculatively* -- only at frame_done do
//   we learn whether the frame was good (CRC). Downstream logic must never
//   see a corrupt frame.
//
// How:
//   * Bytes are written at the speculative write pointer (wr_ptr).
//   * A second pointer (wr_ptr_c) marks the last COMMITTED position.
//   * The reader's "empty" is computed against wr_ptr_c, so in-flight
//     (unverified) bytes are invisible to it.
//   * At frame_done:
//       - frame_ok  -> commit: wr_ptr_c jumps forward to wr_ptr, and the
//                      final byte's LAST flag is set (see below)
//       - !frame_ok -> rewind: wr_ptr jumps back to wr_ptr_c; the frame
//                      vanishes as if it never arrived
//
// Frame boundaries:
//   Each stored word is 9 bits: {last, data}. The LAST flag can't be known
//   while writing (frame length is unknown until the carrier drops), so at
//   commit time the final byte is re-written with its flag set. This is why
//   frame_done must never coincide with wr_valid -- guaranteed by
//   eth_frame_rx (frame_done arrives >= 1 cycle after the last m_valid)
//   and checked by an assertion below.
//
// Overflow policy:
//   If the FIFO fills mid-frame, the frame is "poisoned" (ovf flag),
//   further bytes are ignored, and at frame_done it is rewound and reported
//   via frame_dropped -- exactly like a CRC failure. Frames are all-or-
//   nothing: the reader never sees a truncated frame.
//
// Nice property for the read side:
//   Commits are whole-frame, so !empty guarantees at least one COMPLETE
//   frame is present. A parser can stream a frame start-to-end without
//   ever stalling mid-frame waiting for bytes.
//
// Read interface is first-word-fall-through with valid/ready handshake.
// This version is single-clock; converting to dual-clock (gray-coded
// wr_ptr_c / rd_ptr crossing) also solves the RMII->system CDC.
//=============================================================================
module eth_packet_fifo #(
    parameter int DEPTH = 2048            // must be a power of two
)(
    input  logic       clk,
    input  logic       rst_n,

    //--- Write side: connects 1:1 to eth_frame_rx outputs ------------------
    input  logic [7:0] wr_data,           // <- m_data
    input  logic       wr_valid,          // <- m_valid
    input  logic       frame_done,        // <- frame_done
    input  logic       frame_ok,          // <- frame_ok
    output logic       frame_dropped,     // 1-cycle pulse: frame discarded
                                          //   (bad CRC or overflow)

    //--- Read side: FWFT, valid/ready ---------------------------------------
    output logic [7:0] rd_data,
    output logic       rd_last,           // high on the final byte of a frame
    output logic       rd_valid,
    input  logic       rd_ready
);

    localparam int AW = $clog2(DEPTH);

    // {last, data}
    logic [8:0] mem [DEPTH];

    // Pointers carry one extra MSB to distinguish full from empty on wrap.
    logic [AW:0] wr_ptr;     // speculative write pointer
    logic [AW:0] wr_ptr_c;   // committed write pointer (reader's horizon)
    logic [AW:0] rd_ptr;

    wire full  = (wr_ptr[AW] != rd_ptr[AW]) &&
                 (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]);
    wire empty = (rd_ptr == wr_ptr_c);

    //-------------------------------------------------------------------------
    // Write / commit / rewind
    //-------------------------------------------------------------------------
    logic [7:0] last_byte;   // most recent byte, kept for the LAST-flag fixup
    logic       wrote_any;   // current frame has >= 1 stored byte
    logic       ovf;         // current frame hit a full FIFO -> will be dropped

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr        <= '0;
            wr_ptr_c      <= '0;
            wrote_any     <= 1'b0;
            ovf           <= 1'b0;
            frame_dropped <= 1'b0;
        end else begin
            frame_dropped <= 1'b0;

            if (wr_valid && !ovf) begin
                if (full) begin
                    ovf <= 1'b1;                       // poison the frame
                end else begin
                    mem[wr_ptr[AW-1:0]] <= {1'b0, wr_data};
                    last_byte           <= wr_data;
                    wr_ptr              <= wr_ptr + 1'b1;
                    wrote_any           <= 1'b1;
                end
            end

            if (frame_done) begin
                if (frame_ok && wrote_any && !ovf) begin
                    // Fix up the LAST flag on the final byte, then publish
                    // the frame by advancing the committed pointer.
                    mem[(wr_ptr[AW-1:0] - 1'b1)] <= {1'b1, last_byte};
                    wr_ptr_c <= wr_ptr;
                end else begin
                    wr_ptr <= wr_ptr_c;                // rewind
                    if (wrote_any || ovf)
                        frame_dropped <= 1'b1;
                end
                wrote_any <= 1'b0;
                ovf       <= 1'b0;
            end
        end
    end

`ifndef SYNTHESIS
    // The commit-cycle LAST-flag fixup borrows the write port, so a data
    // write must never coincide with frame_done. eth_frame_rx guarantees
    // this by construction.
    no_write_on_done: assert property (
        @(posedge clk) disable iff (!rst_n) !(wr_valid && frame_done))
        else $error("wr_valid and frame_done asserted in the same cycle");
`endif

    //-------------------------------------------------------------------------
    // Read side: first-word-fall-through
    // rd_en fires when there is data and the output register is free
    // (or being consumed this cycle).
    //-------------------------------------------------------------------------
    wire rd_en = !empty && (!rd_valid || rd_ready);

    logic [8:0] rd_word;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr   <= '0;
            rd_valid <= 1'b0;
            rd_word  <= '0;
        end else begin
            if (rd_en) begin
                rd_word  <= mem[rd_ptr[AW-1:0]];
                rd_ptr   <= rd_ptr + 1'b1;
                rd_valid <= 1'b1;
            end else if (rd_valid && rd_ready) begin
                rd_valid <= 1'b0;                      // consumed, nothing new
            end
        end
    end

    assign {rd_last, rd_data} = rd_word;

endmodule
