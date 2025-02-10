//New Stage for handling register renaming

interface decoder_output_ifc ();
	logic valid;
	mips_core_pkg::AluCtl alu_ctl;
	logic is_branch_jump;
	logic is_jump;
	logic is_jump_reg;
	logic [`ADDR_WIDTH - 1 : 0] branch_target;

	logic is_mem_access;
	mips_core_pkg::MemAccessType mem_action;

	logic uses_rs;
	mips_core_pkg::MipsReg rs_addr;

	logic uses_rt;
	mips_core_pkg::MipsReg rt_addr;

	logic uses_immediate;
	logic [`DATA_WIDTH - 1 : 0] immediate;

	logic uses_rw;
	mips_core_pkg::MipsReg rw_addr;

	modport in  (input valid, alu_ctl, is_branch_jump, is_jump, is_jump_reg,
		branch_target, is_mem_access, mem_action, uses_rs, rs_addr, uses_rt,
		rt_addr, uses_immediate, immediate, uses_rw, rw_addr);
	modport out (output valid, alu_ctl, is_branch_jump, is_jump, is_jump_reg,
		branch_target, is_mem_access, mem_action, uses_rs, rs_addr, uses_rt,
		rt_addr, uses_immediate, immediate, uses_rw, rw_addr);
endinterface



module register_renaming (
    input clk, rst_n,
    input 

);



endmodule

