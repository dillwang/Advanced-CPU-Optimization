module perceptron_trainer(

input clk,
input rst_n,
input logic prediction,
input logic branch_outcome,
input logic [PERCEPTRON_NUMBER-1: 0] history,
input logic signed [WIDTH-1:0] weights [PERCEPTRON_NUMBER],
output reg signed [WIDTH-1:0] weight_update [PERCEPTRON_NUMBER]
);

    //PARAMETERS
    parameter int WEIGHT_NUMBER = 62;
    parameter int PERCEPTRON_NUMBER = 62;
    parameter int WIDTH = 8;
    parameter int INDEX = 6;
    parameter int THRESHOLD = 134;

    //training threshold
    reg theta;

    integer i;
    logic match = branch_outcome ~^ prediction;
    always_ff @(posedge clk or ~rst_n) begin
        if(~rst_n) begin
            for (i = 0; i < WEIGHT_NUMBER; i++) begin
                weight_update <= 0;
            end
            theta <= 0;
        end else if(~match || (theta < THRESHOLD)) begin
                for (i = 0; i < WEIGHT_NUMBER; i++) begin
                    weight_update[i] <= weights[i] + (branch_outcome ~^ history[i] ? 1 : -1);
                end
                theta <= theta + 1;
        end
        else begin
        end
    end



endmodule
