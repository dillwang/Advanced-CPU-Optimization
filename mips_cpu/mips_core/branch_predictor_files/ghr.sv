module ghr(

    input clk,
    input rst_n,
    branch_result_ifc.in ex_branch_result,
    output reg history

);

    parameter int HISTORY_SIZE = 64;

    always_ff@(posedge clk or ~rst_n) begin
        if(~rst_n) begin
            history <= '0;
        end
        else if(ex_branch_result.valid) begin
            history <= {history[HISTORY_SIZE-2:0], ex_branch_result.outcome == TAKEN};
        end
    end


endmodule
