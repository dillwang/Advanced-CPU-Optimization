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
`include "branch_predictor_files/perceptron_predictor.sv"

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

    perceptron_predictor PREDICTOR (
    .clk, .rst_n,
    .i_req_valid     (request_prediction),
    .i_req_pc        (dec_pc.pc),
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

//     // Request
//     input logic i_req_valid,
//     input logic [`ADDR_WIDTH - 1 : 0] i_req_pc,
//     input logic [`ADDR_WIDTH - 1 : 0] i_req_target,
//     output mips_core_pkg::BranchOutcome o_req_prediction,

//     // Feedback
//     input logic i_fb_valid,
//     input logic [`ADDR_WIDTH - 1 : 0] i_fb_pc,
//     input mips_core_pkg::BranchOutcome i_fb_prediction,
//     input mips_core_pkg::BranchOutcome i_fb_outcome
 );

//     always_comb
//     begin
//         //o_req_prediction = NOT_TAKEN;
//         o_req_prediction = TAKEN;
//     end

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


module branch_predictor_gshare (
    input clk,    // Clock
    input rst_n,  // Synchronous reset active low

    // Request
    input logic i_req_valid,
    input logic [`ADDR_WIDTH - 1 : 0] i_req_pc,
    output mips_core_pkg::BranchOutcome o_req_prediction,

    // Feedback
    input logic i_fb_valid,
    input logic [`ADDR_WIDTH - 1 : 0] i_fb_pc,
    input mips_core_pkg::BranchOutcome i_fb_outcome
);
    // Parameters
    parameter GR_WIDTH = 16;      // Width of the global history register
    parameter TABLE_SIZE = 65536;  // Number of entries in the predictor table
    parameter INDEX_WIDTH = $clog2(TABLE_SIZE);

    // Signals
    logic [GR_WIDTH-1:0] global_history;   // Global history register
    logic [INDEX_WIDTH-1:0] index;         // Index into the table
    logic [1:0] counters [TABLE_SIZE-1:0]; // Predictor table of 2-bit counters

    // Generate index by XORing global history with lower bits of PC
    assign index = (i_req_pc[`ADDR_WIDTH-1:`ADDR_WIDTH-INDEX_WIDTH] ^ global_history);

    // Predict branch outcome based on the most significant bit of the counter
    assign o_req_prediction = counters[index][1] ? TAKEN : NOT_TAKEN;

    // Reset logic
    always_ff @(posedge clk or negedge rst_n)
    begin
        if (~rst_n)
        begin
            global_history <= '0;
            for (int i = 0; i < TABLE_SIZE; i++) begin
                counters[i] = 2'b01; // Initialize all counters to weakly not taken
            end
        end
        else
        begin
            // Update global history and counters on feedback
            if (i_fb_valid)
            begin
                // Update global history
                global_history <= {global_history[GR_WIDTH-2:0], i_fb_outcome == TAKEN};

                // Update the saturating counter
                case (i_fb_outcome)
                    TAKEN:
                        if (counters[index] != 2'b11)
                            counters[index] <= counters[index] + 1;
                    NOT_TAKEN:
                        if (counters[index] != 2'b00)
                            counters[index] <= counters[index] - 1;
                endcase
            end
        end
    end

endmodule
