`timescale 1ns/1ps
//=============================================================================
// tb_net_stack.sv
//
// System test of net_stack: ARP + UDP echo sharing the TX path.
//
//   1. ARP request for OUR_IP -> reply frame checked byte-for-byte
//      (OPER=0002, our MAC/IP as sender, PC MAC/IP as target, zero pad)
//   2. ARP request for a DIFFERENT IP -> silence (TPA check works)
//   3. UDP echo still round-trips through the arbiter (regression)
//
// Monitor: a PC-configured rx_ethernet on the DUT's TX pins (frame level),
// plus a PC-configured udp_rx for test 3 (payload level).
//=============================================================================
module tb_net_stack;

    localparam logic [47:0] FPGA_MAC  = 48'h02_00_00_00_00_01;
    localparam logic [47:0] PC_MAC    = 48'h02_00_00_00_00_AA;
    localparam logic [31:0] FPGA_IP   = {8'd192, 8'd168, 8'd1, 8'd2};
    localparam logic [31:0] PC_IP     = {8'd192, 8'd168, 8'd1, 8'd1};
    localparam logic [15:0] FPGA_PORT = 16'd5000;
    localparam logic [15:0] PC_PORT   = 16'hC738;

    logic clk50 = 1'b0;
    logic rst_n = 1'b0;
    always #10 clk50 = ~clk50;

    // ---------------- DUT ----------------
    bit [1:0] pc_txd   = '0;
    logic       pc_tx_en = 1'b0;
    bit [1:0] dut_txd;
    logic       dut_tx_en;
    logic [7:0] dpay_data;
    logic       dpay_valid, dpay_last;
    logic       frame_dropped, mac_reject, echo_busy;

    net_stack #(
        .MAC_ADDR   (FPGA_MAC),
        .OUR_IP     (FPGA_IP),
        .LISTEN_PORT(FPGA_PORT)
    ) dut (
        .clk50         (clk50),
        .rst_n         (rst_n),
        .rmii_rxd      (pc_txd),
        .rmii_crs_dv   (pc_tx_en),
        .rmii_txd      (dut_txd),
        .rmii_tx_en    (dut_tx_en),
        .pay_data      (dpay_data),
        .pay_valid     (dpay_valid),
        .pay_last      (dpay_last),
        .frame_dropped (frame_dropped),
        .mac_reject    (mac_reject),
        .echo_busy     (echo_busy)
    );

    // ---------------- monitor: the PC's receiver ----------------
    logic [7:0]  m_rd_data;
    logic        m_rd_last, m_rd_valid, m_rd_ready;
    logic        m_dropped, m_reject;
    logic [7:0]  m_pay_data;
    logic        m_pay_valid, m_pay_last;
    logic [47:0] m_src_mac;
    logic [31:0] m_src_ip;
    logic [15:0] m_src_port;

    rx_ethernet #(.MAC_ADDR(PC_MAC)) u_mon_rx (
        .clk50         (clk50),
        .rst_n         (rst_n),
        .rmii_rxd      (dut_txd),
        .rmii_crs_dv   (dut_tx_en),
        .rd_data       (m_rd_data),
        .rd_last       (m_rd_last),
        .rd_valid      (m_rd_valid),
        .rd_ready      (m_rd_ready),
        .frame_dropped (m_dropped),
        .mac_reject    (m_reject)
    );

    udp_rx #(.LISTEN_PORT(PC_PORT)) u_mon_udp (
        .clk       (clk50),
        .rst_n     (rst_n),
        .rd_data   (m_rd_data),
        .rd_valid  (m_rd_valid),
        .rd_last   (m_rd_last),
        .rd_ready  (m_rd_ready),
        .pay_data  (m_pay_data),
        .pay_valid (m_pay_valid),
        .pay_last  (m_pay_last),
        .src_mac   (m_src_mac),
        .src_ip    (m_src_ip),
        .src_port  (m_src_port)
    );

    int errors = 0;

    //-------------------------------------------------------------------------
    // Helpers
    //-------------------------------------------------------------------------
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

    function automatic void push48(ref logic [7:0] q[$],
                                   input logic [47:0] v);
        for (int i = 0; i < 6; i++) q.push_back(8'((v >> (8*(5-i)))));
    endfunction
    function automatic void push32(ref logic [7:0] q[$],
                                   input logic [31:0] v);
        for (int i = 0; i < 4; i++) q.push_back(8'((v >> (8*(3-i)))));
    endfunction

    // ARP request frame: who has 'target_ip'? tell PC
    function automatic void make_arp_request(
        output logic [7:0]  f[$],
        input  logic [31:0] target_ip);
        f.delete();
        push48(f, 48'hFF_FF_FF_FF_FF_FF);            // DA = broadcast
        push48(f, PC_MAC);                            // SA
        f.push_back(8'h08); f.push_back(8'h06);       // EtherType = ARP
        f.push_back(8'h00); f.push_back(8'h01);       // HTYPE
        f.push_back(8'h08); f.push_back(8'h00);       // PTYPE
        f.push_back(8'h06); f.push_back(8'h04);       // HLEN/PLEN
        f.push_back(8'h00); f.push_back(8'h01);       // OPER = request
        push48(f, PC_MAC);                            // SHA
        push32(f, PC_IP);                             // SPA
        push48(f, 48'h0);                             // THA (unknown)
        push32(f, target_ip);                         // TPA
        while (f.size() < 60) f.push_back(8'h00);
    endfunction

    // Expected ARP reply frame (as the monitor's rd stream shows it)
    function automatic void expected_arp_reply(output logic [7:0] f[$]);
        f.delete();
        push48(f, PC_MAC);                            // DA = the asker
        push48(f, FPGA_MAC);                          // SA = us
        f.push_back(8'h08); f.push_back(8'h06);
        f.push_back(8'h00); f.push_back(8'h01);
        f.push_back(8'h08); f.push_back(8'h00);
        f.push_back(8'h06); f.push_back(8'h04);
        f.push_back(8'h00); f.push_back(8'h02);       // OPER = reply
        push48(f, FPGA_MAC);                          // SHA = us
        push32(f, FPGA_IP);                           // SPA = our IP
        push48(f, PC_MAC);                            // THA = them
        push32(f, PC_IP);                             // TPA = their IP
        while (f.size() < 60) f.push_back(8'h00);     // eth_frame_tx pad
    endfunction

    function automatic void make_udp_frame(
        output logic [7:0] f[$], input logic [7:0] app[$]);
        logic [7:0]  iph[$];
        logic [15:0] ip_total, udp_total, csum;
        ip_total  = 16'd28 + app.size();
        udp_total = 16'd8  + app.size();
        iph = '{8'h45, 8'h00, ip_total[15:8], ip_total[7:0],
                8'h00, 8'h01, 8'h00, 8'h00, 8'h40, 8'h11, 8'h00, 8'h00,
                PC_IP[31:24],   PC_IP[23:16],   PC_IP[15:8],   PC_IP[7:0],
                FPGA_IP[31:24], FPGA_IP[23:16], FPGA_IP[15:8], FPGA_IP[7:0]};
        csum = ip_checksum(iph);
        iph[10] = csum[15:8]; iph[11] = csum[7:0];
        f.delete();
        push48(f, FPGA_MAC); push48(f, PC_MAC);
        f.push_back(8'h08); f.push_back(8'h00);
        foreach (iph[i]) f.push_back(iph[i]);
        f.push_back(PC_PORT[15:8]);   f.push_back(PC_PORT[7:0]);
        f.push_back(FPGA_PORT[15:8]); f.push_back(FPGA_PORT[7:0]);
        f.push_back(udp_total[15:8]); f.push_back(udp_total[7:0]);
        f.push_back(8'h00); f.push_back(8'h00);
        foreach (app[i]) f.push_back(app[i]);
        while (f.size() < 60) f.push_back(8'h00);
    endfunction

    function automatic void str_to_bytes(output logic [7:0] q[$],
                                         input string s);
        q.delete();
        for (int i = 0; i < s.len(); i++) q.push_back(s.getc(i));
    endfunction

    //-------------------------------------------------------------------------
    // PC-side driver
    //-------------------------------------------------------------------------
    task automatic send_byte(input logic [7:0] b);
        for (int i = 0; i < 4; i++) begin
            pc_txd = b[2*i +: 2];
            @(posedge clk50);
        end
    endtask

    task automatic send_frame(input logic [7:0] frame[$]);
        logic [31:0] crc = 32'hFFFFFFFF;
        logic [31:0] fcs;
        foreach (frame[i]) crc = crc32_byte(crc, frame[i]);
        fcs = ~crc;
        pc_tx_en = 1'b1;
        repeat (2) @(posedge clk50);
        repeat (7) send_byte(8'h55);
        send_byte(8'hD5);
        foreach (frame[i]) send_byte(frame[i]);
        send_byte(fcs[7:0]);  send_byte(fcs[15:8]);
        send_byte(fcs[23:16]); send_byte(fcs[31:24]);
        pc_tx_en = 1'b0;
        pc_txd   = '0;
        repeat (12) @(posedge clk50);
    endtask

    //-------------------------------------------------------------------------
    // PC-side monitors: frames and payloads
    //-------------------------------------------------------------------------
    logic [7:0] fq[$];
    int frames_seen = 0;
    always @(posedge clk50) begin
        if (m_rd_valid && m_rd_ready) begin
            fq.push_back(m_rd_data);
            if (m_rd_last) frames_seen++;
        end
    end

    logic [7:0] pq[$];
    int replies = 0;
    always @(posedge clk50) begin
        if (m_pay_valid) begin
            pq.push_back(m_pay_data);
            if (m_pay_last) replies++;
        end
    end

    task automatic expect_frame(input logic [7:0] exp[$], input string name);
        int target = frames_seen;
        int guard  = 0;
        while (frames_seen == target) begin
            @(posedge clk50);
            if (++guard > 50000) begin
                errors++; $error("[%s] timeout: no frame from DUT", name);
                return;
            end
        end
        if (fq.size() != exp.size()) begin
            errors++;
            $error("[%s] got %0d bytes, expected %0d", name, fq.size(), exp.size());
        end else
            foreach (exp[i])
                if (fq[i] !== exp[i]) begin
                    errors++;
                    $error("[%s] byte %0d: got %02h, expected %02h",
                           name, i, fq[i], exp[i]);
                end
        $display("[%0t] %s: DUT frame verified (%0d bytes)",
                 $time, name, fq.size());
        fq.delete();
    endtask

    task automatic expect_no_frame(input string name);
        int f0 = frames_seen;
        repeat (2000) @(posedge clk50);
        if (frames_seen != f0) begin
            errors++;
            $error("[%s] DUT transmitted a frame it should not have", name);
            fq.delete();
        end else
            $display("[%0t] %s: silence, as expected", $time, name);
    endtask

    //-------------------------------------------------------------------------
    // Tests
    //-------------------------------------------------------------------------
    logic [7:0] f[$], exp[$], app[$];
    int t3_target, t3_guard;

    initial begin
        repeat (5) @(posedge clk50);
        rst_n = 1'b1;
        repeat (10) @(posedge clk50);

        //--- Test 1: ARP request for our IP -> full reply check --------------
        $display("--- Test 1: ARP who-has %0d.%0d.%0d.%0d ---",
                 FPGA_IP[31:24], FPGA_IP[23:16], FPGA_IP[15:8], FPGA_IP[7:0]);
        make_arp_request(f, FPGA_IP);
        send_frame(f);
        expected_arp_reply(exp);
        expect_frame(exp, "T1");

        //--- Test 2: ARP request for someone else -> silence ------------------
        $display("--- Test 2: ARP for a different IP ---");
        make_arp_request(f, {8'd192, 8'd168, 8'd1, 8'd99});
        send_frame(f);
        expect_no_frame("T2");

        //--- Test 3: UDP echo regression through the arbiter ------------------
        $display("--- Test 3: UDP echo still works ---");
        str_to_bytes(app, "still echoing");
        make_udp_frame(f, app);
        send_frame(f);
        begin
            t3_target = replies + 1;
            t3_guard  = 0;
            while (replies < t3_target) begin
                @(posedge clk50);
                if (++t3_guard > 50000) begin
                    errors++; $error("[T3] timeout: no echo"); break;
                end
            end
            if (pq.size() == app.size()) begin
                foreach (app[i])
                    if (pq[i] !== app[i]) begin
                        errors++;
                        $error("[T3] byte %0d: got %02h, expected %02h",
                               i, pq[i], app[i]);
                    end
                $display("[%0t] T3: echo payload verified", $time);
            end else begin
                errors++;
                $error("[T3] echo: got %0d bytes, expected %0d",
                       pq.size(), app.size());
            end
            pq.delete();
            fq.delete();   // the echo frame also passed the frame monitor
        end

        repeat (20) @(posedge clk50);
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d ERROR(S)", errors);
        $finish;
    end

endmodule