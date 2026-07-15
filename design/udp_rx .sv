`timescale 1ns/1ps
//=============================================================================
// udp_rx.sv
//
// UDP receive parser. Consumes clean frames from the packet FIFO read side
// (FWFT) and, for IPv4/UDP frames addressed to LISTEN_PORT, emits the UDP
// payload as a byte stream. Everything else is silently drained.
//
// Byte offsets within a frame (FCS already stripped by eth_frame_rx):
//   0-11   MACs (already vetted by mac_filter -> skipped)
//   12-13  EtherType         : must be 08 00 (IPv4)
//   14     IP version/IHL    : must be 45 (v1 limitation: no IP options)
//   23     IP protocol       : must be 11 (UDP)
//   26-29  source IP         : latched (for future replies)
//   34-35  UDP source port   : latched (for future replies)
//   36-37  UDP dest port     : must equal LISTEN_PORT (big-endian!)
//   38-39  UDP length        : payload bytes = udp_len - 8
//   42..   payload
//
// The pad trap: Ethernet pads short frames to 60 bytes, so rd_last does NOT
// mark the end of the payload -- the UDP length field does. pay_last is
// driven from a countdown loaded with (udp_len - 8); any pad afterwards is
// consumed in DRAIN.
//
// Resync guarantee: an accepted byte with rd_last returns the FSM to HEADER
// from ANY state -- every frame ends exactly once, so the parser can never
// wedge on a malformed frame.
//
// v1 simplifications (documented, easy upgrades):
//   * rd_ready is constant 1 (no backpressure toward the FIFO)
//   * destination IP not checked (accepts unicast and broadcast alike)
//   * IP header checksum and UDP checksum not verified
//   * IHL must be 5 (frames with IP options are drained)
//=============================================================================
module udp_rx #(
    parameter logic [15:0] LISTEN_PORT = 16'd5000
)(
    input  logic        clk,
    input  logic        rst_n,

    // FIFO read side (FWFT)
    input  logic [7:0]  rd_data,
    input  logic        rd_valid,
    input  logic        rd_last,
    output logic        rd_ready,

    // Payload stream out
    output logic [7:0]  pay_data,
    output logic        pay_valid,
    output logic        pay_last,

    // Latched from headers (stable once PAYLOAD begins; for future replies)
    output logic [31:0] src_ip,
    output logic [15:0] src_port
);

    typedef enum logic [1:0] {HEADER, PAYLOAD, DRAIN} state_t;
    state_t state;

    logic [10:0] cnt;        // offset of the byte being accepted THIS cycle
    logic [15:0] udp_len;
    logic [10:0] pay_left;   // payload bytes still to emit

    assign rd_ready = 1'b1;              // v1: always consume

    wire take = rd_valid && rd_ready;    // one byte accepted this cycle

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= HEADER;
            cnt       <= '0;
            pay_data  <= '0;
            pay_valid <= 1'b0;
            pay_last  <= 1'b0;
            udp_len   <= '0;
            pay_left  <= '0;
            src_ip    <= '0;
            src_port  <= '0;
        end else begin
            pay_valid <= 1'b0;
            pay_last  <= 1'b0;

            case (state)
                //-------------------------------------------------------------
                // Walk the headers. Convention: when 'take' is high, rd_data
                // is byte number 'cnt'; cnt increments after use. Any check
                // failing -> DRAIN. Reaching byte 41 therefore implies all
                // checks passed.
                //-------------------------------------------------------------
                HEADER: if (take) begin
                    cnt <= cnt + 1'b1;
                    case (cnt)
                        11'd12: if (rd_data != 8'h08) state <= DRAIN;
                        11'd13: if (rd_data != 8'h00) state <= DRAIN;
                        11'd14: if (rd_data != 8'h45) state <= DRAIN;
                        11'd23: if (rd_data != 8'h11) state <= DRAIN;

                        11'd26, 11'd27, 11'd28, 11'd29:
                            src_ip <= {src_ip[23:0], rd_data};

                        11'd34: src_port[15:8] <= rd_data;
                        11'd35: src_port[7:0]  <= rd_data;

                        11'd36: if (rd_data != LISTEN_PORT[15:8]) state <= DRAIN;
                        11'd37: if (rd_data != LISTEN_PORT[7:0])  state <= DRAIN;

                        11'd38: udp_len[15:8] <= rd_data;
                        11'd39: udp_len[7:0]  <= rd_data;

                        // byte 41 = last UDP header byte (checksum low byte).
                        // Next byte is payload -- arm the countdown.
                        11'd41: begin
                            if (udp_len > 16'd8) begin
                                pay_left <= udp_len[10:0] - 11'd8;
                                state    <= PAYLOAD;
                            end else begin
                                state <= DRAIN;   // empty or malformed length
                            end
                        end

                        default: ;                // uninteresting offsets
                    endcase
                end

                //-------------------------------------------------------------
                // Emit payload; the countdown -- not rd_last -- defines the
                // final byte (pad may follow inside the same frame).
                //-------------------------------------------------------------
                PAYLOAD: if (take) begin
                    pay_data  <= rd_data;
                    pay_valid <= 1'b1;
                    pay_left  <= pay_left - 11'd1;
                    if (pay_left == 11'd1) begin
                        pay_last <= 1'b1;
                        state    <= DRAIN;        // consume any pad
                    end
                end

                //-------------------------------------------------------------
                // Not our frame (or post-payload pad): swallow silently.
                //-------------------------------------------------------------
                DRAIN: ;

                default: state <= HEADER;
            endcase

            //-----------------------------------------------------------------
            // Global resync: the accepted byte carrying rd_last is the final
            // byte of the frame, whatever state we are in. Placed last so it
            // overrides any state decision made above (e.g. PAYLOAD's move
            // to DRAIN when the last payload byte is also the frame's last).
            //-----------------------------------------------------------------
            if (take && rd_last) begin
                state <= HEADER;
                cnt   <= '0;
            end
        end
    end

endmodule