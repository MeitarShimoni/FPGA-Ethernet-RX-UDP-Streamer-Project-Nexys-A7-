`timescale 1ns/1ps
//=============================================================================
// udp_rx.sv -- rev B: additionally latches the frame's SOURCE MAC
// (bytes 6-11), completing the address set needed to build replies:
// peer MAC + peer IP + peer port.
// Everything else identical to rev A (see header comments there / README).
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

    // Latched peer identity (stable once PAYLOAD begins)
    output logic [47:0] src_mac,     // frame bytes 6-11
    output logic [31:0] src_ip,      // frame bytes 26-29
    output logic [15:0] src_port     // frame bytes 34-35
);

    typedef enum logic [1:0] {HEADER, PAYLOAD, DRAIN} state_t;
    state_t state;

    logic [10:0] cnt;
    logic [15:0] udp_len;
    logic [10:0] pay_left;

    assign rd_ready = 1'b1;
    wire take = rd_valid && rd_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= HEADER;
            cnt       <= '0;
            pay_data  <= '0;
            pay_valid <= 1'b0;
            pay_last  <= 1'b0;
            udp_len   <= '0;
            pay_left  <= '0;
            src_mac   <= '0;
            src_ip    <= '0;
            src_port  <= '0;
        end else begin
            pay_valid <= 1'b0;
            pay_last  <= 1'b0;

            case (state)
                HEADER: if (take) begin
                    cnt <= cnt + 1'b1;
                    case (cnt)
                        11'd6, 11'd7, 11'd8, 11'd9, 11'd10, 11'd11:
                            src_mac <= {src_mac[39:0], rd_data};   // NEW

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

                        11'd41: begin
                            if (udp_len > 16'd8) begin
                                pay_left <= udp_len[10:0] - 11'd8;
                                state    <= PAYLOAD;
                            end else
                                state <= DRAIN;
                        end
                        default: ;
                    endcase
                end

                PAYLOAD: if (take) begin
                    pay_data  <= rd_data;
                    pay_valid <= 1'b1;
                    pay_left  <= pay_left - 11'd1;
                    if (pay_left == 11'd1) begin
                        pay_last <= 1'b1;
                        state    <= DRAIN;
                    end
                end

                DRAIN: ;
                default: state <= HEADER;
            endcase

            if (take && rd_last) begin
                state <= HEADER;
                cnt   <= '0;
            end
        end
    end

endmodule