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
    parameter int WEIGHT_NUMBER = HISTORY_SIZE + 1;
    parameter int WEIGHT_BITS = 8;
    localparam THRESHOLD = int'(1.93*HISTORY_SIZE + 14);

//GHR
    logic [HISTORY_SIZE-1:0] ghr;
    logic [HISTORY_SIZE-1:0] ghr_next;

//weight storage
    logic signed [WEIGHT_BITS-1:0] weights [PERCEPTRON_NUMBER][WEIGHT_NUMBER];

//prediction calc
    logic signed [31:0] perceptron_sum;
    logic signed [31:0] stored_perceptron_sum;
    logic [$clog2(PERCEPTRON_NUMBER)-1:0] perceptron_index;

//hash
    function int hash(input logic [`ADDR_WIDTH-1:0] pc);
            logic [23:0] pc_bits = pc[25:2];
            logic [23:0] history_bits = ghr[23:0];
            return (pc_bits ^ history_bits) % (PERCEPTRON_NUMBER);
    endfunction

//ghr update
    always_ff @(posedge clk) begin
        if(~rst_n) begin
            ghr <= '0;
        end else if(i_fb_valid) begin
            ghr <= ghr_next;
        end
    end

    always_comb begin
        ghr_next = {ghr[HISTORY_SIZE-2:0], (i_fb_outcome == TAKEN)};
    end

//perceptron index
    logic [$clog2(PERCEPTRON_NUMBER)-1:0] stored_index;
    assign perceptron_index = hash(i_req_pc);

    always_ff @(posedge clk) begin
    if (i_req_valid) begin
        stored_index <= perceptron_index;
        stored_perceptron_sum <= perceptron_sum;
    end
end

//prediction calc
    always_comb begin
        perceptron_sum = weights[perceptron_index][0]; //bias term
        for(int i = 1; i < WEIGHT_NUMBER; i++) begin
            perceptron_sum += ghr[i-1] ?
                weights[perceptron_index][i] :
                -weights[perceptron_index][i];
        end
    o_req_prediction = (perceptron_sum >= 0) ? TAKEN : NOT_TAKEN;
    perceptron_threshold <= perceptron_sum;
    end

//weight update

    always_ff @(posedge clk or negedge rst_n) begin
        if(~rst_n) begin
            //init weights to 0
            foreach(weights[i, j]) begin
                weights[i][j] <= 0;
            end
        end else if(i_fb_valid) begin
            if((o_req_prediction != i_fb_outcome) ||
                    ($abs(perceptron_threshold) <= THRESHOLD)) begin
                for(int i = 0; i < WEIGHT_NUMBER; i++) begin
                    logic hbit = (i == 0) ? 1'b1 : ghr[i-1];
                    if (i_fb_outcome == TAKEN) begin
                        weights[perceptron_index][i] <= 
                            saturate(weights[perceptron_index][i] + (hbit ? 1 : -1));
                    end else begin
                        weights[perceptron_index][i] <= 
                            saturate(weights[perceptron_index][i] + (hbit ? -1 : 1));
                    end
                end
            end
        end
    end

    //saturate weights to avoid overflow

    function logic signed [WEIGHT_BITS-1:0] saturate(input logic signed [31:0] value);
        if(value > (2**(WEIGHT_BITS-1))-1) begin
            return (2**(WEIGHT_BITS-1))-1;
        end
        else if (value < -(2**(WEIGHT_BITS-1))) begin
            return -(2**(WEIGHT_BITS-1));
        end
        else begin
            return value[WEIGHT_BITS-1:0];
        end
    endfunction

endmodule

