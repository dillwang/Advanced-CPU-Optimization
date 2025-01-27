module branch_predictorTL(

    input clk,    // Clock
    input rst_n,  // Synchronous reset active low

    // Request
    pc_ifc.in dec_pc,
    branch_decoded_ifc.hazard dec_branch_decoded,

    // Feedback
    pc_ifc.in ex_pc,
    branch_result_ifc.in ex_branch_result,
    output logic prediction
);




endmodule
