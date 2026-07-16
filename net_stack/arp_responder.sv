`timescale 1ns/1ps
//=============================================================================
// arp_responder.sv
//
// Answers "who has OUR_IP?" -- the module that makes the FPGA visible to
// arp -a and, transitively, to ping and unicast UDP with zero PC-side
// configuration.
//
// RX side: passively taps the FIFO read stream (rd_ready is owned by
// udp_rx and is constant 1; this module only observes the handshake).
// It walks an ARP request's fixed layout -- offsets within the frame:
//
//   12-13  EtherType        = 08 06
//   14-17  HTYPE/PTYPE      = 0001 / 0800   (Ethernet / IPv4)
//   18-19  HLEN/PLEN        = 06 / 04
//   20-21  OPER             = 0001          (request)
//   22-27  SHA  sender MAC  -> latched (reply destination)
//   28-31  SPA  sender IP   -> latched (reply target IP)
//   38-41  TPA  target IP   must equal OUR_IP
//
// Any mismatch clears 'hit'; a frame ending with hit still set and all 42
// bytes seen queues a reply. No payload buffering is needed -- the reply
// is a fixed 28-byte message built from registers (compare udp_echo, which
// must buffer because its lengths are variable).
//
// Reply: OPER=0002, our MAC/IP as sender, their MAC/IP as target, sent as
// an EtherType 0x0806 frame to their MAC. eth_frame_tx pads it to 60.
//=============================================================================
module arp_responder #(
    parameter logic [47:0] OUR_MAC = 48'h02_00_00_00_00_01,
    parameter logic [31:0] OUR_IP  = {8'd192, 8'd168, 8'd1, 8'd2}
)(
    input  logic        clk,
    input  logic        rst_n,

    // Tap on the FIFO read stream
    input  logic [7:0]  rd_data,
    input  logic        rd_valid,
    input  logic        rd_last,
    input  logic        rd_ready,

    // TX request (to the arbiter)
    output logic [47:0] dst_mac,
    output logic [15:0] ether_type,
    output logic [7:0]  pl_data,
    output logic        pl_valid,
    output logic        pl_last,
    input  logic        pl_ready
);

    assign ether_type = 16'h0806;

    wire take = rd_valid && rd_ready;

    //-------------------------------------------------------------------------
    // Parse
    //-------------------------------------------------------------------------
    logic [10:0] cnt;
    logic        hit;
    logic [47:0] sha;
    logic [31:0] spa;

    // Expected constant for offsets 12..21 (0 = not constant / handled apart)
    function automatic logic [7:0] want(input logic [10:0] idx);
        case (idx)
            11'd12: return 8'h08;  11'd13: return 8'h06;   // EtherType
            11'd14: return 8'h00;  11'd15: return 8'h01;   // HTYPE
            11'd16: return 8'h08;  11'd17: return 8'h00;   // PTYPE
            11'd18: return 8'h06;  11'd19: return 8'h04;   // HLEN/PLEN
            11'd20: return 8'h00;  11'd21: return 8'h01;   // OPER = request
            default: return 8'h00;
        endcase
    endfunction

    //-------------------------------------------------------------------------
    // Reply builder (28-byte ARP message from registers)
    //-------------------------------------------------------------------------
    logic        sending, pending;
    logic [47:0] sha_q;
    logic [31:0] spa_q;
    logic [4:0]  idx;

    function automatic logic [7:0] reply_byte(input logic [4:0] i);
        case (i)
            5'd0:  return 8'h00;  5'd1:  return 8'h01;     // HTYPE
            5'd2:  return 8'h08;  5'd3:  return 8'h00;     // PTYPE
            5'd4:  return 8'h06;  5'd5:  return 8'h04;     // HLEN/PLEN
            5'd6:  return 8'h00;  5'd7:  return 8'h02;     // OPER = reply
            5'd8, 5'd9, 5'd10, 5'd11, 5'd12, 5'd13:        // SHA = us
                   return 8'((OUR_MAC >> (8 * (13 - i))));
            5'd14, 5'd15, 5'd16, 5'd17:                    // SPA = our IP
                   return 8'((OUR_IP  >> (8 * (17 - i))));
            5'd18, 5'd19, 5'd20, 5'd21, 5'd22, 5'd23:      // THA = them
                   return 8'((sha_q   >> (8 * (23 - i))));
            default:                                       // 24-27 TPA = them
                   return 8'((spa_q   >> (8 * (27 - i))));
        endcase
    endfunction

    assign pl_valid = sending;
    assign pl_data  = reply_byte(idx);
    assign pl_last  = sending && (idx == 5'd27);
    assign dst_mac  = sha_q;

    wire advance = pl_valid && pl_ready;

    //-------------------------------------------------------------------------
    // Control
    //-------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt     <= '0;
            hit     <= 1'b1;
            sha     <= '0;
            spa     <= '0;
            sha_q   <= '0;
            spa_q   <= '0;
            pending <= 1'b0;
            sending <= 1'b0;
            idx     <= '0;
        end else begin
            // ---- parse side ----
            if (take) begin
                cnt <= cnt + 11'd1;

                if (cnt >= 11'd12 && cnt <= 11'd21) begin
                    if (rd_data != want(cnt)) hit <= 1'b0;
                end
                else if (cnt >= 11'd22 && cnt <= 11'd27)
                    sha <= {sha[39:0], rd_data};
                else if (cnt >= 11'd28 && cnt <= 11'd31)
                    spa <= {spa[23:0], rd_data};
                else if (cnt >= 11'd38 && cnt <= 11'd41) begin
                    if (rd_data != 8'((OUR_IP >> (8 * (11'd41 - cnt)))))
                        hit <= 1'b0;
                end

                if (rd_last) begin
                    if (hit && cnt >= 11'd41 && !sending) begin
                        pending <= 1'b1;
                        sha_q   <= sha;          // snapshot: the parse regs
                        spa_q   <= spa;          // may be overwritten by the
                    end                          // next frame during the send
                    cnt <= '0;
                    hit <= 1'b1;
                end
            end

            // ---- send side ----
            if (!sending && pending) begin
                sending <= 1'b1;
                pending <= 1'b0;
                idx     <= '0;
            end else if (advance) begin
                idx <= idx + 5'd1;
                if (pl_last) sending <= 1'b0;
            end
        end
    end

endmodule
