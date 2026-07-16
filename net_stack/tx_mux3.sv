`timescale 1ns/1ps

module tx_mux3 (
    input  logic        clk,
    input  logic        rst_n,

    // Port A (priority)
    input  logic [47:0] a_dst_mac,
    input  logic [15:0] a_ether_type,
    input  logic [7:0]  a_pl_data,
    input  logic        a_pl_valid,
    input  logic        a_pl_last,
    output logic        a_pl_ready,

    // Port B
    input  logic [47:0] b_dst_mac,
    input  logic [15:0] b_ether_type,
    input  logic [7:0]  b_pl_data,
    input  logic        b_pl_valid,
    input  logic        b_pl_last,
    output logic        b_pl_ready,

    // Port C
    input  logic [47:0] c_dst_mac,
    input  logic [15:0] c_ether_type,
    input  logic [7:0]  c_pl_data,
    input  logic        c_pl_valid,
    input  logic        c_pl_last,
    output logic        c_pl_ready,

    // To tx_ethernet
    output logic [47:0] dst_mac,
    output logic [15:0] ether_type,
    output logic [7:0]  pl_data,
    output logic        pl_valid,
    output logic        pl_last,
    input  logic        pl_ready
);

    typedef enum logic [1:0] {IDLE, GRANT_A, GRANT_B, GRANT_C} state_t;
    state_t state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= IDLE;
        else begin
            case (state)
                IDLE:    if      (a_pl_valid) state <= GRANT_A;
                         else if (b_pl_valid) state <= GRANT_B;
                         else if (c_pl_valid) state <= GRANT_C;
                GRANT_A: if (a_pl_valid && a_pl_ready && a_pl_last)
                             state <= IDLE;
                GRANT_B: if (b_pl_valid && b_pl_ready && b_pl_last)
                             state <= IDLE;
                GRANT_C: if (c_pl_valid && c_pl_ready && c_pl_last)
                             state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end

    always_comb begin
        // defaults: nobody granted
        dst_mac    = '0;
        ether_type = '0;
        pl_data    = '0;
        pl_valid   = 1'b0;
        pl_last    = 1'b0;
        a_pl_ready = 1'b0;
        b_pl_ready = 1'b0;

        case (state)
            GRANT_A: begin
                dst_mac    = a_dst_mac;
                ether_type = a_ether_type;
                pl_data    = a_pl_data;
                pl_valid   = a_pl_valid;
                pl_last    = a_pl_last;
                a_pl_ready = pl_ready;
            end
            GRANT_B: begin
                dst_mac    = b_dst_mac;
                ether_type = b_ether_type;
                pl_data    = b_pl_data;
                pl_valid   = b_pl_valid;
                pl_last    = b_pl_last;
                b_pl_ready = pl_ready;
            end
            GRANT_C: begin
                dst_mac    = c_dst_mac;
                ether_type = c_ether_type;
                pl_data    = c_pl_data;
                pl_valid   = c_pl_valid;
                pl_last    = c_pl_last;
                c_pl_ready = pl_ready;
            end
            default: ;
        endcase
    end

endmodule
