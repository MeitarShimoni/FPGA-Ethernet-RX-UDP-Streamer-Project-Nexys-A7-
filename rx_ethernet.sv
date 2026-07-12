// rx_ethernet.sv


module rx_ethernet(
    input logic clk50,
    input logic rst_n,

    // INPUT RMII pins from PHY
    input logic [1:0] rmii_rxd,
    input logic rmii_crs_dv,

    // OUTPUT RX aligned byte stream (clk50 domain)
    output logic [7:0] m_data,
    output logic m_valid,
    output logic frame_done,
    output logic frame_ok
);
    logic [7:0] rx_data;
    logic       rx_valid, rx_frame_end;
    
    rmii_rx u_rmii (
        .clk50(clk50), .rst_n(rst_n),
        .rmii_rxd(rmii_rxd), .rmii_crs_dv(rmii_crs_dv),
        .rx_data(rx_data), .rx_valid(rx_valid), .rx_frame_end(rx_frame_end)
    );

    eth_frame_rx u_mac (
        .clk(clk50), .rst_n(rst_n),
        .rx_data(rx_data), .rx_valid(rx_valid), .rx_frame_end(rx_frame_end),
        .m_data(m_data), .m_valid(m_valid), .frame_done(frame_done), .frame_ok(frame_ok)
    );

endmodule