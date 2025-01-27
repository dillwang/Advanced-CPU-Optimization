module weight_table(

    input clk,
    input rst_n,
    input logic update_enable,
    input logic signed [WIDTH-1:0] weight_update [N],
    output reg signed [WIDTH-1:0] weights [N]

);

    //PARAMETERS
    parameter int WEIGHT_NUMBER = 62;
    parameter int PERCEPTRON_NUMBER = 62;
    parameter int WIDTH = 8;
    parameter int INDEX = 6;


    // storage
    reg signed [WIDTH-1:0] weight_values [WEIGHT_NUMBER][WEIGHT_NUMBER];


    /*
    TODO: IMPLEMENT HASH, JUST NEED ADDRESS/PC WIDTH
    HASH FUNCTION TO BE IMPLEMENTED HERE
    */

    // weights
    always_comb begin
        weights = weight_values[idx];
    end


    always_ff @(posedge clk or ~rst_n) begin
        //initialize weights to zero
        if(~rst_n) begin
            int i, j;
            for(i = 0; i < PERCEPTRON_NUMBER; i++) begin
                for(j = 0; j < WEIGHT_NUMBER; j++) begin
                    weight_values[i][j] <= 0;
                end
            end
        end else if(update_enable) begin
            weight_values[idx] <= weight_update;
        end
        else begin
        end
    end

endmodule
