module weight_table #(parameter int PERCEPTRON_NUMBER, int WEIGHT_NUMBER,
                     int HISTORY_SIZE, int WIDTH)(

    input clk,
    input rst_n,
    pc_ifc.in dec_pc,
    input logic update_enable,
    input logic [$clog2(PERCEPTRON_NUMBER)-1:0] selected_perceptron,
    input logic [HISTORY_SIZE-1:0] history,
    input logic signed [WIDTH-1:0] weight_update [PERCEPTRON_NUMBER][WEIGHT_NUMBER],
    output reg signed [WIDTH-1:0] weights [PERCEPTRON_NUMBER][WEIGHT_NUMBER]

);




    // storage
    reg signed [WIDTH-1:0] weight_table [PERCEPTRON_NUMBER][WEIGHT_NUMBER];


    //updating weights
    always_ff @(posedge clk or ~rst_n) begin
        //initialize weights to zero
        if(~rst_n) begin
            int i, j;
            for(i = 0; i < PERCEPTRON_NUMBER; i++) begin
                for(j = 0; j < WEIGHT_NUMBER; j++) begin
                    weight_table[i][j] <= 0;
                end
            end
        end else if(update_enable) begin
            weight_table[selected_perceptron] <= weight_update[selected_perceptron];
        end
    end

    assign weights[selected_perceptron] = weight_table[selected_perceptron];

endmodule
