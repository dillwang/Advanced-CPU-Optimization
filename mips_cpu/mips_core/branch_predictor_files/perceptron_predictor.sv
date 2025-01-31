module perceptron_predictor (
    input clk,    // Clock
    input rst_n,  // Synchronous reset active low

    // Request interface
    input logic i_req_valid,
    input logic [`ADDR_WIDTH - 1 : 0] i_req_pc,
    input logic [`ADDR_WIDTH - 1 : 0] i_req_target,
    output mips_core_pkg::BranchOutcome o_req_prediction,

    // Feedback interface
    input logic i_fb_valid,
    input logic [`ADDR_WIDTH - 1 : 0] i_fb_pc,
    input mips_core_pkg::BranchOutcome i_fb_prediction,
    input mips_core_pkg::BranchOutcome i_fb_outcome
);

//parameters
    parameter int HISTORY_SIZE = 62;
    parameter int PERCEPTRON_NUMBER = 1024;
    parameter int WEIGHT_NUMBER = 63;
    parameter int WEIGHT_BITS = 8;
    localparam THRESHOLD = int'(1.93*HISTORY_SIZE + 14);

//GHR
    logic [HISTORY_SIZE-1:0] ghr;
    logic [HISTORY_SIZE-1:0] ghr_next;

//weight storage
    logic signed [WEIGHT_BITS-1:0] weights [PERCEPTRON_NUMBER][WEIGHT_NUMBER];
    logic signed [WEIGHT_BITS-1:0] weight_updates [PERCEPTRON_NUMBER][WEIGHT_NUMBER];

//prediction calc
    logic signed [31:0] perceptron_sum;
    logic [$clog2(PERCEPTRON_NUMBER)-1:0] perceptron_index;

//hash
    function int hash(input logic [`ADDR_WIDTH-1:0] pc);
            logic [23:0] pc_bits = pc[25:2];
            logic [23:0] history_bits = ghr[23:0];
            return (pc_bits ^ history_bits) % PERCEPTRON_NUMBER;
    endfunction

//ghr update
    always_ff @(posedge clk or ~rst_n) begin
        if(~rst_n) begin
            ghr <= '0;
        end else if(i_fb_valid) begin
            ghr <= ghr_next;
        end
    end

    always_comb begin
        ghr_next = {ghr[HISTORY_SIZE-1:0], (i_fb_outcome == TAKEN)};
    end

//perceptron index
    assign perceptron_index = hash(i_req_valid ? i_req_pc : i_fb_pc);
    