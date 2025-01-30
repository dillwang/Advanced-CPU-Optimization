module perceptron_trainer(

input clk,
input rst_n,
input logic prediction,
branch_result_ifc.in ex_branch_result,
input logic [$clog2(PERCEPTRON_NUMBER)-1:0] selected_perceptron,
input logic [HISTORY_SIZE-1: 0] history,
input logic signed [WIDTH-1:0] weights [PERCEPTRON_NUMBER][WEIGHT_NUMBER],
output logic signed [WIDTH-1:0] weight_update [PERCEPTRON_NUMBER][WEIGHT_NUMBER]
);

    //PARAMETERS
    parameter int WEIGHT_NUMBER = 65;
    parameter int PERCEPTRON_NUMBER = 64;
    parameter int WIDTH = 8;
    parameter int HISTORY_SIZE = 64;

   localparam int THRESHOLD = FLOOR(1.93 * HISTORY_SIZE + 14);

    //training threshold
    reg theta;

    integer i;
    logic match = ex_branch_result ~^ prediction;
    always_ff @(posedge clk or ~rst_n) begin
        if(~rst_n) begin
            for(int p = 0; p < PERCEPTRON_NUMBER; i++) begin
                for (i = 0; i < WEIGHT_NUMBER; i++) begin
                    weight_update[p][i] <= 0;
                end
            end
            theta <= 0;
        end else if(ex_branch_result.valid) begin
            if((prediction != ex_branch_result.outcome) ||
                ($abs(perceptron_output) <= THRESHOLD)) begin
                for (i = 0; i < WEIGHT_NUMBER; i++) begin
                    if(ex_branch_result.outcome == TAKEN) begin
                        weight_update[selected_perceptron][i] <= weights[selected_perceptron][i]
                        + (history[i] ? 1 : -1);
                    end
                    else begin
                        weight_update[selected_perceptron][i] <= weights[selected_perceptron][i]
                         + (history[i] ? -1 : 1);
                    end
                end
                theta <= theta + 1;
            end
        end
    end



endmodule
