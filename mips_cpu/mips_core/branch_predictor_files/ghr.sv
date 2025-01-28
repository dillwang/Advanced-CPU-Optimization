module ghr(

    input clk,
    input rst_n,
    branch_result_ifc.in ex_branch_result,
    output reg history

);

    parameter int HISTORY_SIZE = 64;
    integer i;
    reg history_table[HISTORY_SIZE];

    always_ff@(posedge clk or ~rst_n) begin
        if(~rst_n) begin
            for(i = 0; i < HISTORY_SIZE; i++) begin
                history_table[i] <= 0;
            end
        end
        else begin
            history_table <= {history_table[HISTORY_SIZE-2:0], ex_branch_result};
        end
    end

    assign history = history_table;

endmodule
