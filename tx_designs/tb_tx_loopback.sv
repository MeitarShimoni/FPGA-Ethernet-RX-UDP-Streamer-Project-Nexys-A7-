`timescale 1ns/1ps
//=============================================================================
// tb_tx_loopback.sv
//
// The self-judging testbench: tx_ethernet's pins are wired straight into
// the fully verified rx_ethernet (+ udp_rx). If a transmitted frame comes
// out of the RX side intact, then -- simultaneously -- the TX preamble/SFD,
// dibit order, CRC32 generation, byte order of the FCS, zero-padding, and
// tx_en timing are all correct, because the receiver checks every one of
// them by construction.
//
//        pl stream -> tx_ethernet --txd/tx_en--> rx_ethernet -> udp_rx
//                                    (loopback)
//
// Tests:
//   1. Raw Ethernet frame, short payload -> RX rd_* stream must equal
//      header + payload + zero pad (proves padding + CRC + framing)
//   2. Full UDP-in-Ethernet frame -> udp_rx must emit the app payload
//      (proves the whole stack round-trips: build TX-side, parse RX-side)
//   3. Two frames back-to-back -> IFG and gapless byte timing
//   4. frame_dropped must stay 0 throughout -- a single CRC/timing slip
//      anywhere would fire it.
//=============================================================================
module tb_tx_loopback;

    localparam logic [47:0] RX_MAC = 48'h02_00_00_00_00_01;  // rx_ethernet default
    localparam logic [47:0] TX_MAC = 48'h02_00_00_00_00_AA;

    logic clk50 = 1'b0;
    logic rst_n = 1'b0;
    always #10 clk50 = ~clk50;

    // ---------------- TX side ----------------
    logic [47:0] dst_mac    = RX_MAC;
    logic [15:0] ether_type = 16'h0800;
    logic [7:0]  pl_data  = '0;
    logic        pl_valid = 1'b0;
    logic        pl_last  = 1'b0;
    logic        pl_ready, tx_busy;

    // ---------------- loopback wires ----------------
    logic [1:0] lb_txd;
    logic       lb_tx_en;

    // ---------------- RX side ----------------
    logic [7:0]  rd_data;
    logic        rd_last, rd_valid, rd_ready;
    logic        frame_dropped, mac_reject;
    logic [7:0]  pay_data;
    logic        pay_valid, pay_last;
    logic [31:0] src_ip;
    logic [15:0] src_port;

    tx_ethernet #(.SRC_MAC(TX_MAC)) u_tx (
        .clk50      (clk50),
        .rst_n      (rst_n),
        .dst_mac    (dst_mac),
        .ether_type (ether_type),
        .pl_data    (pl_data),
        .pl_valid   (pl_valid),
        .pl_last    (pl_last),
        .pl_ready   (pl_ready),
        .rmii_txd   (lb_txd),
        .rmii_tx_en (lb_tx_en),
        .busy       (tx_busy)
    );

    rx_ethernet u_rx (                       // MAC_ADDR default = RX_MAC
        .clk50         (clk50),
        .rst_n         (rst_n),
        .rmii_rxd      (lb_txd),             // <-- the loopback
        .rmii_crs_dv   (lb_tx_en),           // <--
        .rd_data       (rd_data),
        .rd_last       (rd_last),
        .rd_valid      (rd_valid),
        .rd_ready      (rd_ready),
        .frame_dropped (frame_dropped),
        .mac_reject    (mac_reject)
    );

    udp_rx #(.LISTEN_PORT(16'd5000)) u_udp (
        .clk       (clk50),
        .rst_n     (rst_n),
        .rd_data   (rd_data),
        .rd_valid  (rd_valid),
        .rd_last   (rd_last),
        .rd_ready  (rd_ready),
        .pay_data  (pay_data),
        .pay_valid (pay_valid),
        .pay_last  (pay_last),
        .src_ip    (src_ip),
        .src_port  (src_port)
    );

    int errors = 0;
    int drops  = 0;
    always @(posedge clk50) if (frame_dropped) drops++;

    //-------------------------------------------------------------------------
    // Helpers (IP checksum for building a UDP payload TX-side)
    //-------------------------------------------------------------------------
    function automatic logic [15:0] ip_checksum(input logic [7:0] hdr[$]);
        int unsigned sum = 0;
        for (int i = 0; i < hdr.size(); i += 2)
            sum += {hdr[i], hdr[i+1]};
        while (sum > 32'h0000FFFF)
            sum = (sum & 32'h0000FFFF) + (sum >> 16);
        return ~sum[15:0];
    endfunction

    // Build the ETHERNET PAYLOAD (IP+UDP+data) -- what a udp_tx module will
    // one day generate in RTL; here the TB plays that role.
    function automatic void make_ip_udp_payload(
        output logic [7:0]  q[$],
        input  logic [15:0] dst_port,
        input  logic [7:0]  app[$]);

        logic [7:0]  iph[$];
        logic [15:0] ip_total, udp_total, csum;

        ip_total  = 16'd20 + 16'd8 + app.size();
        udp_total = 16'd8 + app.size();

        iph = '{8'h45, 8'h00, ip_total[15:8], ip_total[7:0],
                8'h00, 8'h01, 8'h00, 8'h00,
                8'h40, 8'h11, 8'h00, 8'h00,
                8'hC0, 8'hA8, 8'h01, 8'h02,          // src = the FPGA
                8'hC0, 8'hA8, 8'h01, 8'h01};         // dst = the PC
        csum    = ip_checksum(iph);
        iph[10] = csum[15:8];
        iph[11] = csum[7:0];

        q.delete();
        foreach (iph[i]) q.push_back(iph[i]);
        q.push_back(8'h13); q.push_back(8'h88);      // src port 5000
        q.push_back(dst_port[15:8]); q.push_back(dst_port[7:0]);
        q.push_back(udp_total[15:8]); q.push_back(udp_total[7:0]);
        q.push_back(8'h00); q.push_back(8'h00);
        foreach (app[i]) q.push_back(app[i]);
    endfunction

    function automatic void str_to_bytes(output logic [7:0] q[$],
                                         input string s);
        q.delete();
        for (int i = 0; i < s.len(); i++) q.push_back(s.getc(i));
    endfunction

    //-------------------------------------------------------------------------
    // TX payload driver (valid/ready, held until consumed)
    //-------------------------------------------------------------------------
    task automatic send_payload(input logic [7:0] p[$]);
        foreach (p[i]) begin
            @(negedge clk50);
            pl_data  = p[i];
            pl_last  = (i == p.size() - 1);
            pl_valid = 1'b1;
            // hold until this byte is consumed
            do @(posedge clk50); while (!(pl_valid && pl_ready));
            @(negedge clk50);
        end
        pl_valid = 1'b0;
        pl_last  = 1'b0;
        // wait out the frame + IFG
        wait (tx_busy == 1'b0);
        repeat (4) @(posedge clk50);
    endtask

    //-------------------------------------------------------------------------
    // RX-side frame spy (passive: udp_rx holds rd_ready high)
    //-------------------------------------------------------------------------
    logic [7:0] fq[$];
    int frames_seen = 0;
    always @(posedge clk50) begin
        if (rd_valid && rd_ready) begin
            fq.push_back(rd_data);
            if (rd_last) frames_seen++;
        end
    end

    task automatic check_frame(input logic [7:0] exp[$], input string name);
        int target = frames_seen + 0;   // frames already counted
        int guard  = 0;
        while (frames_seen == target) begin
            @(posedge clk50);
            if (++guard > 30000) begin
                errors++; $error("[%s] timeout: frame never reached RX", name);
                return;
            end
        end
        if (fq.size() != exp.size()) begin
            errors++;
            $error("[%s] RX got %0d bytes, expected %0d", name, fq.size(), exp.size());
        end else
            foreach (exp[i])
                if (fq[i] !== exp[i]) begin
                    errors++;
                    $error("[%s] byte %0d: got %02h, expected %02h",
                           name, i, fq[i], exp[i]);
                end
        $display("[%0t] %s: frame round-tripped, %0d bytes OK",
                 $time, name, fq.size());
        fq.delete();
    endtask

    // Expected RX frame = DA + SA + type + payload + zero pad to 60
    function automatic void expected_frame(
        output logic [7:0] f[$],
        input  logic [7:0] payload[$]);
        f.delete();
        for (int i = 0; i < 6; i++) f.push_back(8'((RX_MAC >> (8*(5-i)))));
        for (int i = 0; i < 6; i++) f.push_back(8'((TX_MAC >> (8*(5-i)))));
        f.push_back(8'h08); f.push_back(8'h00);
        foreach (payload[i]) f.push_back(payload[i]);
        while (f.size() < 60) f.push_back(8'h00);
    endfunction

    // UDP payload spy
    logic [7:0] pq[$];
    int payloads_done = 0;
    always @(posedge clk50) begin
        if (pay_valid) begin
            pq.push_back(pay_data);
            if (pay_last) payloads_done++;
        end
    end

    //-------------------------------------------------------------------------
    // Tests
    //-------------------------------------------------------------------------
    logic [7:0] p[$], q[$], exp[$], app[$];

    initial begin
        repeat (5) @(posedge clk50);
        rst_n = 1'b1;
        repeat (10) @(posedge clk50);

        //--- Test 1: raw short frame -> padding + CRC + framing --------------
        $display("--- Test 1: raw frame, short payload ---");
        str_to_bytes(p, "LOOPBACK!");
        send_payload(p);
        expected_frame(exp, p);
        check_frame(exp, "T1");

        //--- Test 2: full UDP round trip --------------------------------------
        $display("--- Test 2: UDP through the whole stack ---");
        str_to_bytes(app, "tx says hello");
        make_ip_udp_payload(q, 16'd5000, app);
        send_payload(q);
        expected_frame(exp, q);
        check_frame(exp, "T2");
        begin
            int guard = 0;
            while (payloads_done == 0) begin
                @(posedge clk50);
                if (++guard > 5000) begin
                    errors++; $error("[T2] udp_rx never emitted the payload");
                    break;
                end
            end
            if (pq.size() != app.size()) begin
                errors++;
                $error("[T2] app payload: got %0d bytes, expected %0d",
                       pq.size(), app.size());
            end else begin
                foreach (app[i])
                    if (pq[i] !== app[i]) begin
                        errors++;
                        $error("[T2] app byte %0d: got %02h, expected %02h",
                               i, pq[i], app[i]);
                    end
                $display("[%0t] T2: application payload round-tripped OK", $time);
            end
            pq.delete();
        end

        //--- Test 3: back-to-back frames (IFG + gapless bytes) ----------------
        $display("--- Test 3: two frames back-to-back ---");
        str_to_bytes(p, "frame one");
        send_payload(p);
        expected_frame(exp, p);
        check_frame(exp, "T3a");
        str_to_bytes(p, "frame two!!");
        send_payload(p);
        expected_frame(exp, p);
        check_frame(exp, "T3b");

        //--- Test 4: nothing was ever dropped ----------------------------------
        if (drops != 0) begin
            errors++;
            $error("frame_dropped fired %0d time(s): TX produced a bad frame", drops);
        end else
            $display("frame_dropped = 0: every TX frame passed CRC + filter");

        repeat (10) @(posedge clk50);
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d ERROR(S)", errors);
        $finish;
    end

endmodule
