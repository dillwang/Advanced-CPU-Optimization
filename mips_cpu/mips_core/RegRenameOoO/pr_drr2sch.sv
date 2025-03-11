module pr_drr2sch (
    input clk, rst_n,
    hazard_control_ifc.in i_hc,

    // Input from decode + register renaming stage
    decoder_output_ifc.in i_decoded,
    reg_ren_ifc.in i_reg,
    alu_pass_through_ifc.in i_alu_pass_through,

    // Output to scheduling stage
    decoder_output_ifc.out o_decoded,
    reg_ren_ifc.out o_reg,
    alu_pass_through_ifc.out o_alu_pass_through
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            // Reset all outputs
            o_decoded.valid <= 0;
            o_decoded.alu_ctl <= ALUCTL_NOP;
            o_decoded.is_branch_jump <= 0;
            o_decoded.is_jump <= 0;
            o_decoded.is_jump_reg <= 0;
            o_decoded.branch_target <= 0;
            o_decoded.is_mem_access <= 0;
            o_decoded.mem_action <= READ;
            o_decoded.uses_rs <= 0;
            o_decoded.rs_addr <= 0;
            o_decoded.uses_rt <= 0;
            o_decoded.rt_addr <= 0;
            o_decoded.uses_immediate <= 0;
            o_decoded.immediate <= 0;
            o_decoded.uses_rw <= 0;
            o_decoded.rw_addr <= 0;

            o_reg.next_instr <= '0;
            o_reg.instr_wr <= 0;

            o_alu_pass_through.is_branch <= 0;
            o_alu_pass_through.prediction <= NOT_TAKEN;
            o_alu_pass_through.recovery_target <= 0;
            o_alu_pass_through.is_mem_access <= 0;
            o_alu_pass_through.mem_action <= READ;
            o_alu_pass_through.sw_data <= 0;
            o_alu_pass_through.uses_rw <= 0;
            o_alu_pass_through.rw_addr <= 0;
        end else if (!i_hc.stall) begin
            if (i_hc.flush) begin
                // Flush all outputs
                o_decoded.valid <= 0;
                o_decoded.alu_ctl <= ALUCTL_NOP;
                o_decoded.is_branch_jump <= 0;
                o_decoded.is_jump <= 0;
                o_decoded.is_jump_reg <= 0;
                o_decoded.branch_target <= 0;
                o_decoded.is_mem_access <= 0;
                o_decoded.mem_action <= READ;
                o_decoded.uses_rs <= 0;
                o_decoded.rs_addr <= 0;
                o_decoded.uses_rt <= 0;
                o_decoded.rt_addr <= 0;
                o_decoded.uses_immediate <= 0;
                o_decoded.immediate <= 0;
                o_decoded.uses_rw <= 0;
                o_decoded.rw_addr <= 0;

                o_reg.next_instr <= '0;
                o_reg.instr_wr <= 0;

                o_alu_pass_through.is_branch <= 0;
                o_alu_pass_through.prediction <= NOT_TAKEN;
                o_alu_pass_through.recovery_target <= 0;
                o_alu_pass_through.is_mem_access <= 0;
                o_alu_pass_through.mem_action <= READ;
                o_alu_pass_through.sw_data <= 0;
                o_alu_pass_through.uses_rw <= 0;
                o_alu_pass_through.rw_addr <= 0;
            end else begin
                // Pass through all inputs to outputs
                o_decoded <= i_decoded;
                o_reg <= i_reg;
                o_alu_pass_through <= i_alu_pass_through;
            end
        end
    end
endmodule