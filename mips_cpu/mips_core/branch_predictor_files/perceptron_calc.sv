
module perceptron_calc #(parameter int HISTORY_SIZE, int PERCEPTRON, int WEIGHT_NUMBER, int WIDTH)(
input clk,
input rst_n,
input logic [HISTORY_SIZE-1:0] history,
input logic [$clog2(PERCEPTRON_NUMBER)-1:0] selected_perceptron,
input logic signed [WIDTH-1:0] weights [PERCEPTRON_NUMBER],
output logic prediction
);




reg signed [31:0] sum;



always_comb begin
    sum = weights[selected_perceptron][0];  //bias weight
    for(int i = 1; i < WEIGHT_NUMBER; i++) begin
        sum += (history[i-1] ? weights[selected_perceptron][i] : -weights[selected_perceptron][i]);
    end
end

assign prediction = (sum >= 0) ? TAKEN : NOT_TAKEN;

endmodule
