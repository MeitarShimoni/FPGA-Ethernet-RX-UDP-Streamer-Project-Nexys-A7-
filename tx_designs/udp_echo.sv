`timescale 1ns/1ps
//=============================================================================
// udp_echo.sv
//
// UDP echo engine: captures each payload emitted by udp_rx into a buffer,
// then streams a complete reply (IP header + UDP header + payload) into
// tx_ethernet with all three address levels swapped:
//
//     dst MAC  = the frame's source MAC   (latched by udp_rx rev B)
//     dst IP   = the packet's source IP    src IP   = OUR_IP
//     dst port = the packet's source port  src port = LISTEN_PORT
//
// Why buffer instead of streaming through: the reply's IP total-length and
// UDP length fields are transmitted BEFORE the payload, so the payload size
// must be known before the first header byte leaves. Whole-payload capture
// first, then build -- the TX-side twin of the RX FIFO's "whole frames only".
//
// The IP header checksum is computed combinationally from registers once
// the length is known (a handful of 16-bit adds -- easy at 50 MHz).
// UDP checksum is sent as 0000 = "not used" (legal in IPv4).
//
// Busy policy (v1): payload arriving while a reply is still transmitting is
// dropped -- the buffer must not be overwritten mid-send. At 100 Mbps with
// small payloads this window is microseconds.
//=============================================================================
module udp_echo #(
    parameter logic [31:0] OUR_IP      = {8'd192, 8'd168, 8'd1, 8'd2},
    parameter logic [15:0] LISTEN_PORT = 16'd5000
)(
    input  logic        clk,
    input  logic        rst_n,

    // From udp_rx
    input  logic [7:0]  pay_data,
    input  logic        pay_valid,
    input  logic        pay_last,
    input  logic [47:0] peer_mac,
    input  logic [31:0] peer_ip,
    input  logic [15:0] peer_port,

    // To tx_ethernet
    output logic [47:0] dst_mac,
    output logic [15:0] ether_type,
    output logic [7:0]  pl_data,
    output logic        pl_valid,
    output logic        pl_last,
    input  logic        pl_ready,

    output logic        busy
);

    assign ether_type = 16'h0800;

    //-------------------------------------------------------------------------
    // Payload buffer (BRAM template: write in a reset-free process)
    //-------------------------------------------------------------------------
    (* ram_style = "block" *) logic [7:0] ram [2048];

    logic [10:0] wcnt;                 // capture write pointer
    logic [10:0] plen;                 // captured payload length
    logic [10:0] raddr;
    logic [7:0]  ram_q;

    typedef enum logic [1:0] {CAPTURE, SEND} state_t;
    state_t state;

    wire capturing = (state == CAPTURE);

    always_ff @(posedge clk) begin                       // write port
        if (capturing && pay_valid)
            ram[wcnt] <= pay_data;
    end

    // always_ff @(posedge clk)                             // read port
    //     ram_q <= ram[raddr];
    wire rd_en = (state == CAPTURE) || advance;

    always_ff @(posedge clk) begin                       // read port
        if (rd_en)
            ram_q <= ram[raddr];
    end

    // ============================ DEBUG ======================================
    // Add this for debug
    logic [10:0] packet_counter;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            packet_counter <= 0;
        end else begin
            if (state == CAPTURE && pay_valid) packet_counter <= packet_counter + 1;
            else if (state == CAPTURE && pay_last) packet_counter <= 0;
        end
    end

    //-------------------------------------------------------------------------
    // Reply fields, latched at capture completion
    //-------------------------------------------------------------------------
    logic [31:0] peer_ip_q;
    logic [15:0] peer_port_q;

    wire [15:0] ip_total  = 16'd28 + {5'b0, plen};       // 20 + 8 + payload
    wire [15:0] udp_total = 16'd8  + {5'b0, plen};

    // IPv4 header checksum: one's-complement sum of the header's 16-bit
    // words (checksum field itself excluded), folded, inverted.
    function automatic logic [15:0] fold(input logic [31:0] s);
        logic [31:0] t;
        t = (s & 32'h0000FFFF) + (s >> 16);
        t = (t & 32'h0000FFFF) + (t >> 16);
        return ~t[15:0];
    endfunction

    wire [31:0] csum_acc = 32'h4500 + ip_total + 32'h0001 + 32'h0000
                         + 32'h4011
                         + OUR_IP[31:16]    + OUR_IP[15:0]
                         + peer_ip_q[31:16] + peer_ip_q[15:0];
    wire [15:0] ip_csum = fold(csum_acc);

    // Reply header byte mux: idx 0..19 IP header, 20..27 UDP header
    function automatic logic [7:0] hdr_byte(input logic [10:0] idx);
        case (idx)
            11'd0:  return 8'h45;
            11'd1:  return 8'h00;
            11'd2:  return ip_total[15:8];
            11'd3:  return ip_total[7:0];
            11'd4:  return 8'h00;                        // identification
            11'd5:  return 8'h01;
            11'd6:  return 8'h00;                        // flags/fragment
            11'd7:  return 8'h00;
            11'd8:  return 8'h40;                        // TTL = 64
            11'd9:  return 8'h11;                        // protocol = UDP
            11'd10: return ip_csum[15:8];
            11'd11: return ip_csum[7:0];
            11'd12: return OUR_IP[31:24];
            11'd13: return OUR_IP[23:16];
            11'd14: return OUR_IP[15:8];
            11'd15: return OUR_IP[7:0];
            11'd16: return peer_ip_q[31:24];
            11'd17: return peer_ip_q[23:16];
            11'd18: return peer_ip_q[15:8];
            11'd19: return peer_ip_q[7:0];
            11'd20: return LISTEN_PORT[15:8];            // reply src port
            11'd21: return LISTEN_PORT[7:0];
            11'd22: return peer_port_q[15:8];            // reply dst port
            11'd23: return peer_port_q[7:0];
            11'd24: return udp_total[15:8];
            11'd25: return udp_total[7:0];
            default: return 8'h00;                       // 26,27: UDP csum = 0
        endcase
    endfunction

    //-------------------------------------------------------------------------
    // FSM: capture a payload, then stream the reply (28 header bytes + plen)
    //-------------------------------------------------------------------------
    logic [10:0] idx;                                    // reply byte index

    wire [10:0] total_reply = 11'd28 + plen;
    wire        in_payload  = (idx >= 11'd28);

    assign pl_valid = (state == SEND);
    assign pl_data  = in_payload ? ram_q : hdr_byte(idx);
    assign pl_last  = (state == SEND) && (idx == total_reply - 11'd1);
    assign busy     = (state == SEND);

    wire advance = pl_valid && pl_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= CAPTURE;
            wcnt        <= '0;
            plen        <= '0;
            idx         <= '0;
            raddr       <= '0;
            dst_mac     <= '0;
            peer_ip_q   <= '0;
            peer_port_q <= '0;
        end else begin
            case (state)
                CAPTURE: begin
                    if (pay_valid) begin
                        wcnt <= wcnt + 11'd1;
                        if (pay_last) begin
                            plen        <= wcnt + 11'd1;
                            dst_mac     <= peer_mac;     // swap #1: MAC
                            peer_ip_q   <= peer_ip;      // swap #2: IP
                            peer_port_q <= peer_port;    // swap #3: port
                            idx         <= '0;
                            raddr       <= '0;           // prefetch ram[0]
                            state       <= SEND;
                        end
                    end
                end

                // SEND: if (advance) begin
                //     idx <= idx + 11'd1;
                //     // keep ram_q one byte ahead of the payload index
                //     raddr <= (idx + 11'd1 >= 11'd28) ? (idx + 11'd1 - 11'd27)
                //                                      : 11'd0;
                //     if (pl_last) begin
                //         state <= CAPTURE;
                //         wcnt  <= '0;
                //     end
                // end
                SEND: if (advance) begin
                    idx <= idx + 11'd1;
                    
                    // Logic: 
                    // When idx is 27, we want raddr to be 0 for the next cycle (pl_data starts reading RAM)
                    if (idx == 11'd27)
                        raddr <= 11'd0;
                    else if (idx >= 11'd28)
                        raddr <= raddr + 11'd1;
                        
                    if (pl_last) begin
                        state <= CAPTURE;
                        wcnt  <= '0;
                    end
                end

                default: state <= CAPTURE;
            endcase
        end
    end

endmodule
