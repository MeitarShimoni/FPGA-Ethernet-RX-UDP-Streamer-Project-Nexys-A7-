// rx_ethernet.sv
module rx_ethernet #(
    parameter int FIFO_DEPTH = 2048
)(
    input  logic       clk50,
    input  logic       rst_n,

    // RMII pins from PHY
    input  logic [1:0] rmii_rxd,
    input  logic       rmii_crs_dv,

    // Clean frame stream out (FIFO read side, FWFT)
    output logic [7:0] rd_data,
    output logic       rd_last,
    output logic       rd_valid,
    input  logic       rd_ready,       // note: an INPUT -- consumer drives it

    // Status (nice for LEDs/debug)
    output logic       frame_dropped
);

    // Stage 1 -> Stage 2
    logic [7:0] rx_data;
    logic       rx_valid, rx_frame_end;

    // Stage 2 -> Stage 3 (now internal!)
    logic [7:0] m_data;
    logic       m_valid, frame_done, frame_ok;

    rmii_rx u_rmii (
        .clk50        (clk50),
        .rst_n        (rst_n),
        .rmii_rxd     (rmii_rxd),
        .rmii_crs_dv  (rmii_crs_dv),
        .rx_data      (rx_data),
        .rx_valid     (rx_valid),
        .rx_frame_end (rx_frame_end)
    );

    eth_frame_rx u_mac (
        .clk          (clk50),
        .rst_n        (rst_n),
        .rx_data      (rx_data),
        .rx_valid     (rx_valid),
        .rx_frame_end (rx_frame_end),
        .m_data       (m_data),
        .m_valid      (m_valid),
        .frame_done   (frame_done),
        .frame_ok     (frame_ok)
    );

    eth_packet_fifo #(.DEPTH(FIFO_DEPTH)) u_fifo (
        .clk           (clk50),
        .rst_n         (rst_n),
        // write side: names line up 1:1 with the parser outputs
        .wr_data       (m_data),
        .wr_valid      (m_valid),
        .frame_done    (frame_done),
        .frame_ok      (frame_ok),
        .frame_dropped (frame_dropped),
        // read side: straight to the top-level ports
        .rd_data       (rd_data),
        .rd_last       (rd_last),
        .rd_valid      (rd_valid),
        .rd_ready      (rd_ready)
    );

endmodule