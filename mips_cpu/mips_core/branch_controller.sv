/*
 * branch_controller.sv
 * Author: Zinsser Zhang
 * Last Revision: 04/08/2018
 *
 * branch_controller is a bridge between branch predictor to hazard controller.
 * Two simple predictors are also provided as examples.
 *
 * See wiki page "Branch and Jump" for details.
 */
`include "mips_core.svh"

module branch_controller (
    input clk,    // Clock
    input rst_n,  // Synchronous reset active low

    // Request
    pc_ifc.in dec_pc,
    branch_decoded_ifc.hazard dec_branch_decoded,

    // Feedback
    pc_ifc.in ex_pc,
    branch_result_ifc.in ex_branch_result
);
    logic request_prediction;

    // Change the following line to switch predictor
    // branch_predictor_always_not_taken PREDICTOR (
    //     .clk, .rst_n,

    //     .i_req_valid     (request_prediction),
    //     .i_req_pc        (dec_pc.pc),
    //     .i_req_target    (dec_branch_decoded.target),
    //     .o_req_prediction(dec_branch_decoded.prediction),

    //     .i_fb_valid      (ex_branch_result.valid),
    //     .i_fb_pc         (ex_pc.pc),
    //     .i_fb_prediction (ex_branch_result.prediction),
    //     .i_fb_outcome    (ex_branch_result.outcome)
    // );

    branch_predictor_global_share PREDICTOR (
    .clk,
    .rst_n,

    .i_req_valid     (request_prediction),
    .i_req_pc        (dec_pc.pc),
    .i_req_target    (dec_branch_decoded.target),
    .o_req_prediction(dec_branch_decoded.prediction),

    .i_fb_valid      (ex_branch_result.valid),
    .i_fb_pc         (ex_pc.pc),
    .i_fb_outcome    (ex_branch_result.outcome)
);


    always_comb
    begin
        request_prediction = dec_branch_decoded.valid & ~dec_branch_decoded.is_jump;
        dec_branch_decoded.recovery_target =
            (dec_branch_decoded.prediction == TAKEN)
            ? dec_pc.pc + `ADDR_WIDTH'd8
            : dec_branch_decoded.target;
    end

endmodule

module branch_predictor_always_not_taken (
    input clk,    // Clock
    input rst_n,  // Synchronous reset active low

    // Request
    input logic i_req_valid,
    input logic [`ADDR_WIDTH - 1 : 0] i_req_pc,
    input logic [`ADDR_WIDTH - 1 : 0] i_req_target,
    output mips_core_pkg::BranchOutcome o_req_prediction,

    // Feedback
    input logic i_fb_valid,
    input logic [`ADDR_WIDTH - 1 : 0] i_fb_pc,
    input mips_core_pkg::BranchOutcome i_fb_prediction,
    input mips_core_pkg::BranchOutcome i_fb_outcome
);

    always_comb
    begin
        //o_req_prediction = NOT_TAKEN;
        o_req_prediction = TAKEN;
    end

endmodule

module branch_predictor_2bit (
    input clk,    // Clock
    input rst_n,  // Synchronous reset active low

    // Request
    input logic i_req_valid,
    input logic [`ADDR_WIDTH - 1 : 0] i_req_pc,
    input logic [`ADDR_WIDTH - 1 : 0] i_req_target,
    output mips_core_pkg::BranchOutcome o_req_prediction,

    // Feedback
    input logic i_fb_valid,
    input logic [`ADDR_WIDTH - 1 : 0] i_fb_pc,
    input mips_core_pkg::BranchOutcome i_fb_prediction,
    input mips_core_pkg::BranchOutcome i_fb_outcome
);

    logic [1:0] counter;

    task incr;
        begin
            if (counter != 2'b11)
                counter <= counter + 2'b01;
        end
    endtask

    task decr;
        begin
            if (counter != 2'b00)
                counter <= counter - 2'b01;
        end
    endtask

    always_ff @(posedge clk)
    begin
        if(~rst_n)
        begin
            counter <= 2'b01;   // Weakly not taken
        end
        else
        begin
            if (i_fb_valid)
            begin
                case (i_fb_outcome)
                    NOT_TAKEN: decr();
                    TAKEN:     incr();
                endcase
            end
        end
    end

    always_comb
    begin
        o_req_prediction = counter[1] ? TAKEN : NOT_TAKEN;
    end

endmodule



module branch_predictor_global_share (
    input clk,    // Clock
    input rst_n,  // Reset active low

    // Request
    input logic i_req_valid,
    input logic [`ADDR_WIDTH - 1 : 0] i_req_pc,
    input logic [`ADDR_WIDTH - 1 : 0] i_req_target,
    output mips_core_pkg::BranchOutcome o_req_prediction,

    // Feedback
    input logic i_fb_valid,
    input logic [`ADDR_WIDTH - 1 : 0] i_fb_pc,
    input mips_core_pkg::BranchOutcome i_fb_outcome
);
    parameter integer GHR_BITS = 8;  // Global History Register size
    parameter integer PHT_ENTRIES = (1 << GHR_BITS); // Number of entries in PHT

    // Registers and Tables
    logic [GHR_BITS-1:0] ghr;                 // Global History Register
    logic [1:0] pht [0:PHT_ENTRIES-1];        // Pattern History Table

    // Prediction
    logic [1:0] prediction_counter;           // Counter value from PHT

    // Initialization
    integer i;
    initial begin
        for (i = 0; i < PHT_ENTRIES; i++) begin
            pht[i] = 2'b01; // Initialize all counters to weakly not taken
        end
    end

    // Request Prediction
    always_comb begin
        // Index into the PHT using GHR
        prediction_counter = pht[ghr];
        o_req_prediction = (prediction_counter[1]) ? TAKEN : NOT_TAKEN;
    end

    // Feedback and Updates
    always_ff @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            ghr <= '0; // Reset GHR to zero
        end else if (i_fb_valid) begin
            // Update the counter in PHT based on the outcome
            case (i_fb_outcome)
                TAKEN: begin
                    if (pht[ghr] != 2'b11) pht[ghr] <= pht[ghr] + 1; // Increment
                end
                NOT_TAKEN: begin
                    if (pht[ghr] != 2'b00) pht[ghr] <= pht[ghr] - 1; // Decrement
                end
            endcase

            // Update the GHR by shifting in the feedback outcome
            ghr <= {ghr[GHR_BITS-2:0], i_fb_outcome};
        end
    end

endmodule

