// module rx_ethernet_tb;



// logic clk50;
// logic rst_n;

// logic rmii_crs_dv;
// logic [1:0] rmii_rxd;


// always #10 clk50 = ~clk50;   // 50 MHz


// logic [7:0] rd_data;
// logic rd_last;
// logic rd_valid;
// logic rd_ready;
// logic frame_dropped;
// logic mac_reject;

// // DUT
// // #(.MAC_ADDR(48'h02_00_00_00_00_01))
// rx_ethernet #(
//     .MAC_ADDR(48'h02_00_00_00_00_01), 
//     .FIFO_DEPTH(2048)) 
//     dut (
//     .clk50(clk50),
//     .rst_n(rst_n),

//     .rmii_rxd(rmii_rxd),
//     .rmii_crs_dv(rmii_crs_dv),
    
//     .rd_data(rd_data),
//     .rd_last(rd_last),
//     .rd_valid(rd_valid),
//     .rd_ready(rd_ready),
    
//     .frame_dropped(frame_dropped),
//     .mac_reject(mac_reject)
// );






// // =========================================================================
// // TASKS AND FUNCTIONS
// // =========================================================================

// //-------------------------------------------------------------------------
// // Reference CRC32 (same algorithm as DUT) used to build the FCS
// //-------------------------------------------------------------------------
// function automatic logic [31:0] crc32_byte
//     (input logic [31:0] crc, input logic [7:0] data);
//     logic [31:0] c;
//     c = crc ^ {24'h0, data};
//     for (int i = 0; i < 8; i++)
//         c = c[0] ? (c >> 1) ^ 32'hEDB88320 : (c >> 1);
//     return c;
// endfunction

// //-------------------------------------------------------------------------
// // Dibit-level driver (LSB pair first, one dibit per 50 MHz clock)
// //-------------------------------------------------------------------------
// task automatic send_byte(input logic [7:0] b);
//     for (int i = 0; i < 4; i++) begin
//         rmii_rxd = b[2*i +: 2];
//         @(posedge clk50);
//     end
// endtask

// task automatic send_frame(input logic [7:0] frame[$], input bit corrupt);
//     logic [31:0] crc;
//     logic [31:0] fcs;
//     logic [7:0]  b;

//     // Compute FCS over the (uncorrupted) frame
//     crc = 32'hFFFFFFFF;
//     foreach (frame[i]) crc = crc32_byte(crc, frame[i]);
//     fcs = ~crc;                          // transmitted complemented, LSB byte first

//     rmii_crs_dv = 1'b1;
//     repeat (2) @(posedge clk50);         // a little carrier before data

//     repeat (7) send_byte(8'h55);         // preamble
//     send_byte(8'hD5);                    // SFD

//     foreach (frame[i]) begin
//         b = frame[i];
//         if (corrupt && i == 20) b ^= 8'hFF;   // flip one byte mid-frame
//         send_byte(b);
//     end
//     send_byte(fcs[7:0]);
//     send_byte(fcs[15:8]);
//     send_byte(fcs[23:16]);
//     send_byte(fcs[31:24]);

//     rmii_crs_dv = 1'b0;
//     rmii_rxd    = '0;
//     repeat (10) @(posedge clk50);        // inter-frame gap
// endtask


// logic [7:0] frame[$];
// logic [7:0] frame2[$];
// logic expect_ok;

// // Stimulus
// initial begin
//     clk50 = 1'b0;
//     rst_n = 1'b0;
//     rd_ready = 1'b1;
//     expect_ok = 1'b1;
//     for(int i = 0; i < 20; i++) begin
//         frame.push_back(i);    
//     end

//     @(posedge clk50);
//     rst_n = 1'b1;

//     // send_frame(frame, 1'b0);     // good frame
//     send_frame(frame, 1'b0);
//     // for(int i = 0; i < 20; i++) begin
//     //     frame2.push_back($urandom_range(0, 255));    
//     // end
//     #100;

//     // send_frame(frame2, 1'b0);

//     $display("Simulation Ended");
//     // $finish;

// end

// endmodule


`timescale 1ns/1ps
//=============================================================================
// tb_rx_ethernet.sv
//
// Integration test of the complete RX chain (rx_ethernet):
// RMII dibits in -> clean frames out via the FIFO read side.
//
// Tests:
//   1. Broadcast DA, good CRC        -> received
//   2. DA = our MAC, good CRC        -> received
//   3. DA = someone else, good CRC   -> rejected (mac_reject + dropped)
//   4. Broadcast DA, corrupted       -> rejected (dropped, no mac_reject)
//
// The DUT uses the default MAC_ADDR = 02:00:00:00:00:01.
//=============================================================================
module tb_rx_ethernet;

    localparam logic [47:0] OUR_MAC = 48'h02_00_00_00_00_01;

    logic clk50 = 1'b0;
    logic rst_n = 1'b0;
    always #10 clk50 = ~clk50;                 // 50 MHz

    // DUT I/O
    logic [1:0] rmii_rxd    = '0;
    logic       rmii_crs_dv = 1'b0;
    logic [7:0] rd_data;
    logic       rd_last, rd_valid;
    logic       rd_ready = 1'b0;
    logic       frame_dropped, mac_reject;

    rx_ethernet dut (.*);
//     rx_ethernet #(
//     .MAC_ADDR(48'h02_00_00_00_00_01), 
//     .FIFO_DEPTH(2048)) 
//     dut (
//     .clk50(clk50),
//     .rst_n(rst_n),

//     .rmii_rxd(rmii_rxd),
//     .rmii_crs_dv(rmii_crs_dv),
    
//     .rd_data(rd_data),
//     .rd_last(rd_last),
//     .rd_valid(rd_valid),
//     .rd_ready(rd_ready),
    
//     .frame_dropped(frame_dropped),
//     .mac_reject(mac_reject)
// );


    int errors    = 0;
    int n_drops   = 0;
    int n_rejects = 0;

    always @(posedge clk50) begin
        if (frame_dropped) n_drops++;
        if (mac_reject)    n_rejects++;
    end

    //-------------------------------------------------------------------------
    // CRC32 reference (for building a valid FCS)
    //-------------------------------------------------------------------------
    function automatic logic [31:0] crc32_byte
        (input logic [31:0] crc, input logic [7:0] data);
        logic [31:0] c;
        c = crc ^ {24'h0, data};
        for (int i = 0; i < 8; i++)
            c = c[0] ? (c >> 1) ^ 32'hEDB88320 : (c >> 1);
        return c;
    endfunction

    //-------------------------------------------------------------------------
    // RMII pin-level driver
    //-------------------------------------------------------------------------
    task automatic send_byte(input logic [7:0] b);
        for (int i = 0; i < 4; i++) begin
            rmii_rxd = b[2*i +: 2];
            @(posedge clk50);
        end
    endtask

    task automatic send_frame(input logic [7:0] frame[$], input bit corrupt);
        logic [31:0] crc;
        logic [31:0] fcs;
        logic [7:0]  b;

        crc = 32'hFFFFFFFF;
        foreach (frame[i]) crc = crc32_byte(crc, frame[i]);
        fcs = ~crc;

        rmii_crs_dv = 1'b1;
        repeat (2) @(posedge clk50);
        repeat (7) send_byte(8'h55);           // preamble
        send_byte(8'hD5);                      // SFD
        foreach (frame[i]) begin
            b = frame[i];
            if (corrupt && i == 20) b ^= 8'hFF;
            send_byte(b);
        end
        send_byte(fcs[7:0]);
        send_byte(fcs[15:8]);
        send_byte(fcs[23:16]);
        send_byte(fcs[31:24]);
        rmii_crs_dv = 1'b0;
        rmii_rxd    = '0;
        repeat (12) @(posedge clk50);          // inter-frame gap
    endtask

    //-------------------------------------------------------------------------
    // Frame builder: DA + fixed SA + EtherType + pad to 60 bytes
    //-------------------------------------------------------------------------
    function automatic void make_frame(output logic [7:0] f[$],
                                       input logic [47:0] da,
                                       input logic [7:0]  seed);
        f.delete();
        for (int i = 0; i < 6; i++) 
        f.push_back(da[8*(5-i) +: 8]);     // DA
        f.push_back(8'h02); 
        f.push_back(8'h00); 
        f.push_back(8'h00);   // SA
        f.push_back(8'h00); 
        f.push_back(8'h00); 
        f.push_back(8'hAA);
        f.push_back(8'h08); 
        f.push_back(8'h00);                        // EtherType
        while (f.size() < 60) f.push_back(seed + f.size()[7:0]);       // pad
    endfunction

    //-------------------------------------------------------------------------
    // Read-side consumer with random backpressure (negedge snapshot style)
    //-------------------------------------------------------------------------
    task automatic read_frame(input logic [7:0] exp[$], input string name);
        logic [7:0] got[$];
        bit v, l, r;
        logic [7:0] d;
        bit done = 1'b0;
        int guard = 0;

        while (!done) begin
            @(negedge clk50);
            rd_ready = ($urandom_range(0, 3) != 0);
            v = rd_valid; d = rd_data; l = rd_last; r = rd_ready;
            @(posedge clk50);
            if (v && r) begin
                got.push_back(d);
                if (l) done = 1'b1;
            end
            if (++guard > 20000) begin
                errors++; $error("[%s] timeout waiting for frame", name);
                break;
            end
        end
        @(negedge clk50);
        rd_ready = 1'b0;

        if (got.size() != exp.size()) begin
            errors++;
            $error("[%s] got %0d bytes, expected %0d", name, got.size(), exp.size());
        end else begin
            foreach (exp[i])
                if (got[i] !== exp[i]) begin
                    errors++;
                    $error("[%s] byte %0d: got %02h, expected %02h",
                           name, i, got[i], exp[i]);
                end
        end
        $display("[%0t] %s: frame received, %0d bytes OK", $time, name, got.size());
    endtask

    task automatic expect_empty(input string name);
        repeat (8) @(negedge clk50);
        if (rd_valid) begin
            errors++;
            $error("[%s] FIFO offers a frame that should have been rejected", name);
        end else
            $display("[%0t] %s: nothing readable, as expected", $time, name);
    endtask

    //-------------------------------------------------------------------------
    // Test sequence
    //-------------------------------------------------------------------------
    logic [7:0] f[$];
    int d0, r0;

    initial begin
        repeat (5) @(posedge clk50);
        rst_n = 1'b1;
        repeat (5) @(posedge clk50);

        //--- Test 1: broadcast, good CRC -> accepted -------------------------
        $display("--- Test 1: broadcast frame ---");
        make_frame(f, 48'hFF_FF_FF_FF_FF_FF, 8'h10);
        send_frame(f, 1'b0);
        read_frame(f, "T1");

        //--- Test 2: our MAC, good CRC -> accepted ---------------------------
        $display("--- Test 2: unicast to us ---");
        make_frame(f, OUR_MAC, 8'h30);
        send_frame(f, 1'b0);
        read_frame(f, "T2");

        //--- Test 3: someone else's MAC, good CRC -> mac_reject --------------
        $display("--- Test 3: unicast to another MAC ---");
        d0 = n_drops; r0 = n_rejects;
        make_frame(f, 48'h02_DE_AD_BE_EF_00, 8'h50);
        send_frame(f, 1'b0);
        expect_empty("T3");
        if (n_rejects != r0 + 1) begin errors++; $error("[T3] expected mac_reject pulse"); end
        if (n_drops   != d0 + 1) begin errors++; $error("[T3] expected frame_dropped pulse"); end

        //--- Test 4: broadcast but corrupted -> CRC drop, no mac_reject ------
        $display("--- Test 4: corrupted broadcast ---");
        d0 = n_drops; r0 = n_rejects;
        make_frame(f, 48'hFF_FF_FF_FF_FF_FF, 8'h70);
        send_frame(f, 1'b1);
        expect_empty("T4");
        if (n_drops   != d0 + 1) begin errors++; $error("[T4] expected frame_dropped pulse"); end
        if (n_rejects != r0)     begin errors++; $error("[T4] mac_reject must NOT fire on CRC error"); end

        //--- Summary ----------------------------------------------------------
        repeat (10) @(posedge clk50);
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d ERROR(S)", errors);
        // $finish;
    end

endmodule