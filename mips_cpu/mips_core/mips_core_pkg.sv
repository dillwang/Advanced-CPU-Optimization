/*
 * mips_core_pkg.sv
 * Author: Zinsser Zhang
 * Last Revision: 04/09/2018
 *
 * This package defines all the enum types used across different units within
 * mips_core.
 *
 * See wiki page "Systemverilog Primer" section package and enum for details.
 */


package mips_core_pkg;

typedef enum logic [5:0] {
	zero = 6'd0,
	at = 6'd1,
	v0 = 6'd2,
	v1 = 6'd3,
	a0 = 6'd4,
	a1 = 6'd5,
	a2 = 6'd6,
	a3 = 6'd7,
	t0 = 6'd8,
	t1 = 6'd9,
	t2 = 6'd10,
	t3 = 6'd11,
	t4 = 6'd12,
	t5 = 6'd13,
	t6 = 6'd14,
	t7 = 6'd15,
	s0 = 6'd16,
	s1 = 6'd17,
	s2 = 6'd18,
	s3 = 6'd19,
	s4 = 6'd20,
	s5 = 6'd21,
	s6 = 6'd22,
	s7 = 6'd23,
	t8 = 6'd24,
	t9 = 6'd25,
	k0 = 6'd26,
	k1 = 6'd27,
	gp = 6'd28,
	sp = 6'd29,
	s8 = 6'd30,
	ra = 6'd31
} MipsReg;

typedef enum logic [4:0] {
	ALUCTL_NOP,			// No Operation (noop)
	ALUCTL_ADD,			// Add (signed)
	ALUCTL_ADDU,		// Add (unsigned)
	ALUCTL_SUB,			// Subtract (signed)
	ALUCTL_SUBU,		// Subtract (unsigned)
	ALUCTL_AND,			// AND
	ALUCTL_OR,			// OR
	ALUCTL_XOR,			// XOR
	ALUCTL_SLT,			// Set on Less Than
	ALUCTL_SLTU,		// Set on Less Than (unsigned)
	ALUCTL_SLL,			// Shift Left Logical
	ALUCTL_SRL,			// Shift Right Logical
	ALUCTL_SRA,			// Shift Right Arithmetic
	ALUCTL_SLLV,		// Shift Left Logical Variable
	ALUCTL_SRLV,		// Shift Right Logical Variable
	ALUCTL_SRAV,		// Shift Right Arithmetic Variable
	ALUCTL_NOR,			// NOR
	ALUCTL_MTC0_PASS,	// Move to Coprocessor (PASS)
	ALUCTL_MTC0_FAIL,	// Move to Coprocessor (FAIL)
	ALUCTL_MTC0_DONE,	// Move to Coprocessor (DONE)

	ALUCTL_BA,			// Unconditional branch
	ALUCTL_BEQ,
	ALUCTL_BNE,
	ALUCTL_BLEZ,
	ALUCTL_BGTZ,
	ALUCTL_BGEZ,
	ALUCTL_BLTZ
} AluCtl;

typedef enum logic {
	WRITE,
	READ
} MemAccessType;

typedef enum logic {
	NOT_TAKEN,
	TAKEN
} BranchOutcome;

 //Instruction Queue Entry
typedef struct {
	mips_core_pkg::AluCtl instruction; //alu_ctl
	mips_core_pkg::MipsReg rw_phys;
	mips_core_pkg::MipsReg rt_phys;
	mips_core_pkg::MipsReg rs_phys;
	logic valid; //same as alu?
	logic ready;
	logic is_branch_jump;
	logic is_jump;
	logic is_jump_reg;
	logic [`ADDR_WIDTH - 1 : 0] branch_target;
	logic is_mem_access;
	mips_core_pkg::MemAccessType mem_action;
	logic uses_rs;
	logic uses_rt;
	logic uses_immediate;
	logic [26 - 1 : 0] immediate;
	logic uses_rw;
	logic [31:0] count;
} Instr_Queue_Entry_t;

endpackage
