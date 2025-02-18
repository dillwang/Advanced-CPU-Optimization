module pr_sch (
	input clk,    // Clock
	input rst_n,  // Synchronous reset active low

	hazard_control_ifc.in i_hc,

	// Pipelined interfaces
	pc_ifc.in  i_pc,
	pc_ifc.out o_pc,

	alu_input_ifc.in  i_alu_input,
	alu_input_ifc.out o_alu_input,
	alu_pass_through_ifc.in  i_alu_pass_through,
	alu_pass_through_ifc.out o_alu_pass_through
);

	always_ff @(posedge clk)
	begin
		if(~rst_n)
		begin
			o_pc.pc <= '0;

			o_alu_input.valid <= '0;
			o_alu_input.alu_ctl <= ALUCTL_NOP;
			o_alu_input.op1 <= '0;
			o_alu_input.op2 <= '0;


			o_alu_pass_through.is_branch <= 1'b0;
			o_alu_pass_through.prediction <= NOT_TAKEN;
			o_alu_pass_through.recovery_target <= '0;

			o_alu_pass_through.is_mem_access <= 1'b0;
			o_alu_pass_through.mem_action <= READ;

			o_alu_pass_through.sw_data <= '0;

			o_alu_pass_through.uses_rw <= 1'b0;
			o_alu_pass_through.rw_addr <= zero;
		end
		else
		begin
			if (!i_hc.stall)
			begin
				if (i_hc.flush)
				begin
					o_pc.pc <= '0;

					o_alu_input.valid <= '0;
					o_alu_input.alu_ctl <= ALUCTL_NOP;
					o_alu_input.op1 <= '0;
					o_alu_input.op2 <= '0;


					o_alu_pass_through.is_branch <= 1'b0;
					o_alu_pass_through.prediction <= NOT_TAKEN;
					o_alu_pass_through.recovery_target <= '0;

					o_alu_pass_through.is_mem_access <= 1'b0;
					o_alu_pass_through.mem_action <= READ;

					o_alu_pass_through.sw_data <= '0;

					o_alu_pass_through.uses_rw <= 1'b0;
					o_alu_pass_through.rw_addr <= zero;
				end
				else
				begin
					o_pc.pc <= i_pc.pc;

					o_alu_input.valid <= i_alu_input.valid;
					o_alu_input.alu_ctl <= i_alu_input.alu_ctl;
					o_alu_input.op1 <= i_alu_input.op1;
					o_alu_input.op2 <= i_alu_input.op2;


					o_alu_pass_through.is_branch <= i_alu_pass_through.is_branch;
					o_alu_pass_through.prediction <= i_alu_pass_through.prediction;
					o_alu_pass_through.recovery_target <= i_alu_pass_through.recovery_target;

					o_alu_pass_through.is_mem_access <= i_alu_pass_through.is_mem_access;
					o_alu_pass_through.mem_action <= i_alu_pass_through.mem_action;

					o_alu_pass_through.sw_data <= i_alu_pass_through.sw_data;

					o_alu_pass_through.uses_rw <= i_alu_pass_through.uses_rw;
					o_alu_pass_through.rw_addr <= i_alu_pass_through.rw_addr;
				end
			end
		end
	end
endmodule