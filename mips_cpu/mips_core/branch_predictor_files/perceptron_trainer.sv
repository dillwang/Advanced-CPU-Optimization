module perceptron_trainer(

input clk,
input rst_n,
input logic prediction,
branch_result_ifc.in ex_branch_result,
input logic [HISTORY_SIZE-1: 0] history,
input logic signed [WIDTH-1:0] weights [PERCEPTRON_NUMBER],
output logic signed [WIDTH-1:0] weight_update [PERCEPTRON_NUMBER]
);

    //PARAMETERS
    parameter int WEIGHT_NUMBER = 62;
    parameter int PERCEPTRON_NUMBER = 62;
    parameter int WIDTH = 8;
    parameter int INDEX = 6;
    parameter int THRESHOLD = 1.93 * HISTORY_SIZE + 14;

    //training threshold
    reg theta;

    integer i;
    logic match = ex_branch_result ~^ prediction;
    always_ff @(posedge clk or ~rst_n) begin
        if(~rst_n) begin
            for (i = 0; i < WEIGHT_NUMBER; i++) begin
                weight_update[i] <= 0;
            end
            theta <= 0;
        end else if(~match || (theta < THRESHOLD)) begin
                for (i = 0; i < WEIGHT_NUMBER; i++) begin
                    weight_update[i] <= weights[i] + (ex_branch_result.outcome ~^ history[i] ? 1 : -1);
                end
                theta <= theta + 1;
        end
        else begin
        end
    end



endmodule
