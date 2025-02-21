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
    input decoder_output_ifc.out,

);


	//Register Renaming stuff
	parameter int NUM_ARCH_REGS = 32;
	parameter int NUM_PHYS_REGS = 64;
	parameter int INSTR_QUEUE_SIZE = 16;


	logic [5:0] fl_in;
	logic fl_out;

	

	logic [5:0] rmt [NUM_ARCH_REGS];

	circ_fifo free_list();
	circ_fifo #(6, 32) active_list();



	typedef struct {
		logic [31:0] instruction;
		logic [5:0] rd_phys;
		logic [5:0] rt_phys;
		logic [5:0] rs_phys;
		logic valid;
	} Instr_Queue_Entry_t;

	Instr_Queue_Entry_t instr_queue[INSTR_QUEUE_SIZE];









endmodule

