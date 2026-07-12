module rx_ethernet_tb;



logic clk50;
logic rst_n;

logic rmii_crs_dv;
logic [1:0] rmii_rxd;


always #10 clk50 = ~clk50;   // 50 MHz


logic [7:0] m_data;
logic m_valid;
logic frame_done;
logic frame_ok;

// DUT
rx_ethernet dut (
    .clk50(clk50),
    .rst_n(rst_n),

    .rmii_rxd(rmii_rxd),
    .rmii_crs_dv(rmii_crs_dv),

    .m_data(m_data), 
    .m_valid(m_valid), 
    .frame_done(frame_done), 
    .frame_ok(frame_ok)
);






// =========================================================================
// TASKS AND FUNCTIONS
// =========================================================================

//-------------------------------------------------------------------------
// Reference CRC32 (same algorithm as DUT) used to build the FCS
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
// Dibit-level driver (LSB pair first, one dibit per 50 MHz clock)
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

    // Compute FCS over the (uncorrupted) frame
    crc = 32'hFFFFFFFF;
    foreach (frame[i]) crc = crc32_byte(crc, frame[i]);
    fcs = ~crc;                          // transmitted complemented, LSB byte first

    rmii_crs_dv = 1'b1;
    repeat (2) @(posedge clk50);         // a little carrier before data

    repeat (7) send_byte(8'h55);         // preamble
    send_byte(8'hD5);                    // SFD

    foreach (frame[i]) begin
        b = frame[i];
        if (corrupt && i == 20) b ^= 8'hFF;   // flip one byte mid-frame
        send_byte(b);
    end
    send_byte(fcs[7:0]);
    send_byte(fcs[15:8]);
    send_byte(fcs[23:16]);
    send_byte(fcs[31:24]);

    rmii_crs_dv = 1'b0;
    rmii_rxd    = '0;
    repeat (10) @(posedge clk50);        // inter-frame gap
endtask


logic [7:0] frame[$];
logic [7:0] frame2[$];
logic expect_ok;

// Stimulus
initial begin
    clk50 = 1'b0;
    rst_n = 1'b0;
    expect_ok = 1'b1;
    for(int i = 0; i < 20; i++) begin
        frame.push_back(i);    
    end

    @(posedge clk50);
    rst_n = 1'b1;

    // send_frame(frame, 1'b0);     // good frame
    send_frame(frame, 1'b0);
    // for(int i = 0; i < 20; i++) begin
    //     frame2.push_back($urandom_range(0, 255));    
    // end
    #100;

    // send_frame(frame2, 1'b0);

    $display("Simulation Ended");
    // $finish;

end

endmodule