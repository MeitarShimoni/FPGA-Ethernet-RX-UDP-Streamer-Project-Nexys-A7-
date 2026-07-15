module Chip_Top (
    input  logic       clk,          // 100 MHz board oscillator
    input  logic       rst_n,        // active-low reset (check button polarity!)

    // Ethernet RMII / PHY
    input  logic [1:0] rmii_rxd,
    input  logic       rmii_crs_dv,
    output logic       eth_refclk,   // 50 MHz to PHY (via ODDR)
    output logic       eth_rstn,     // PHY reset, active low
    output logic       eth_txen,

    // 7-segment display
    output logic [6:0] cathodes_out,
    output logic [7:0] anodes,

    output logic red_led_1,
    output logic blue_led_1,

    output logic red_led_2,
    output logic blue_led_2
);

    // ---------------- declarations ----------------
    logic        clk50, locked, sys_rst_n;
    logic [7:0]  rd_data;
    logic        rd_last, rd_valid, rd_ready;
    logic        frame_dropped, mac_reject;
    logic [19:0] phy_rst_cnt;
    logic [15:0]  frame_count;

    // =============== DEBUG LEDs =================
    assign red_led_1  = frame_dropped;
    assign blue_led_2 = mac_reject;

    assign red_led_2  = 1'b0;
    assign blue_led_1 = 1'b0;

    // ============================================





    assign rd_ready = 1'b1;
    assign eth_txen = 1'b0;

    // ---------------- clocking & reset ----------------
    clk_wiz_0 clock_gen_50 (
        .clk_in1 (clk),
        .resetn  (rst_n),            // RAW reset into the PLL
        .locked  (locked),
        .clk_out1(clk50)
    );

    assign sys_rst_n = locked & rst_n;   // downstream reset, lock-qualified

    // 50 MHz out to the PHY, launched from the IOB register
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC"))
    u_refclk_fwd (
        .Q(eth_refclk), .C(clk50), .CE(1'b1),
        .D1(1'b1), .D2(1'b0), .R(1'b0), .S(1'b0)
    );

    // PHY reset sequencer: hold low ~21 ms after PLL lock, then release
    always_ff @(posedge clk50 or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            phy_rst_cnt <= '0;
            eth_rstn    <= 1'b0;
        end else if (!(&phy_rst_cnt))
            phy_rst_cnt <= phy_rst_cnt + 1'b1;
        else
            eth_rstn    <= 1'b1;
    end

    // ---------------- RX chain ----------------
    rx_ethernet eth_rx (
        .clk50         (clk50),
        .rst_n         (sys_rst_n),
        .rmii_rxd      (rmii_rxd),
        .rmii_crs_dv   (rmii_crs_dv),
        .rd_data       (rd_data),
        .rd_last       (rd_last),
        .rd_valid      (rd_valid),
        .rd_ready      (rd_ready),
        .frame_dropped (frame_dropped),
        .mac_reject    (mac_reject)
    );

    // ---------------- first-light indicator ----------------
    always_ff @(posedge clk50 or negedge sys_rst_n) begin
        if (!sys_rst_n)               frame_count <= '0;
        else if (rd_valid && rd_last) frame_count <= frame_count + 1'b1;
    end

    seven_segment segment_display (
        .system_clock (clk50),        // same domain as frame_count!
        .cpu_rst_n    (sys_rst_n),
        .display_val  ({rd_data,8'd0,frame_count}),
        .cathodes_out (cathodes_out),
        .anodes       (anodes)
    );

endmodule