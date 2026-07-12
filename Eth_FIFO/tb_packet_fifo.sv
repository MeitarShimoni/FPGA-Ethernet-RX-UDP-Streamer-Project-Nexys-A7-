`timescale 1ns/1ps
//=============================================================================
// tb_packet_fifo.sv
//
// Unit test for eth_packet_fifo (single-clock version, DEPTH=64 to make
// overflow easy to hit). Drives the write side the same way eth_frame_rx
// would (bytes, then a frame_done/frame_ok verdict one gap-cycle later),
// and reads with random backpressure.
//
// Tests:
//   1. Good frame          -> readable, correct bytes, LAST on final byte
//   2. Bad frame (CRC)     -> frame_dropped pulse, FIFO stays empty
//   3. Bad then good       -> only the good frame is readable
//   4. Two good frames     -> both readable, boundaries via rd_last
//   5. Oversized frame     -> overflow -> dropped; FIFO still healthy after
//=============================================================================
module tb_packet_fifo;

    localparam int DEPTH = 64;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #10 clk = ~clk;

    // DUT I/O
    logic [7:0] wr_data;
    logic       wr_valid   = 1'b0;
    logic       frame_done = 1'b0;
    logic       frame_ok   = 1'b0;
    logic       frame_dropped;
    logic [7:0] rd_data;
    logic       rd_last, rd_valid;
    logic       rd_ready   = 1'b0;

    eth_packet_fifo #(.DEPTH(DEPTH)) dut (.*);

    int errors  = 0;
    int n_drops = 0;

    always @(posedge clk)
        if (frame_dropped) n_drops++;

    //-------------------------------------------------------------------------
    // Write-side driver: mimics eth_frame_rx timing
    // (frame_done arrives with a gap after the last byte, never overlapping
    //  wr_valid -- same guarantee the real module gives)
    //-------------------------------------------------------------------------
    task automatic write_frame(input logic [7:0] bytes[$], input bit ok);
        foreach (bytes[i]) begin
            @(negedge clk);
            wr_data  = bytes[i];
            wr_valid = 1'b1;
        end
        @(negedge clk);
        wr_valid = 1'b0;
        @(negedge clk);                    // gap cycle
        frame_done = 1'b1;
        frame_ok   = ok;
        @(negedge clk);
        frame_done = 1'b0;
        frame_ok   = 1'b0;
    endtask

    //-------------------------------------------------------------------------
    // Read-side consumer with random backpressure.
    // Snapshot signals at negedge (stable, pre-edge values), so the recorded
    // transfer is exactly what the DUT sees at the following posedge.
    //-------------------------------------------------------------------------
    task automatic read_frame(input logic [7:0] exp[$], input string name);
        logic [7:0] got[$];
        bit         v, l, r;
        logic [7:0] d;
        bit         done = 1'b0;
        int         guard = 0;

        while (!done) begin
            @(negedge clk);
            rd_ready = ($urandom_range(0, 3) != 0);   // ~75% ready
            v = rd_valid; d = rd_data; l = rd_last; r = rd_ready;
            @(posedge clk);
            if (v && r) begin
                got.push_back(d);
                if (l) done = 1'b1;
            end
            if (++guard > 10000) begin
                errors++; $error("[%s] timeout waiting for frame", name);
                break;
            end
        end
        @(negedge clk);
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
        $display("[%0t] %s: read %0d bytes", $time, name, got.size());
    endtask

    // Check that the FIFO presents no data (used after drops)
    task automatic expect_empty(input string name);
        repeat (5) @(negedge clk);
        if (rd_valid) begin
            errors++;
            $error("[%s] FIFO offers data but should be empty", name);
        end else
            $display("[%0t] %s: FIFO empty as expected", $time, name);
    endtask

    function automatic void make_frame(output logic [7:0] f[$],
                                       input int len, input logic [7:0] seed);
        f.delete();
        for (int i = 0; i < len; i++) f.push_back(seed + i[7:0]);
    endfunction

    //-------------------------------------------------------------------------
    // Test sequence
    //-------------------------------------------------------------------------
    logic [7:0] fa[$], fb[$];
    int drops_before;

    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);

        //--- Test 1: single good frame ---------------------------------------
        $display("--- Test 1: good frame ---");
        make_frame(fa, 20, 8'h10);
        write_frame(fa, 1'b1);
        read_frame(fa, "T1");

        //--- Test 2: bad frame is rewound ------------------------------------
        $display("--- Test 2: bad frame ---");
        drops_before = n_drops;
        make_frame(fa, 20, 8'h30);
        write_frame(fa, 1'b0);
        expect_empty("T2");
        if (n_drops != drops_before + 1) begin
            errors++; $error("[T2] expected 1 frame_dropped pulse");
        end

        //--- Test 3: bad then good -> only good is visible -------------------
        $display("--- Test 3: bad then good ---");
        make_frame(fa, 15, 8'h50);
        make_frame(fb, 25, 8'h80);
        write_frame(fa, 1'b0);       // dropped
        write_frame(fb, 1'b1);       // kept
        read_frame(fb, "T3");
        expect_empty("T3b");

        //--- Test 4: two good frames, boundaries preserved --------------------
        $display("--- Test 4: two good frames ---");
        make_frame(fa, 10, 8'hA0);
        make_frame(fb, 12, 8'hC0);
        write_frame(fa, 1'b1);
        write_frame(fb, 1'b1);
        read_frame(fa, "T4a");
        read_frame(fb, "T4b");

        //--- Test 5: overflow -> drop, FIFO healthy afterwards ----------------
        $display("--- Test 5: overflow ---");
        drops_before = n_drops;
        make_frame(fa, DEPTH + 20, 8'h01);   // bigger than the whole FIFO
        write_frame(fa, 1'b1);               // CRC ok, but no room
        expect_empty("T5");
        if (n_drops != drops_before + 1) begin
            errors++; $error("[T5] expected 1 frame_dropped pulse");
        end
        make_frame(fb, 8, 8'hE0);            // FIFO must still work
        write_frame(fb, 1'b1);
        read_frame(fb, "T5b");

        //--- Summary ----------------------------------------------------------
        repeat (5) @(negedge clk);
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d ERROR(S)", errors);
        $finish;
    end

endmodule
