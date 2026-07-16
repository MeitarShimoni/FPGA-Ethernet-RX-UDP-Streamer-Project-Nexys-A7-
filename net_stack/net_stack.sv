`timescale 1ns/1ps
//=============================================================================
// net_stack.sv
//
// The network stack, one module -- supersedes udp_echo_system:
//
//                       +-> udp_rx --+-> udp_echo ---> port B \
//   RMII -> rx_ethernet-+            +-> pay_* taps            +-> tx_mux2
//                       +-> arp_responder ---------> port A   /      |
//                                                              tx_ethernet -> RMII
//
// Both parsers tap the same FIFO read stream (rd_ready is udp_rx's
// constant 1; arp_responder observes the handshake passively). Each is
// selective by construction, so no explicit dispatcher logic is needed --
// the "dispatch" is every parser bailing on frames that aren't its own.
//
// In Chip_Top: replace the udp_echo_system instance with net_stack
// (identical ports). Behavior added: the FPGA now answers ARP -- after
// programming, `arp -a` on the PC shows MAC_ADDR against OUR_IP, ping's
// address resolution succeeds, and unicast UDP needs no netsh tricks.
//=============================================================================
module net_stack #(
    parameter logic [47:0] MAC_ADDR    = 48'h02_00_00_00_00_01,
    parameter logic [31:0] OUR_IP      = {8'd192, 8'd168, 8'd1, 8'd2},
    parameter logic [15:0] LISTEN_PORT = 16'd5000,
    parameter int          FIFO_DEPTH  = 2048
)(
    input  logic       clk50,
    input  logic       rst_n,

    // RMII pins
    input  logic [1:0] rmii_rxd,
    input  logic       rmii_crs_dv,
    output logic [1:0] rmii_txd,
    output logic       rmii_tx_en,

    // Add Stream Inputs
    
    // Add Stream Outputs

    // Taps for display / debug
    output logic [7:0] pay_data,
    output logic       pay_valid,
    output logic       pay_last,
    output logic       frame_dropped,
    output logic       mac_reject,
    output logic       echo_busy
);

    // RX stream (shared by both parsers)
    logic [7:0]  rd_data;
    logic        rd_last, rd_valid, rd_ready;

    // udp_rx -> udp_echo
    logic [47:0] src_mac;
    logic [31:0] src_ip;
    logic [15:0] src_port;

    // producers -> arbiter
    logic [47:0] a_dst_mac,  b_dst_mac;
    logic [15:0] a_type,     b_type;
    logic [7:0]  a_data,     b_data;
    logic        a_valid, a_last, a_ready;
    logic        b_valid, b_last, b_ready;

    logic [47:0] c_dst_mac;
    logic [15:0] c_type;
    logic [7:0]  c_data;
    logic        c_valid; 
    logic        c_last; 
    logic        c_ready;


    // arbiter -> tx
    logic [47:0] dst_mac;
    logic [15:0] ether_type;
    logic [7:0]  pl_data;
    logic        pl_valid, pl_last, pl_ready;

    rx_ethernet #(.MAC_ADDR(MAC_ADDR), .FIFO_DEPTH(FIFO_DEPTH)) u_rx (
        .clk50         (clk50),
        .rst_n         (rst_n),
        .rmii_rxd      (rmii_rxd),
        .rmii_crs_dv   (rmii_crs_dv),
        .rd_data       (rd_data),
        .rd_last       (rd_last),
        .rd_valid      (rd_valid),
        .rd_ready      (rd_ready),
        .frame_dropped (frame_dropped),
        .mac_reject    (mac_reject)
    );

    udp_rx #(.LISTEN_PORT(LISTEN_PORT)) u_udp (
        .clk       (clk50),
        .rst_n     (rst_n),
        .rd_data   (rd_data),
        .rd_valid  (rd_valid),
        .rd_last   (rd_last),
        .rd_ready  (rd_ready),
        .pay_data  (pay_data),
        .pay_valid (pay_valid),
        .pay_last  (pay_last),
        .src_mac   (src_mac),
        .src_ip    (src_ip),
        .src_port  (src_port)
    );

    arp_responder #(.OUR_MAC(MAC_ADDR), .OUR_IP(OUR_IP)) u_arp (
        .clk        (clk50),
        .rst_n      (rst_n),
        .rd_data    (rd_data),
        .rd_valid   (rd_valid),
        .rd_last    (rd_last),
        .rd_ready   (rd_ready),
        .dst_mac    (a_dst_mac),
        .ether_type (a_type),
        .pl_data    (a_data),
        .pl_valid   (a_valid),
        .pl_last    (a_last),
        .pl_ready   (a_ready)
    );

    udp_echo #(.OUR_IP(OUR_IP), .LISTEN_PORT(LISTEN_PORT)) u_echo (
        .clk       (clk50),
        .rst_n     (rst_n),
        .pay_data  (pay_data),
        .pay_valid (pay_valid),
        .pay_last  (pay_last),
        .peer_mac  (src_mac),
        .peer_ip   (src_ip),
        .peer_port (src_port),
        .dst_mac   (b_dst_mac),
        .ether_type(b_type),
        .pl_data   (b_data),
        .pl_valid  (b_valid),
        .pl_last   (b_last),
        .pl_ready  (b_ready),
        .busy      (echo_busy)
    );

    // tx_mux2 u_mux (
    //     .clk         (clk50),
    //     .rst_n       (rst_n),
    //     .a_dst_mac   (a_dst_mac),
    //     .a_ether_type(a_type),
    //     .a_pl_data   (a_data),
    //     .a_pl_valid  (a_valid),
    //     .a_pl_last   (a_last),
    //     .a_pl_ready  (a_ready),
    //     .b_dst_mac   (b_dst_mac),
    //     .b_ether_type(b_type),
    //     .b_pl_data   (b_data),
    //     .b_pl_valid  (b_valid),
    //     .b_pl_last   (b_last),
    //     .b_pl_ready  (b_ready),
    //     .dst_mac     (dst_mac),
    //     .ether_type  (ether_type),
    //     .pl_data     (pl_data),
    //     .pl_valid    (pl_valid),
    //     .pl_last     (pl_last),
    //     .pl_ready    (pl_ready)
    // );

        assign c_dst_mac = a_dst_mac;
        assign c_type    = a_type;

        tx_mux3 u_mux (
        .clk         (clk50),
        .rst_n       (rst_n),
        // PRIORITY: ARP wins over UDP echo
        .a_dst_mac   (a_dst_mac),
        .a_ether_type(a_type),
        .a_pl_data   (a_data),
        .a_pl_valid  (a_valid),
        .a_pl_last   (a_last),
        .a_pl_ready  (a_ready),
        // UDP echo is next in priority
        .b_dst_mac   (b_dst_mac),
        .b_ether_type(b_type),
        .b_pl_data   (b_data),
        .b_pl_valid  (b_valid),
        .b_pl_last   (b_last),
        .b_pl_ready  (b_ready),
        // UDP echo is next in priority
        .c_dst_mac   (c_dst_mac),
        .c_ether_type(c_type),
        .c_pl_data   (c_data),
        .c_pl_valid  (c_valid),
        .c_pl_last   (c_last),
        .c_pl_ready  (c_ready),
        
        .dst_mac     (dst_mac),
        .ether_type  (ether_type),
        .pl_data     (pl_data),
        .pl_valid    (pl_valid),
        .pl_last     (pl_last),
        .pl_ready    (pl_ready)
    );

    tx_ethernet #(.SRC_MAC(MAC_ADDR)) u_tx (
        .clk50      (clk50),
        .rst_n      (rst_n),
        .dst_mac    (dst_mac),
        .ether_type (ether_type),
        .pl_data    (pl_data),
        .pl_valid   (pl_valid),
        .pl_last    (pl_last),
        .pl_ready   (pl_ready),
        .rmii_txd   (rmii_txd),
        .rmii_tx_en (rmii_tx_en),
        .busy       ()
    );

endmodule
