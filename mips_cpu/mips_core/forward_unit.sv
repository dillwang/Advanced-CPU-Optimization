/*
 * branch_controller.sv
 * Author: Pravin P. Prabhu, Zinsser Zhang
 * Last Revision: 04/08/2018
 *
 * Provides forwarding support to the pipeline (i.e. instructions that have
 * completed in later stages can have their results forwarded to newer
 * instructions that require them -- this improves performance by resolving
 * data dependencies without requiring a stall).
 *
 * See wiki page "Systemverilop Primer" section tasks for a potential bug in
 * this unit caused by using tasks incorrectly (due to sensitivity list)
 */
`include "mips_core.svh"

module forward_unit (
	// Input from decoder
	decoder_output_ifc.in decoded,
	reg_file_output_ifc.in reg_data,
	reg_ren_ifc.in rr_ifc,
	reg_ren_ifc.out rr_wb,

	// Feedback from EX stage
	alu_pass_through_ifc.in ex_ctl,
	alu_output_ifc.in ex_data,

	// Feedback from MEM stage
	write_back_ifc.in mem,

	// Feedback from WB stage
	write_back_ifc.in wb,

	// Output
	reg_file_output_ifc.out out,
	output logic o_lw_hazard
);

	task check_forward_rs;
		input logic uses_rs;
		input mips_core_pkg::MipsReg rs_addr;

		input logic condition;
		input mips_core_pkg::MipsReg r_source;
		input logic [`DATA_WIDTH - 1 : 0] d_source;
		begin
			if (uses_rs && (rs_addr == r_source) && condition) begin
				out.rs_data = d_source;
				rr_wb.busy_bits[rs_addr] = 0;	//this will throw a fit probably
			end
		end
	endtask

	task check_forward_rt;
		input logic uses_rt;
		input logic [5:0] rt_addr;

		input logic condition;
		input mips_core_pkg::MipsReg r_source;
		input logic [`DATA_WIDTH - 1 : 0] d_source;
		begin
			if (uses_rt && (rt_addr == r_source) && condition) begin
				out.rt_data = d_source;
				rr_wb.busy_bits[rt_addr] = 0;	//this will also probably throw a fit
			end
		end
	endtask

	task check_forward;
		input logic uses_rs;
		input logic uses_rt;
		input mips_core_pkg::MipsReg rs_addr;
		input mips_core_pkg::MipsReg rt_addr;

		input logic condition;
		input mips_core_pkg::MipsReg r_source;
		input logic [`DATA_WIDTH - 1 : 0] d_source;
		begin
			check_forward_rs(uses_rs, rs_addr, condition, r_source, d_source);
			check_forward_rt(uses_rt, rt_addr, condition, r_source, d_source);
		end
	endtask

	always_comb
	begin
		out.rs_data = reg_data.rs_data;
		out.rt_data = reg_data.rt_data;

		// Forward WB stage
		check_forward(rr_ifc.next_instr.uses_rs, rr_ifc.next_instr.uses_rt,
			rr_ifc.next_instr.rs_phys, rr_ifc.next_instr.rt_phys,
			wb.uses_rw, wb.rw_addr, wb.rw_data);

		// Forward MEM stage
		check_forward(rr_ifc.next_instr.uses_rs, rr_ifc.next_instr.uses_rt,
			rr_ifc.next_instr.rs_phys, rr_ifc.next_instr.rt_phys,
			mem.uses_rw, mem.rw_addr, mem.rw_data);

		// Forward EX stage
		check_forward(rr_ifc.next_instr.uses_rs, rr_ifc.next_instr.uses_rt,
			rr_ifc.next_instr.rs_phys, rr_ifc.next_instr.rt_phys,
			ex_data.valid & ex_ctl.uses_rw & ~ex_ctl.is_mem_access,
			ex_ctl.rw_addr, ex_data.result);
	end

	always_comb
	begin
		o_lw_hazard = ex_data.valid & ex_ctl.uses_rw & ex_ctl.is_mem_access
			& ((rr_ifc.next_instr.uses_rs & (rr_ifc.next_instr.rs_phys == ex_ctl.rw_addr))
				| (rr_ifc.next_instr.uses_rt & (rr_ifc.next_instr.rt_phys == ex_ctl.rw_addr))
				| rr_ifc.busy_bits[rr_ifc.next_instr.rt_phys] | rr_ifc.busy_bits[rr_ifc.next_instr.rs_phys]);
				// or phys?
				//added last two ors, should check if either is busy
	end

endmodule
