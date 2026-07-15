`timescale 1ns/1ps
//=============================================================================
// tb_Chip_Top.sv
//
// Lean smoke test for the hardware top. The full parsing chain is already
// verified by tb_udp_rx; this TB checks only what is unique to Chip_Top:
//   * clocking: clk_wiz lock -> sys_rst_n release
//   * PHY reset sequencer: eth_rstn eventually rises
//   * the last_pay_byte latch and its update on real UDP traffic
//
// Requirements on Chip_Top for this TB:
//   1. NO rd_ready port -- rd_ready is internal, driven by udp_rx.
//   2. Add a parameter so the ~21 ms PHY reset doesn't dominate sim time:
//
//        module Chip_Top #(parameter int PHY_RST_W = 20) ( ... );
//        ...
//        logic [PHY_RST_W-1:0] phy_rst_cnt;
//
//      (hardware keeps the default 20; this TB overrides it to 8)
//
// Note: frames are driven synchronous to dut.clk50 (hierarchical reference)
// -- the TB has no 50 MHz clock of its own; driving dibits off the 100 MHz
// board clock would send them at double speed.
//=============================================================================
module tb_Chip_Top;

    // ---------------- clocks & DUT I/O ----------------
    logic clk = 1'b0;
    always #5 clk = ~clk;                  // 100 MHz board oscillator

    logic       rst_n        = 1'b0;
    logic [1:0] rmii_rxd     = '0;
    logic       rmii_crs_dv  = 1'b0;
    logic       eth_refclk, eth_rstn, eth_txen;
    logic [6:0] cathodes_out;
    logic [7:0] anodes;

    Chip_Top #(.PHY_RST_W(8)) dut (       // short PHY reset for sim
        .clk          (clk),
        .rst_n        (rst_n),
        .rmii_rxd     (rmii_rxd),
        .rmii_crs_dv  (rmii_crs_dv),
        .eth_refclk   (eth_refclk),
        .eth_rstn     (eth_rstn),
        .eth_txen     (eth_txen),
        .cathodes_out (cathodes_out),
        .anodes       (anodes)
        // If you added LED ports to Chip_Top, connect them here as well.
    );

    // All RMII driving is synchronous to the DUT's internal 50 MHz clock
    wire clk50 = dut.clk50;

    int errors = 0;

    // ---------------- reference functions ----------------
    function automatic logic [31:0] crc32_byte
        (input logic [31:0] crc, input logic [7:0] data);
        logic [31:0] c;
        c = crc ^ {24'h0, data};
        for (int i = 0; i < 8; i++)
            c = c[0] ? (c >> 1) ^ 32'hEDB88320 : (c >> 1);
        return c;
    endfunction

    function automatic logic [15:0] ip_checksum(input logic [7:0] hdr[$]);
        int unsigned sum = 0;
        for (int i = 0; i < hdr.size(); i += 2)
            sum += {hdr[i], hdr[i+1]};
        while (sum > 32'h0000FFFF)
            sum = (sum & 32'h0000FFFF) + (sum >> 16);
        return ~sum[15:0];
    endfunction

    function automatic void make_udp_frame(
        output logic [7:0]  f[$],
        input  logic [15:0] dst_port,
        input  logic [7:0]  payload[$],
        input  logic [7:0]  ip_proto = 8'h11);

        logic [7:0]  iph[$];
        logic [15:0] ip_total, udp_total, csum;

        ip_total  = 16'd20 + 16'd8 + payload.size();
        udp_total = 16'd8 + payload.size();

        iph = '{8'h45, 8'h00,
                ip_total[15:8], ip_total[7:0],
                8'h00, 8'h01, 8'h00, 8'h00,
                8'h40, ip_proto,
                8'h00, 8'h00,
                8'hC0, 8'hA8, 8'h01, 8'h01,
                8'hC0, 8'hA8, 8'h01, 8'h02};
        csum    = ip_checksum(iph);
        iph[10] = csum[15:8];
        iph[11] = csum[7:0];

        f.delete();
        for (int i = 0; i < 6; i++) f.push_back(8'hFF);            // DA bcast
        f.push_back(8'h02); f.push_back(8'h00); f.push_back(8'h00);
        f.push_back(8'h00); f.push_back(8'h00); f.push_back(8'hAA);
        f.push_back(8'h08); f.push_back(8'h00);
        foreach (iph[i]) f.push_back(iph[i]);
        f.push_back(8'hC7); f.push_back(8'h38);                    // src port
        f.push_back(dst_port[15:8]); f.push_back(dst_port[7:0]);
        f.push_back(udp_total[15:8]); f.push_back(udp_total[7:0]);
        f.push_back(8'h00); f.push_back(8'h00);                    // UDP csum 0
        foreach (payload[i]) f.push_back(payload[i]);
        while (f.size() < 60) f.push_back(8'h00);
    endfunction

    function automatic void str_to_bytes(output logic [7:0] q[$],
                                         input string s);
        q.delete();
        for (int i = 0; i < s.len(); i++) q.push_back(s.getc(i));
    endfunction

    function automatic void print_frame(input logic [7:0] f[$],
                                        input string name = "Frame");
        $display("--- %s (%0d bytes) ---", name, f.size());
        for (int i = 0; i < f.size(); i++) begin
            if (i % 16 == 0) $write("%04x: ", i);
            $write("%02x ", f[i]);
            if (i % 16 == 15 || i == f.size() - 1) $display("");
        end
    endfunction

    // ---------------- RMII pin-level driver ----------------
    task automatic send_byte(input logic [7:0] b);
        for (int i = 0; i < 4; i++) begin
            rmii_rxd <= (b >> (i * 2)) & 2'b11;
            @(posedge clk50);
        end
    endtask

    task automatic send_frame(input logic [7:0] frame[$]);
        logic [31:0] crc;
        logic [31:0] fcs;

        crc = 32'hFFFFFFFF;
        foreach (frame[i]) crc = crc32_byte(crc, frame[i]);
        fcs = ~crc;

        rmii_crs_dv <= 1'b1;
        repeat (2) @(posedge clk50);
        repeat (7) send_byte(8'h55);
        send_byte(8'hD5);
        foreach (frame[i]) send_byte(frame[i]);
        send_byte(fcs[7:0]);  send_byte(fcs[15:8]);
        send_byte(fcs[23:16]); send_byte(fcs[31:24]);
        rmii_crs_dv <= 1'b0;
        rmii_rxd    <= '0;
        repeat (12) @(posedge clk50);
    endtask

    // ---------------- payload spy (hierarchical) ----------------
    logic [7:0] pq[$];
    int payloads_done = 0;

    always @(posedge clk50) begin
        if (dut.u_udp.pay_valid) begin
            pq.push_back(dut.u_udp.pay_data);
            if (dut.u_udp.pay_last) payloads_done++;
        end
    end

    task automatic check_payload(input logic [7:0] exp[$], input string name);
        int target = payloads_done + 1;
        int guard  = 0;
        while (payloads_done < target) begin
            @(posedge clk50);
            if (++guard > 20000) begin
                errors++; $error("[%s] timeout waiting for payload", name);
                return;
            end
        end
        if (pq.size() != exp.size()) begin
            errors++;
            $error("[%s] got %0d bytes, expected %0d", name, pq.size(), exp.size());
        end else
            foreach (exp[i])
                if (pq[i] !== exp[i]) begin
                    errors++;
                    $error("[%s] byte %0d: got %02h, expected %02h",
                           name, i, pq[i], exp[i]);
                end
        $display("[%0t] %s: payload OK (%0d bytes)", $time, name, pq.size());
        pq.delete();
    endtask

    // ---------------- test sequence ----------------
    logic [7:0] f[$], p[$];

    initial begin
        // 1. release the board reset
        #100 rst_n = 1'b1;

        // 2. wait for the clocking chain: PLL lock -> sys_rst_n
        wait (dut.sys_rst_n === 1'b1);
        $display("[%0t] PLL locked, sys_rst_n released", $time);

        // 3. PHY reset sequencer must eventually release eth_rstn
        wait (eth_rstn === 1'b1);
        $display("[%0t] eth_rstn released by sequencer", $time);

        // sanity: TX must be silent in an RX-only design
        if (eth_txen !== 1'b0) begin
            errors++; $error("eth_txen is not tied low");
        end

        repeat (20) @(posedge clk50);

        // 4. one UDP frame to the listen port -> payload + display latch
        $display("--- UDP frame to port 5000 ---");
        str_to_bytes(p, "hello fpga 7");
        make_udp_frame(f, 16'd5000, p);
        print_frame(f, "Sent frame");
        send_frame(f);
        check_payload(p, "T1");

        repeat (5) @(posedge clk50);
        if (dut.last_pay_byte !== "7") begin
            errors++;
            $error("last_pay_byte = %02h, expected %02h ('7')",
                   dut.last_pay_byte, 8'h37);
        end else
            $display("[%0t] display latch shows '7' (0x37) -- OK", $time);

        // 5. non-UDP frame -> latch must NOT change
        $display("--- TCP frame (must be ignored) ---");
        make_udp_frame(f, 16'd5000, p, 8'h06);       // protocol = TCP
        send_frame(f);
        repeat (100) @(posedge clk50);
        if (dut.last_pay_byte !== "7") begin
            errors++;
            $error("latch changed on a non-UDP frame: %02h", dut.last_pay_byte);
        end else
            $display("[%0t] latch unchanged on TCP frame -- OK", $time);

        // summary
        repeat (10) @(posedge clk50);
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d ERROR(S)", errors);
        $finish;
    end

endmodule