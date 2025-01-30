module branch_predictorTL(
    input clk,
    input rst_n,
    // Request
    pc_ifc.in dec_pc,
    branch_decoded_ifc.hazard dec_branch_decoded,
    // Feedback
    pc_ifc.in ex_pc,
    branch_result_ifc.in ex_branch_result,
    output logic prediction
);

    // Parameters
    parameter int PERCEPTRON_NUMBER = 64;
    parameter int WEIGHT_NUMBER = 65;
    parameter int HISTORY_SIZE = 64;

    // Signals
    logic [HISTORY_SIZE-1:0] history;
    logic signed [WIDTH-1:0] weights [PERCEPTRON_NUMBER][WEIGHT_NUMBER];
    logic signed [WIDTH-1:0] weight_update [PERCEPTRON_NUMBER][WEIGHT_NUMBER];


    function int hash(input logic [`ADDR_WIDTH-1:0] pc,
     input logic [HISTORY_SIZE-1:0] history);
        logic [23:0] pc_bits = .pc[25:2];       // Use PC[25:2] as per the paper
        logic [23:0] history_bits = history[23:0];
        return (pc_bits ^ history_bits) % PERCEPTRON_NUMBER;
    endfunction

    // Compute selected_perceptron using hash
    logic [$clog2(PERCEPTRON_NUMBER)-1:0] selected_perceptron;
    assign selected_perceptron = hash(dec_pc.pc, history_reg.history);

    // Modules
    ghr #(.HISTORY_SIZE(HISTORY_SIZE)) history_reg (
        .clk, .rst_n, .ex_branch_result, .history
    );

    perceptron_calc #(
        .PERCEPTRON_NUMBER(PERCEPTRON_NUMBER),
        .WEIGHT_NUMBER(WEIGHT_NUMBER),
        .HISTORY_SIZE(HISTORY_SIZE)
    ) percep (
        .clk,
        .rst_n,
        .history,
        .weights,
        .selected_perceptron(selected_perceptron),
        .prediction
    );

    perceptron_trainer #(
        .PERCEPTRON_NUMBER(PERCEPTRON_NUMBER),
        .WEIGHT_NUMBER(WEIGHT_NUMBER),
        .HISTORY_SIZE(HISTORY_SIZE)
    ) trainer (
        .clk, .rst_n, .prediction, .ex_branch_result,
        .selected_perceptron(selected_perceptron),
        .history, .weights, .weight_update
    );

    weight_table #(
        .PERCEPTRON_NUMBER(PERCEPTRON_NUMBER),
        .WEIGHT_NUMBER(WEIGHT_NUMBER),
        .HISTORY_SIZE(HISTORY_SIZE)
    ) table (
        .clk, .rst_n, .dec_pc, .history,
        .update_enable(ex_branch_result.valid),
        .selected_perceptron(selected_perceptron),
        .weight_update, .weights
    );

endmodule
