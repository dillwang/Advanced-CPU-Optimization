
module perceptron_calc(
input clk,
input rst_n,
input logic history,
input logic signed [WIDTH-1:0] weights [PERCEPTRON_NUMBER],
output logic prediction
);


parameter int PERCEPTRON_NUMBER = 62;
parameter int WIDTH = 8;

integer i;
integer idx;
reg signed [31:0] sum;



always_comb begin
    sum = 0;
    for(i = 0; i < PERCEPTRON_NUMBER; i++) begin
        sum = sum + (history[idx][i] ? weights[idx][i] : -weights[idx][i]);
    end
end

assign prediction = (sum >= 0) ? 1 : 0;

endmodule
