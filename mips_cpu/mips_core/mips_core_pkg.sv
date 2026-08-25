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

typedef enum logic [4:0] {
	zero = 5'd0,
	at = 5'd1,
	v0 = 5'd2,
	v1 = 5'd3,
	a0 = 5'd4,
	a1 = 5'd5,
	a2 = 5'd6,
	a3 = 5'd7,
	t0 = 5'd8,
	t1 = 5'd9,
	t2 = 5'd10,
	t3 = 5'd11,
	t4 = 5'd12,
	t5 = 5'd13,
	t6 = 5'd14,
	t7 = 5'd15,
	s0 = 5'd16,
	s1 = 5'd17,
	s2 = 5'd18,
	s3 = 5'd19,
	s4 = 5'd20,
	s5 = 5'd21,
	s6 = 5'd22,
	s7 = 5'd23,
	t8 = 5'd24,
	t9 = 5'd25,
	k0 = 5'd26,
	k1 = 5'd27,
	gp = 5'd28,
	sp = 5'd29,
	s8 = 5'd30,
	ra = 5'd31
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

// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
// |||| Out of order execution
// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
// Sizing of the out of order back end. FE_WIDTH is the width of the entire
// in-order front end (fetch, decode, rename, dispatch) and of commit; the two
// have to match so that the machine can retire as fast as it can rename.
// The free list holds PHYS_REGS - ARCH_REGS spare tags, and that is what
// bounds the window in practice rather than the reorder buffer. At 64 physical
// registers only 32 tags are spare, so at most 32 register-writing instructions
// can be in flight against a 64-entry reorder buffer -- the buffer could never
// fill, and on quickSort the free list was 100% of every dispatch stall.
parameter int PHYS_REGS    = 128;
parameter int PRF_IDX_W    = 7;		// $clog2(PHYS_REGS)
parameter int ARCH_REGS    = 32;
// The reset and squash loops over `rob` and `rmt` are non-blocking assignments
// to an unpacked array inside a for loop, which the simulator accepts only if
// it can fully unroll them -- and its default unroll budget is 64. Past that it
// reports BLKLOOPINIT. The Makefile therefore passes --unroll-count, which is
// all this needs; there is nothing wrong with the model.
parameter int ROB_ENTRIES  = 128;
parameter int ROB_IDX_W    = 7;		// $clog2(ROB_ENTRIES)
parameter int IQ_ENTRIES   = 32;
// Only worth anything once the reorder buffer is no longer the constraint: at
// 64 reorder buffer entries, doubling this measured zero to the cycle.
parameter int LSQ_ENTRIES  = 32;
parameter int LSQ_IDX_W    = 5;		// $clog2(LSQ_ENTRIES)
parameter int FE_WIDTH     = 3;		// decode / rename / dispatch / commit width
// How many words fetch pulls out of the instruction cache per cycle. This is
// deliberately wider than FE_WIDTH and is the whole point of the fetch buffer:
// at two words a fetch pair straddling the end of a cache line delivers one
// instruction, and so does the cycle after a taken branch whose delay slot fell
// outside the pair. Measured on coin, those two cost 5.86 M and 7.01 M cycles
// of half-width fetch respectively -- together more than half the run, against
// an instruction cache miss rate of 0.01%. Reading a whole line instead removes
// both, and decode still takes FE_WIDTH per cycle off the other end.
// Must not exceed the instruction cache's LINE_SIZE.
parameter int FETCH_WIDTH  = 4;
parameter int ISSUE_WIDTH  = 3;		// instructions started per cycle
// One writeback port per issue port for the ALUs, plus one for load data
// returning from the load/store queue an arbitrary number of cycles later.
parameter int NUM_WB       = ISSUE_WIDTH + 1;

// Branch predictor geometry. These live here rather than inside the predictor
// because a branch carries its predictor state with it through the reorder
// buffer, so the pipeline structs have to be able to name their widths.
parameter int BP_HISTORY   = 16;
parameter int BP_TABLES    = 1024;
parameter int BP_IDX_W     = 10;	// $clog2(BP_TABLES)

// Branch target buffer geometry. The BTB is what lets a prediction be made in
// fetch: it answers "is the instruction at this pc a branch, and where does it
// go" before the instruction itself has been decoded.
parameter int BTB_ENTRIES  = 512;
parameter int BTB_IDX_W    = 9;		// $clog2(BTB_ENTRIES)
// The tag is every pc bit above the index, so a hit is exact: it can only
// mean that this same pc was decoded as a direct branch or jump before.
parameter int BTB_TAG_W    = 26 - BTB_IDX_W - 2;	// ADDR_WIDTH - index - 2

// Miss status holding registers. This is how many D-cache line fills may be in
// flight at once, and so how many independent misses can overlap instead of
// serialising. The memory model accepts 4 reads per master id, so 4 is the most
// the interface can carry.
parameter int NUM_MSHR   = 4;
parameter int MSHR_IDX_W = 2;		// $clog2(NUM_MSHR)

// Memory dependence prediction. A load is normally held until every older
// store has computed its address, which makes disambiguation exact and replay
// unnecessary -- but on a store-heavy program it is also most of the idle time.
// Loads are therefore allowed past unresolved stores, and a store that turns
// out to write a word a younger load already read squashes that load.
//
// This table is the brake. It is a bit per load pc: set when that load causes a
// violation, and read at dispatch, and a load whose bit is set goes back to
// waiting for every older store. Almost all violations come from a handful of
// static loads, so one bit each is enough to stop them repeating.
parameter int MDP_ENTRIES = 1024;
parameter int MDP_IDX_W   = 10;		// $clog2(MDP_ENTRIES)
// The table is cleared every 2**MDP_CLEAR_W cycles, so a bit set by an aliasing
// pc or by a phase that has ended does not disable that load for the whole run.
parameter int MDP_CLEAR_W = 16;

typedef logic [PRF_IDX_W - 1 : 0] preg_t;
typedef logic [ROB_IDX_W - 1 : 0] rob_idx_t;
typedef logic [LSQ_IDX_W - 1 : 0] lsq_idx_t;
typedef logic [MSHR_IDX_W - 1 : 0] mshr_id_t;

// Physical register 0 is never allocated and never written, so it reads as a
// hard zero. The decoder already clears uses_r* for architectural register
// zero, so every unused operand renames to this tag and needs no special case
// anywhere else in the back end.
parameter preg_t PREG_ZERO = PRF_IDX_W'(0);

// A decoded instruction on its way into rename. This is just the fields of
// decoder_output_ifc flattened into a packed struct so that the front end can
// carry FE_WIDTH of them per cycle, plus the branch prediction made for it.
typedef struct packed {
	logic valid;
	logic [25:0] pc;
	// True when the encoded instruction word was not all zeroes. The reference
	// trace does not record nops, so commit uses this to stay in step with it.
	logic inst_nz;

	AluCtl alu_ctl;
	logic is_branch_jump;
	logic is_jump;
	logic is_jump_reg;
	logic [25:0] branch_target;

	logic is_mem_access;
	MemAccessType mem_action;

	logic uses_rs;
	MipsReg rs_addr;
	logic uses_rt;
	MipsReg rt_addr;
	logic uses_immediate;
	logic [31:0] immediate;
	logic uses_rw;
	MipsReg rw_addr;

	// Prediction made for this instruction, plus the predictor state that
	// produced it. Carrying the index/history/confidence along means the
	// perceptron can be trained in program order at commit with exactly the
	// state it predicted from, instead of whatever happens to be current.
	BranchOutcome prediction;
	logic [25:0] recovery_target;
	// Clear when the branch target buffer missed, so fetch never looked the
	// branch up and there is no predictor state to train or history to rewind.
	logic bp_valid;
	logic [BP_IDX_W - 1 : 0] bp_index;
	logic [BP_HISTORY - 1 : 0] bp_hist;
	logic bp_weak;
	BranchOutcome bp_perc;		// what the perceptron alone said
	BranchOutcome bp_gshare;	// what gshare alone said
} dec_uop_t;

// A decoded and renamed instruction, as it flows from rename into the reorder
// buffer, the issue queue and the load/store queue.
typedef struct packed {
	logic valid;
	logic [25:0] pc;
	logic inst_nz;

	AluCtl alu_ctl;
	logic uses_imm;
	logic [31:0] imm;

	// Renamed operands. ps1/ps2 are PREG_ZERO when the operand is unused.
	preg_t ps1;
	preg_t ps2;
	preg_t pd;
	preg_t old_pd;		// previous mapping of arch_rd, freed at commit
	logic uses_rw;
	MipsReg arch_rd;

	// Control flow. is_branch marks a conditional branch that the predictor
	// guessed at and that execute has to verify. is_jump_reg marks jr/jalr,
	// whose target is not known until the register is read.
	logic is_branch;
	logic is_jump_reg;
	// Any control transfer, conditional or not. The instruction after one is
	// its delay slot, and a delay slot can never be re-fetched on its own.
	logic is_ctrl;
	BranchOutcome prediction;
	logic [25:0] recovery_target;	// where to go if the guess was wrong
	logic [25:0] seq_target;		// pc + 8, the address after the delay slot
	logic bp_valid;					// predictor state below is real
	logic [BP_IDX_W - 1 : 0] bp_index;
	logic [BP_HISTORY - 1 : 0] bp_hist;
	logic bp_weak;
	BranchOutcome bp_perc;
	BranchOutcome bp_gshare;

	// Memory
	logic is_mem;
	MemAccessType mem_action;
	lsq_idx_t lsq_idx;
	// Set when the memory dependence predictor has seen this load violate. It
	// then waits for every older store instead of speculating past them.
	logic mem_wait;

	logic is_done;					// MTC0_DONE, ends the simulation

	rob_idx_t rob_idx;
} uop_t;

endpackage
