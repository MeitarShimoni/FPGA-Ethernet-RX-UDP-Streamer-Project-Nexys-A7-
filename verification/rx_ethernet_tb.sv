`timescale 1ns/1ps
//=============================================================================
// tb_rx_ethernet.sv
//=============================================================================
module tb_rx_ethernet;

    localparam logic [47:0] OUR_MAC = 48'h02_00_00_00_00_01;

    logic clk50 = 1'b0;
    logic rst_n = 1'b0;
    always #10 clk50 = ~clk50;                 // 50 MHz

    // DUT I/O - Kept as 'logic' (4-state) to ensure we catch X's!
    bit [1:0] rmii_rxd    = '0;
    logic       rmii_crs_dv = 1'b0;
    logic [7:0] rd_data;
    logic       rd_last, rd_valid;
    logic       rd_ready = 1'b1;
    logic       frame_dropped, mac_reject;

    int errors = 0;

    // Excellent practice using explicit port mapping here
    rx_ethernet dut (
        .clk50          (clk50),
        .rst_n          (rst_n),
        .rmii_rxd       (rmii_rxd),
        .rmii_crs_dv    (rmii_crs_dv),
        .rd_data        (rd_data),
        .rd_last        (rd_last),
        .rd_valid       (rd_valid),
        .rd_ready       (rd_ready),
        .frame_dropped  (frame_dropped),
        .mac_reject     (mac_reject)
    );


    function automatic void print_frame(input logic [7:0] f[$], input string name="Frame");
        $display("\n--- %s (%0d bytes) ---", name, f.size());
        for (int i = 0; i < f.size(); i++) begin
            if (i % 16 == 0) $write("%04x: ", i);
            $write("%02x ", f[i]);
            // Print a new line every 16 bytes, or at the end of the packet
            if (i % 16 == 15 || i == f.size() - 1) $display("");
        end
        $display("--------------------------------\n");
    endfunction

    //-------------------------------------------------------------------------
    // CRC32 reference (for building a valid FCS)
    //-------------------------------------------------------------------------
    function automatic logic [31:0] crc32_byte (input logic [31:0] crc, input logic [7:0] data);
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
            // FIX: Restored the shift/mask approach to avoid simulator +: bugs
            rmii_rxd <= (b >> (i * 2)) & 2'b11; 
            // $display("[%0t] sending dibit %0d: %b", $time, i, rmii_rxd);
            @(posedge clk50);
        end
    endtask

    task automatic send_frame(input logic [7:0] frame[$]);
        logic [31:0] crc;
        logic [31:0] fcs;

        crc = 32'hFFFFFFFF;
        foreach (frame[i]) crc = crc32_byte(crc, frame[i]);
        fcs = ~crc;
        
        rmii_crs_dv <= 1'b1; // FIX: Non-blocking assignment
        print_frame(frame, "Sent Frame");
        repeat (2) @(posedge clk50);
        
        repeat (7) send_byte(8'h55);           // preamble
        send_byte(8'hD5);                      // SFD
        foreach (frame[i]) send_byte(frame[i]);
        send_byte(fcs[7:0]);
        send_byte(fcs[15:8]);
        send_byte(fcs[23:16]);
        send_byte(fcs[31:24]);

        rmii_crs_dv <= 1'b0; // FIX: Non-blocking assignment
        rmii_rxd    <= '0;   // FIX: Non-blocking assignment

        repeat (12) @(posedge clk50);          // inter-frame gap
    endtask

    //-------------------------------------------------------------------------
    // Frame builder: DA + fixed SA + EtherType + pad to 60 bytes
    //-------------------------------------------------------------------------
    function automatic void make_frame(output logic [7:0] f[$], input logic [47:0] da, input logic [7:0]  seed);
        f.delete();
        for (int i = 0; i < 6; i++)
            // FIX: Restored shift/mask approach
            f.push_back( (da >> (8 * (5 - i))) & 8'hFF );
            
        f.push_back(8'h02);
        f.push_back(8'h00);
        f.push_back(8'h00);   // SA
        f.push_back(8'h00);
        f.push_back(8'h00);
        f.push_back(8'hAA);
        f.push_back(8'h08);
        f.push_back(8'h00);                        // EtherType

        while (f.size() < 60) f.push_back(seed + f.size());       // pad
    endfunction

    //-------------------------------------------------------------------------
    // Read-side consumer: rd_ready held high, just collect until rd_last
    //-------------------------------------------------------------------------
    task automatic read_frame(input logic [7:0] exp[$]);
        logic [7:0] got[$];
        bit done = 1'b0;
        int guard = 0;

        while (!done) begin
            @(posedge clk50);
            if (rd_valid) begin
                got.push_back(rd_data);
                if (rd_last) done = 1'b1;
            end

            if (++guard > 20000) begin
                errors++; $error("timeout waiting for frame");
                break;
            end
        end

        if (got.size() != exp.size()) begin
            errors++;
            $error("got %0d bytes, expected %0d", got.size(), exp.size());

        end else begin
            foreach (exp[i])
                if (got[i] !== exp[i]) begin
                    errors++;
                    $error("byte %0d: got %02h, expected %02h", i, got[i], exp[i]);
                end
        end

        $display("[%0t] frame received, %0d bytes", $time, got.size());
    endtask

    //-------------------------------------------------------------------------
    // Test sequence: unicast to our own MAC, good CRC -> must be received
    //-------------------------------------------------------------------------
    logic [7:0] f[$];

    initial begin
        $dumpfile("tb_rx_ethernet.vcd");
        $dumpvars(0, tb_rx_ethernet);
        
        repeat (5) @(posedge clk50);
        rst_n = 1'b1;
        repeat (5) @(posedge clk50);
        $display("--- Sending frame addressed to our MAC ---");

        make_frame(f, OUR_MAC, 8'h30);
        
        
        // FIX: Restored concurrent execution so the testbench doesn't time out
        fork
            send_frame(f);
            read_frame(f);
        join

        repeat (10) @(posedge clk50);

        // make_frame(f, 48'hFF_FF_FF_FF_FF_FF, 8'h40);
        // $display("--- Sending broadcast frame ---");
        
        // make_custom_frame(f, 48'hFF_FF_FF_FF_12_FF, 48'h02_00_00_00_00_01, 16'h0800, {8'h40, 8'h41, 8'h42});
        make_custom_frame(f, OUR_MAC, 48'h02_00_00_00_00_01, 16'h0800, {8'h40, 8'h41, 8'h42});

        fork
            send_frame(f);
            read_frame(f);
        join

        repeat (10) @(posedge clk50);

        if (errors == 0) $display("ALL TESTS PASSED");
        else $display("%0d ERROR(S)", errors);

        $finish;
    end



function automatic void make_custom_frame(
    output logic [7:0]  f[$],
    input  logic [47:0] destination_mac,
    input  logic [47:0] source_mac,
    input  logic [15:0] ether_type,
    input  logic [7:0]  payload[$]);

    f.delete();

    for (int i = 0; i < 6; i++)                          // DA
        f.push_back( 8'((destination_mac >> (8*(5-i))) & 8'hFF) );

    for (int i = 0; i < 6; i++)                          // SA -- use the argument!
        f.push_back( 8'((source_mac >> (8*(5-i))) & 8'hFF) );

    f.push_back(ether_type[15:8]);                       // EtherType, big-endian
    f.push_back(ether_type[7:0]);

    foreach (payload[i]) f.push_back(payload[i]);        // payload -- was missing!

    // while (f.size() < 60) f.push_back(8'h00);            // pad with zeros
endfunction









endmodule