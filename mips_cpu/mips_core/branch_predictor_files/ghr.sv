module ghr #(parameter int HISTORY_SIZE)(

    input clk,
    input rst_n,
    branch_result_ifc.in ex_branch_result,
    output reg [HISTORY_SIZE-1:0]history

);


    always_ff@(posedge clk or ~rst_n) begin
        if(~rst_n) begin
            history <= '0;
        end
        else if(ex_branch_result.valid) begin
            history <= {history[HISTORY_SIZE-2:0], ex_branch_result.outcome == TAKEN};
        end
    end


endmodule
