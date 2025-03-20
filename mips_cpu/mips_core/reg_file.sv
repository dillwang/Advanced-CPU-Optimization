/*
 * reg_file.sv
 * Author: Zinsser Zhang
 * Last Revision: 04/09/2018
 *
 * A 32-bit wide, 32-word deep register file with two asynchronous read port
 * and one synchronous write port.
 *
 * Register file needs to output '0 if uses_r* signal is low. In this case,
 * either reg zero is requested for read or the register is unused.
 *
 * See wiki page "Branch and Jump" for details.
 */
`include "mips_core.svh"
`include "mips_core/RegRenameOoO/register_renaming.sv"

interface reg_file_output_ifc ();
	logic [`DATA_WIDTH - 1 : 0] rs_data;
	logic [`DATA_WIDTH - 1 : 0] rt_data;

	modport in  (input rs_data, rt_data);
	modport out (output rs_data, rt_data);
endinterface

module reg_file (
	input clk,    // Clock

	// Input from decoder
	//decoder_output_ifc.in i_decoded,

	//input from reg rename
	reg_ren_ifc.in i_reg_ren,
	reg_ren_ifc.out o_reg_ren,

	// Input from write back stage
	write_back_ifc.in i_wb,

	// Output data
	reg_file_output_ifc.out out,

	output logic commit_rw

);






	logic [`DATA_WIDTH - 1 : 0] regs [5:0];

	assign out.rs_data = i_reg_ren.next_instr.uses_rs ? regs[i_reg_ren.next_instr.rs_phys] : '0;
	assign out.rt_data = i_reg_ren.next_instr.uses_rt ? regs[i_reg_ren.next_instr.rt_phys] : '0;

	always_ff @(posedge clk) begin
		if(i_wb.uses_rw)
		begin
			regs[i_wb.rw_addr] = i_wb.rw_data;
			commit_rw <= 1;
		end
		else begin
			commit_rw <= 0;
		end
	end

	always_comb begin
		if(i_wb.uses_rw) begin
			o_reg_ren.busy_bits[i_wb.rw_addr] = 0;
		end
	end



endmodule
