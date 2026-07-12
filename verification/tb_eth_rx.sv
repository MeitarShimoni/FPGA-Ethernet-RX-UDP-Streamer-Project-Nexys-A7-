`timescale 1ns/1ps
//=============================================================================
// tb_eth_rx.sv
//
// Self-checking testbench: builds a minimal Ethernet frame (with a correctly
// computed FCS), serializes it into RMII dibits at 50 MHz, and drives it
// through rmii_rx -> eth_frame_rx. Checks that:
//   * the emitted byte stream matches the frame (FCS stripped)
//   * frame_ok is asserted at frame_done
// A second run corrupts one byte and expects frame_ok == 0.
//
// Tip for later: replace `frame` below with real bytes copied from a
// Wireshark capture ("Copy -> ...as a Hex Stream") to test against real
// traffic before ever touching hardware.
//=============================================================================
module tb_eth_rx;

    logic clk50;
    logic rst_n;
    always #10 clk50 = ~clk50;   // 50 MHz

    // RMII pins
    logic [1:0] rmii_rxd    = '0;
    logic       rmii_crs_dv = 1'b0;

    // DUT wiring
    logic [7:0] rx_data;
    logic       rx_valid, rx_frame_end;
    logic [7:0] m_data;
    logic       m_valid, frame_done, frame_ok;

    logic [7:0] frame[$];

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

    //-------------------------------------------------------------------------
    // Scoreboard: capture emitted bytes, compare at frame_done
    //-------------------------------------------------------------------------
    logic [7:0] expected[$];
    logic [7:0] got[$];
    bit         expect_ok;
    int         n_checked = 0;

    always @(posedge clk50) begin
        if (m_valid) got.push_back(m_data);
        if (frame_done) begin
            n_checked++;
            if (frame_ok !== expect_ok)
                $error("frame_ok=%0b, expected %0b", frame_ok, expect_ok);
            else
                $display("[%0t] frame_done, frame_ok=%0b as expected", $time, frame_ok);
            if (expect_ok) begin
                if (got.size() != expected.size())
                    $error("byte count %0d, expected %0d", got.size(), expected.size());
                else
                    foreach (expected[i])
                        if (got[i] !== expected[i])
                            $error("byte %0d: got %02h, expected %02h",
                                   i, got[i], expected[i]);
            end
            got.delete();
        end
    end

    //-------------------------------------------------------------------------
    // Stimulus: minimal 60-byte frame (broadcast DA, ARP EtherType)
    //-------------------------------------------------------------------------
    initial begin
        clk50 = 1'b0;
        rst_n = 1'b0;
        

        // DA = broadcast, SA = 02:00:00:00:00:01, EtherType = 0x0806 (ARP)
        frame = '{8'hFF,8'hFF,8'hFF,8'hFF,8'hFF,8'hFF,
                  8'h02,8'h00,8'h00,8'h00,8'h00,8'h01,
                  8'h08,8'h06};
        // while (frame.size() < 60) frame.push_back(frame.size()[7:0]); // pad
        while (frame.size() < 60) frame.push_back(frame.size());

        repeat (5) @(posedge clk50);
        rst_n = 1'b1;
        repeat (5) @(posedge clk50);

        // Test 1: good frame
        expected  = frame;
        expect_ok = 1'b1;
        send_frame(frame, 1'b0);

        // Test 2: corrupted frame -> CRC must fail
        expect_ok = 1'b0;
        send_frame(frame, 1'b1);

        repeat (20) @(posedge clk50);
        if (n_checked == 2) $display("TB finished: 2 frames checked.");
        else                $error("TB finished but only %0d frames checked", n_checked);
        $finish;
    end

endmodule
