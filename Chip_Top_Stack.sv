module Chip_Top_Stack #(parameter int PHY_RST_W = 20 )(
    input  logic       clk,          // 100 MHz board oscillator
    input  logic       rst_n,        // active-low reset (check button polarity!)

    // Ethernet RMII / PHY
    input  logic [1:0] rmii_rxd,
    input  logic       rmii_crs_dv,
    output logic       eth_refclk,   // 50 MHz to PHY (via ODDR)
    output logic       eth_rstn,     // PHY reset, active low

    output logic       rmii_tx_en,
    output logic [1:0] rmii_txd,


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
    logic [PHY_RST_W-1:0] phy_rst_cnt;
    logic [31:0]  frame_count;


    localparam logic [47:0] FPGA_MAC  = 48'h02_00_00_00_00_01;
    localparam logic [47:0] PC_MAC    = 48'h02_00_00_00_00_AA;
    localparam logic [31:0] FPGA_IP   = {8'd192, 8'd168, 8'd1, 8'd2};
    localparam logic [31:0] PC_IP     = {8'd192, 8'd168, 8'd1, 8'd1};
    localparam logic [15:0] FPGA_PORT = 16'd5000;
    localparam logic [15:0] PC_PORT   = 16'hC738;

    // =============== DEBUG LEDs =================
    assign red_led_1  = frame_dropped;
    // assign blue_led_2 = mac_reject;

    assign red_led_2  = 1'b0;
    assign blue_led_1 = 1'b0;

    // ============================================
    logic [7:0] pay_data;
    logic       pay_valid;
    logic       pay_last;
    logic       echo_busy;





    assign rd_ready = 1'b1;
    // assign eth_txen = 1'b0;

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


    net_stack #(
        .MAC_ADDR   (FPGA_MAC),
        .OUR_IP     (FPGA_IP),
        .LISTEN_PORT(FPGA_PORT)
    ) ethernet_core_top (
        .clk50         (clk50),
        .rst_n         (sys_rst_n),
        .rmii_rxd      (rmii_rxd),
        .rmii_crs_dv   (rmii_crs_dv),
        .rmii_txd      (rmii_txd),
        .rmii_tx_en    (rmii_tx_en),
        .pay_data      (pay_data),
        .pay_valid     (pay_valid),
        .pay_last      (pay_last),
        .frame_dropped (frame_dropped),
        .mac_reject    (mac_reject),
        .echo_busy     (echo_busy)
    );

    logic [7:0] last_pay_byte;

    always_ff @(posedge clk50 or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            frame_count   <= '0;
            last_pay_byte <= '0;
        end else begin
            // Latch the most recent payload byte
            if (pay_valid) begin
                last_pay_byte <= pay_data;
            end
            
            // Increment frame counter when a payload finishes
            if (pay_valid && pay_last) begin
                frame_count <= frame_count + 1'b1;
            end
        end
    end

    seven_segment segment_display (
        .system_clock (clk50),        // same domain as frame_count!
        .cpu_rst_n    (sys_rst_n),
        .display_val  ({last_pay_byte,8'd0,frame_count[15:0]}),
        .cathodes_out (cathodes_out),
        .anodes       (anodes)
    );

endmodule