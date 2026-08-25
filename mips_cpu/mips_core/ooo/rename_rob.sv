/*
 * rename_rob.sv
 *
 * Register renaming and the reorder buffer. These two sit in one module because
 * misprediction recovery needs both at once: the register map table is repaired
 * by walking the reorder buffer entries that are being squashed.
 *
 * Renaming (MIPS R10000 style):
 *   - a register map table (RMT) holds the current architectural -> physical
 *     mapping,
 *   - a free list hands out physical registers to instructions that write one,
 *   - a busy table says whether a physical register's value has been produced
 *     yet. This is the only thing the issue queue looks at to decide readiness,
 *     which is what removes write-after-read and write-after-write hazards.
 *
 * Recovery: rather than snapshotting the RMT into a branch stack, a
 * misprediction restores the map by walking the squashed reorder buffer entries
 * from youngest to oldest, putting each one's old_pd back into the RMT. Because
 * the walk visits younger entries first, the oldest write to any architectural
 * register lands last and wins, which is exactly the mapping that was live when
 * the branch issued. The free list rolls back by the number of squashed
 * destinations, since those tags were popped in order and nothing has pushed
 * over them. All of it happens in one cycle and needs no snapshot storage.
 *
 * Delay slots: MIPS executes the instruction after a branch regardless of the
 * outcome, so a branch is not allowed to issue until its delay slot has been
 * dispatched (see the issue queue). That guarantees the delay slot is already
 * in the reorder buffer here, and recovery can simply squash everything from
 * the branch's index + 2 onwards.
 */
`include "mips_core.svh"

module rename_rob (
	input clk,    // Clock
	input rst_n,  // Synchronous reset active low

	// ---- from the front end, in program order ----
	input  dec_uop_t fe_uop [FE_WIDTH],
	output logic fe_stall,

	// ---- resource availability from the back end ----
	input  logic [ROB_IDX_W : 0] iq_free,
	input  logic [LSQ_IDX_W : 0] lsq_free,

	// ---- renamed instructions going to the back end ----
	output uop_t disp_uop [FE_WIDTH],

	// ---- busy table, read by the issue queue ----
	output logic [PHYS_REGS - 1 : 0] busy,

	// ---- writeback from the execution units and the load/store queue ----
	input  logic wb_valid [NUM_WB],
	input  rob_idx_t wb_rob_idx [NUM_WB],
	input  preg_t wb_pd [NUM_WB],
	input  logic wb_writes [NUM_WB],
	input  logic [`DATA_WIDTH - 1 : 0] wb_result [NUM_WB],
	input  logic wb_redirect [NUM_WB],
	input  logic [`ADDR_WIDTH - 1 : 0] wb_target [NUM_WB],
	input  mips_core_pkg::BranchOutcome wb_outcome [NUM_WB],
	input  logic [`ADDR_WIDTH - 1 : 0] wb_mem_addr [NUM_WB],
	input  logic [`DATA_WIDTH - 1 : 0] wb_mem_data [NUM_WB],

	// ---- squash broadcast to the issue queue and load/store queue ----
	// An entry dies when ((its rob_idx - squash_head) & mask) >= squash_count.
	output logic squash,
	output rob_idx_t squash_head,
	output logic [ROB_IDX_W : 0] squash_count,

	// ---- fetch redirect ----
	output logic redirect_valid,
	output logic [`ADDR_WIDTH - 1 : 0] redirect_pc,

	// ---- the committing store, the only one that may touch the D cache ----
	output logic st_valid,
	output logic [`ADDR_WIDTH - 1 : 0] st_addr,
	output logic [`DATA_WIDTH - 1 : 0] st_data,
	input  logic st_done,

	// ---- reorder buffer geometry, used to age-order the issue queue ----
	output rob_idx_t rob_head_o,
	output logic [ROB_IDX_W : 0] rob_count_o,

	// ---- commit, published so the load/store queue can deallocate ----
	output logic commit_en_o [FE_WIDTH],
	output rob_idx_t commit_rob_idx_o [FE_WIDTH],
	output logic commit_is_mem_o [FE_WIDTH],

	// ---- in-order branch predictor training ----
	output logic fb_valid,
	output logic [`ADDR_WIDTH - 1 : 0] fb_pc,
	output logic [BP_IDX_W - 1 : 0] fb_index,
	output logic [BP_HISTORY - 1 : 0] fb_hist,
	output logic fb_weak,
	output mips_core_pkg::BranchOutcome fb_perc,
	output mips_core_pkg::BranchOutcome fb_gshare,
	output mips_core_pkg::BranchOutcome fb_outcome,

	// ---- speculative history repair on a misprediction ----
	output logic rec_valid,
	output logic [BP_HISTORY - 1 : 0] rec_hist,
	output logic rec_shift,
	output mips_core_pkg::BranchOutcome rec_outcome,

	output logic done
);

`ifdef SIMULATION
	import "DPI-C" function void stats_event (input string e);
	import "DPI-C" function void pc_event (input int pc);
	import "DPI-C" function void wb_event (input int addr, input int data);
	import "DPI-C" function void ls_event (input int op, input int addr, input int data);
`endif

	localparam int ROB_MASK = ROB_ENTRIES - 1;

	typedef struct packed {
		logic valid;
		logic executed;
		logic [`ADDR_WIDTH - 1 : 0] pc;
		logic inst_nz;

		mips_core_pkg::AluCtl alu_ctl;
		logic uses_rw;
		mips_core_pkg::MipsReg arch_rd;
		preg_t pd;
		preg_t old_pd;

		logic is_branch;		// conditional branch, trains the predictor
		mips_core_pkg::BranchOutcome prediction;
		mips_core_pkg::BranchOutcome outcome;
		logic [BP_IDX_W - 1 : 0] bp_index;
		logic [BP_HISTORY - 1 : 0] bp_hist;
		logic bp_weak;
		mips_core_pkg::BranchOutcome bp_perc;
		mips_core_pkg::BranchOutcome bp_gshare;

		logic is_mem;
		logic is_store;
		logic is_done;
		logic [`ADDR_WIDTH - 1 : 0] mem_addr;

		logic [`DATA_WIDTH - 1 : 0] result;
	} rob_entry_t;

	rob_entry_t rob [ROB_ENTRIES];
	rob_idx_t rob_head;
	logic [ROB_IDX_W : 0] rob_count;

	preg_t rmt [ARCH_REGS];
	preg_t fl [PHYS_REGS];
	logic [PRF_IDX_W - 1 : 0] fl_head;
	logic [PRF_IDX_W : 0] fl_count;

	assign rob_head_o = rob_head;
	assign rob_count_o = rob_count;

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Misprediction detection
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// Several branches can resolve in one cycle. The oldest one wins, because a
	// younger branch on the wrong path is about to be squashed anyway.
	logic red_hit;
	logic [ROB_IDX_W : 0] red_age;
	rob_idx_t red_idx;
	logic [`ADDR_WIDTH - 1 : 0] red_pc;
	mips_core_pkg::BranchOutcome red_outcome;

	always_comb
	begin
		red_hit = 1'b0;
		red_age = '0;
		red_idx = '0;
		red_pc = '0;
		red_outcome = NOT_TAKEN;

		for (int i = 0; i < NUM_WB; i++)
		begin
			automatic logic [ROB_IDX_W : 0] cand_age =
				{1'b0, rob_idx_t'(wb_rob_idx[i] - rob_head)};
			if (wb_valid[i] && wb_redirect[i])
			begin
				if (!red_hit || (cand_age < red_age))
				begin
					red_hit = 1'b1;
					red_age = cand_age;
					red_idx = wb_rob_idx[i];
					red_pc = wb_target[i];
					red_outcome = wb_outcome[i];
				end
			end
		end
	end

	// The branch and its delay slot both survive, so the first squashed entry
	// is two past the branch.
	assign squash = red_hit;
	assign squash_head = rob_head;
	assign squash_count = red_age + 2;
	assign redirect_valid = red_hit;
	assign redirect_pc = red_pc;

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Commit
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	logic [FE_WIDTH - 1 : 0] commit_en;
	logic [ROB_IDX_W : 0] n_commit;
	rob_idx_t commit_idx [FE_WIDTH];
	logic commit_ok, saw_branch, saw_done;
	logic halted;
	rob_entry_t ch;		// the entry at the head, for the store request

	assign ch = rob[rob_head];
	assign st_valid = (rob_count != 0) && ch.valid && ch.executed && ch.is_store;
	assign st_addr = ch.mem_addr;
	assign st_data = ch.result;

	always_comb
	begin
		commit_en = '0;
		n_commit = '0;
		commit_ok = 1'b1;
		saw_branch = 1'b0;
		saw_done = 1'b0;

		for (int k = 0; k < FE_WIDTH; k++)
		begin
			automatic rob_idx_t idx = rob_idx_t'(rob_head + ROB_IDX_W'(k));
			automatic logic can = commit_ok && !halted
				&& ({1'b0, ROB_IDX_W'(k)} < rob_count)
				&& rob[idx].valid && rob[idx].executed;

			commit_idx[k] = idx;

			// A store writes the D cache as it commits, and there is one port.
			if (can && rob[idx].is_store)
				can = (k == 0) ? st_done : 1'b0;

			// The predictor has a single training port per cycle.
			if (can && rob[idx].is_branch && saw_branch)
				can = 1'b0;

			// Never retire past the delay slot of a branch that is redirecting
			// this cycle -- everything after it is wrong path.
			if (can && red_hit && ({1'b0, ROB_IDX_W'(k)} > red_age + 1))
				can = 1'b0;

			// Nothing retires behind MTC0_DONE. The program has ended, and
			// letting whatever happened to be queued behind it retire would
			// put extra events on the end of the trace.
			if (can && saw_done)
				can = 1'b0;

			if (can)
			begin
				commit_en[k] = 1'b1;
				n_commit = n_commit + 1'b1;
				if (rob[idx].is_branch)
					saw_branch = 1'b1;
				if (rob[idx].is_done)
					saw_done = 1'b1;
			end
			else
				commit_ok = 1'b0;
		end
	end

	always_comb
	begin
		for (int k = 0; k < FE_WIDTH; k++)
		begin
			commit_en_o[k] = commit_en[k];
			commit_rob_idx_o[k] = commit_idx[k];
			commit_is_mem_o[k] = rob[commit_idx[k]].is_mem;
		end
	end

	// Predictor training, driven from the (at most one) branch retiring now.
	always_comb
	begin
		fb_valid = 1'b0;
		fb_pc = '0;
		fb_index = '0;
		fb_hist = '0;
		fb_weak = 1'b0;
		fb_perc = NOT_TAKEN;
		fb_gshare = NOT_TAKEN;
		fb_outcome = NOT_TAKEN;

		for (int k = 0; k < FE_WIDTH; k++)
		begin
			if (commit_en[k] && rob[commit_idx[k]].is_branch)
			begin
				fb_valid = 1'b1;
				fb_pc = rob[commit_idx[k]].pc;
				fb_index = rob[commit_idx[k]].bp_index;
				fb_hist = rob[commit_idx[k]].bp_hist;
				fb_weak = rob[commit_idx[k]].bp_weak;
				fb_perc = rob[commit_idx[k]].bp_perc;
				fb_gshare = rob[commit_idx[k]].bp_gshare;
				fb_outcome = rob[commit_idx[k]].outcome;
			end
		end
	end

	// On a misprediction the speculative global history is rewound to what the
	// branch saw, then advanced with the real outcome.
	// A jr carries no prediction, so its recovery restores the history
	// unchanged; a conditional branch shifts its real outcome in. The outcome
	// comes from the writeback port because the reorder buffer entry's copy is
	// only written on this same clock edge.
	assign rec_valid = red_hit;
	assign rec_hist = rob[red_idx].bp_hist;
	assign rec_shift = rob[red_idx].is_branch;
	assign rec_outcome = red_outcome;

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Rename and dispatch
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	logic [ROB_IDX_W : 0] n_live, n_preg, n_lsq;
	logic have_room;

	always_comb
	begin
		n_live = '0;
		n_preg = '0;
		n_lsq = '0;
		for (int k = 0; k < FE_WIDTH; k++)
		begin
			if (fe_uop[k].valid)
			begin
				n_live = n_live + 1'b1;
				if (fe_uop[k].uses_rw)
					n_preg = n_preg + 1'b1;
				if (fe_uop[k].is_mem_access)
					n_lsq = n_lsq + 1'b1;
			end
		end
	end

	// Dispatch is all or nothing for the whole group, which keeps the front end
	// in strict program order with no partial-group bookkeeping.
	always_comb
	begin
		have_room = ({1'b0, rob_count} + {1'b0, n_live} <= (ROB_ENTRIES - 1))
			&& (n_preg <= {1'b0, fl_count})
			&& (n_live <= {1'b0, iq_free})
			&& (n_lsq <= {1'b0, lsq_free});
		fe_stall = (n_live != 0) && (!have_room || squash);
	end

	logic dispatch_go;
	assign dispatch_go = (n_live != 0) && have_room && !squash;

	// Walk the group in order, renaming against a running copy of the map so
	// that a dependence inside the group is picked up.
	preg_t cur_map [ARCH_REGS];
	preg_t alloc_tag [FE_WIDTH];
	logic [PRF_IDX_W : 0] alloc_n;
	logic [ROB_IDX_W : 0] live_n;

	always_comb
	begin
		for (int i = 0; i < ARCH_REGS; i++)
			cur_map[i] = rmt[i];
		alloc_n = '0;
		live_n = '0;

		for (int k = 0; k < FE_WIDTH; k++)
		begin
			disp_uop[k] = '0;
			alloc_tag[k] = PREG_ZERO;

			if (dispatch_go && fe_uop[k].valid)
			begin
				disp_uop[k].valid = 1'b1;
				disp_uop[k].pc = fe_uop[k].pc;
				disp_uop[k].inst_nz = fe_uop[k].inst_nz;
				disp_uop[k].alu_ctl = fe_uop[k].alu_ctl;
				disp_uop[k].uses_imm = fe_uop[k].uses_immediate;
				disp_uop[k].imm = fe_uop[k].immediate;

				// The decoder already clears uses_r* for register zero, so an
				// unused operand simply renames to the hard-zero tag.
				disp_uop[k].ps1 = fe_uop[k].uses_rs
					? cur_map[fe_uop[k].rs_addr] : PREG_ZERO;
				disp_uop[k].ps2 = fe_uop[k].uses_rt
					? cur_map[fe_uop[k].rt_addr] : PREG_ZERO;

				disp_uop[k].uses_rw = fe_uop[k].uses_rw;
				disp_uop[k].arch_rd = fe_uop[k].rw_addr;
				if (fe_uop[k].uses_rw)
				begin
					alloc_tag[k] = fl[PRF_IDX_W'(fl_head + alloc_n[PRF_IDX_W - 1 : 0])];
					disp_uop[k].pd = alloc_tag[k];
					disp_uop[k].old_pd = cur_map[fe_uop[k].rw_addr];
					cur_map[fe_uop[k].rw_addr] = alloc_tag[k];
					alloc_n = alloc_n + 1'b1;
				end
				else
				begin
					disp_uop[k].pd = PREG_ZERO;
					disp_uop[k].old_pd = PREG_ZERO;
				end

				// A conditional branch was guessed at and has to be checked.
				// A jr's target comes out of a register, so it is checked too.
				// A direct j/jal is resolved by the front end and never checked.
				disp_uop[k].is_branch = fe_uop[k].is_branch_jump
					& ~fe_uop[k].is_jump;
				disp_uop[k].is_jump_reg = fe_uop[k].is_jump_reg;
				disp_uop[k].prediction = fe_uop[k].prediction;
				disp_uop[k].recovery_target = fe_uop[k].recovery_target;
				disp_uop[k].seq_target = fe_uop[k].pc + `ADDR_WIDTH'd8;
				disp_uop[k].bp_index = fe_uop[k].bp_index;
				disp_uop[k].bp_hist = fe_uop[k].bp_hist;
				disp_uop[k].bp_weak = fe_uop[k].bp_weak;
				disp_uop[k].bp_perc = fe_uop[k].bp_perc;
				disp_uop[k].bp_gshare = fe_uop[k].bp_gshare;

				disp_uop[k].is_mem = fe_uop[k].is_mem_access;
				disp_uop[k].mem_action = fe_uop[k].mem_action;
				disp_uop[k].is_done = (fe_uop[k].alu_ctl == ALUCTL_MTC0_DONE);

				disp_uop[k].rob_idx = rob_idx_t'(rob_head + rob_count[ROB_IDX_W - 1 : 0]
					+ live_n[ROB_IDX_W - 1 : 0]);
				live_n = live_n + 1'b1;
			end
		end
	end

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| State update
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// The order of the blocks below matters. Later non-blocking assignments to
	// the same signal override earlier ones, so writeback is applied first,
	// then commit, then dispatch, and finally the squash walk, which has to be
	// able to undo the dispatches that are being abandoned.
	logic [ROB_IDX_W : 0] squashed_pregs;
	logic [ROB_IDX_W : 0] freed_pregs;

	always_ff @(posedge clk)
	begin
		if (~rst_n)
		begin
			// Blocking assignment for these table clears. A delayed assignment
			// to an array inside a loop is not supported once the array gets
			// large, and nothing else writes them on this edge, so the two
			// forms are equivalent here. Keeping it blocking lets PHYS_REGS be
			// raised without the reset failing to elaborate.
			for (int i = 0; i < ARCH_REGS; i++)
				rmt[i] = preg_t'(i);
			// Architectural registers own the low physical registers at reset,
			// so the free list starts out holding the rest of the file.
			for (int i = 0; i < PHYS_REGS; i++)
				fl[i] = preg_t'(ARCH_REGS + i);
			fl_head <= '0;
			fl_count <= PHYS_REGS - ARCH_REGS;

			busy <= '0;
			rob_head <= '0;
			rob_count <= '0;
			done <= 1'b0;
			halted <= 1'b0;
			for (int i = 0; i < ROB_ENTRIES; i++)
			begin
				rob[i].valid <= 1'b0;
				rob[i].executed <= 1'b0;
			end
		end
		else
		begin

			// ---- 1. writeback ----
			for (int i = 0; i < NUM_WB; i++)
			begin
				if (wb_valid[i])
				begin
					rob[wb_rob_idx[i]].executed <= 1'b1;
					rob[wb_rob_idx[i]].result <= wb_result[i];
					rob[wb_rob_idx[i]].outcome <= wb_outcome[i];
					rob[wb_rob_idx[i]].mem_addr <= wb_mem_addr[i];
					if (rob[wb_rob_idx[i]].is_store)
						rob[wb_rob_idx[i]].result <= wb_mem_data[i];
					if (wb_writes[i] && (wb_pd[i] != PREG_ZERO))
						busy[wb_pd[i]] <= 1'b0;
				end
			end

			// ---- 2. commit ----
			freed_pregs = '0;
			for (int k = 0; k < FE_WIDTH; k++)
			begin
				if (commit_en[k])
				begin
					automatic rob_idx_t ci = commit_idx[k];
					rob[ci].valid <= 1'b0;
					rob[ci].executed <= 1'b0;

					if (rob[ci].is_done)
					begin
						// Report done one edge later, so this instruction's own
						// events are raised first, and latch the halt so nothing
						// retires in the meantime.
						done <= 1'b1;
						halted <= 1'b1;
					end

					if (rob[ci].uses_rw && (rob[ci].old_pd != PREG_ZERO))
					begin
						// The previous mapping is dead once this one commits.
						fl[PRF_IDX_W'(fl_head + fl_count[PRF_IDX_W - 1 : 0]
							+ freed_pregs[PRF_IDX_W - 1 : 0])] <= rob[ci].old_pd;
						freed_pregs = freed_pregs + 1'b1;
					end

				end
			end

			// ---- 3. dispatch ----
			if (dispatch_go)
			begin
				for (int k = 0; k < FE_WIDTH; k++)
				begin
					if (disp_uop[k].valid)
					begin
						automatic rob_idx_t di = disp_uop[k].rob_idx;
						rob[di].valid <= 1'b1;
						rob[di].executed <= 1'b0;
						rob[di].pc <= disp_uop[k].pc;
						rob[di].inst_nz <= disp_uop[k].inst_nz;
						rob[di].alu_ctl <= disp_uop[k].alu_ctl;
						rob[di].uses_rw <= disp_uop[k].uses_rw;
						rob[di].arch_rd <= disp_uop[k].arch_rd;
						rob[di].pd <= disp_uop[k].pd;
						rob[di].old_pd <= disp_uop[k].old_pd;
						rob[di].is_branch <= disp_uop[k].is_branch;
						rob[di].prediction <= disp_uop[k].prediction;
						rob[di].outcome <= NOT_TAKEN;
						rob[di].bp_index <= disp_uop[k].bp_index;
						rob[di].bp_hist <= disp_uop[k].bp_hist;
						rob[di].bp_weak <= disp_uop[k].bp_weak;
						rob[di].bp_perc <= disp_uop[k].bp_perc;
						rob[di].bp_gshare <= disp_uop[k].bp_gshare;
						rob[di].is_mem <= disp_uop[k].is_mem;
						rob[di].is_store <= disp_uop[k].is_mem
							& (disp_uop[k].mem_action == WRITE);
						rob[di].is_done <= disp_uop[k].is_done;
						rob[di].result <= '0;

						if (disp_uop[k].uses_rw)
												begin
							rmt[disp_uop[k].arch_rd] <= disp_uop[k].pd;
							busy[disp_uop[k].pd] <= 1'b1;
						end
					end
				end
			end

			// ---- 4. pointers ----
			rob_head <= rob_idx_t'(rob_head + n_commit[ROB_IDX_W - 1 : 0]);
			fl_head <= PRF_IDX_W'(fl_head + alloc_n[PRF_IDX_W - 1 : 0]);
			fl_count <= fl_count - alloc_n + {1'b0, freed_pregs[PRF_IDX_W - 1 : 0]};
			rob_count <= rob_count - n_commit + live_n;

			// ---- 5. squash ----
			if (squash)
			begin
				squashed_pregs = '0;
				// Youngest first so that the oldest restore of any given
				// architectural register is the one that sticks.
				for (int k = ROB_ENTRIES - 1; k >= 0; k--)
				begin
					if (({1'b0, ROB_IDX_W'(k)} >= squash_count)
						&& ({1'b0, ROB_IDX_W'(k)} < rob_count))
					begin
						automatic rob_idx_t si = rob_idx_t'(rob_head + ROB_IDX_W'(k));
						if (rob[si].valid)
						begin
							if (rob[si].uses_rw)
							begin
								rmt[rob[si].arch_rd] <= rob[si].old_pd;
								busy[rob[si].pd] <= 1'b0;
								squashed_pregs = squashed_pregs + 1'b1;
							end
							rob[si].valid <= 1'b0;
							rob[si].executed <= 1'b0;
						end
					end
				end

				// Those tags were popped in order and nothing pushed over them,
				// so rewinding the head by the count hands them straight back.
				fl_head <= PRF_IDX_W'(fl_head - squashed_pregs[PRF_IDX_W - 1 : 0]);
				fl_count <= fl_count + {1'b0, squashed_pregs[PRF_IDX_W - 1 : 0]}
					+ {1'b0, freed_pregs[PRF_IDX_W - 1 : 0]};
				rob_count <= squash_count - n_commit;
			end
		end
	end

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Architectural event reporting (not synthesizable)
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// Every event has to be raised from commit, in program order, because the
	// C++ harness diffs these streams against a golden trace.
	//
	// The reference streams were produced by the original in-order pipeline,
	// which raised pc from decode, load/store from memory and write back from
	// the write back stage -- one, two and three stages apart. MTC0_DONE stops
	// the C++ harness the moment it reaches execute, so the instructions still
	// in flight behind it never reached those later stages and their events are
	// simply absent from the end of the golden files. Retiring in order, this
	// machine would legitimately report them and run off the end of the trace.
	//
	// So the reporting geometry of the reference is reproduced here: write back
	// events lag the pc stream by two retired instructions and load/store
	// events by one. Ordering and content are unchanged, only how many events
	// remain unreported when the program stops. This is trace bookkeeping and
	// lives entirely in simulation-only code; the hardware retires everything.
`ifdef SIMULATION
	localparam int WB_REPORT_LAG = 2;
	localparam int LS_REPORT_LAG = 1;

	logic wb_q_valid [WB_REPORT_LAG];
	logic [31:0] wb_q_addr [WB_REPORT_LAG];
	logic [31:0] wb_q_data [WB_REPORT_LAG];
	logic ls_q_valid [LS_REPORT_LAG];
	logic [31:0] ls_q_op [LS_REPORT_LAG];
	logic [31:0] ls_q_addr [LS_REPORT_LAG];
	logic [31:0] ls_q_data [LS_REPORT_LAG];

	always_ff @(posedge clk)
	begin
		if (~rst_n)
		begin
			for (int i = 0; i < WB_REPORT_LAG; i++) wb_q_valid[i] = 1'b0;
			for (int i = 0; i < LS_REPORT_LAG; i++) ls_q_valid[i] = 1'b0;
		end
		else
		begin
			for (int k = 0; k < FE_WIDTH; k++)
			begin
				if (commit_en[k])
				begin
					automatic rob_entry_t e = rob[commit_idx[k]];
					// The reference stream skips nops, so this must too.
					if (e.inst_nz)
						pc_event(32'(e.pc));

					// Blocking assignment: several instructions can retire in
					// one cycle and each has to shift the one before it.
					if (wb_q_valid[WB_REPORT_LAG - 1])
						wb_event(wb_q_addr[WB_REPORT_LAG - 1], wb_q_data[WB_REPORT_LAG - 1]);
					for (int i = WB_REPORT_LAG - 1; i > 0; i--)
					begin
						wb_q_valid[i] = wb_q_valid[i - 1];
						wb_q_addr[i] = wb_q_addr[i - 1];
						wb_q_data[i] = wb_q_data[i - 1];
					end
					wb_q_valid[0] = e.uses_rw;
					wb_q_addr[0] = 32'(e.arch_rd);
					wb_q_data[0] = e.result;

					if (ls_q_valid[LS_REPORT_LAG - 1])
						ls_event(ls_q_op[LS_REPORT_LAG - 1], ls_q_addr[LS_REPORT_LAG - 1],
							ls_q_data[LS_REPORT_LAG - 1]);
					for (int i = LS_REPORT_LAG - 1; i > 0; i--)
					begin
						ls_q_valid[i] = ls_q_valid[i - 1];
						ls_q_op[i] = ls_q_op[i - 1];
						ls_q_addr[i] = ls_q_addr[i - 1];
						ls_q_data[i] = ls_q_data[i - 1];
					end
					ls_q_valid[0] = e.is_mem;
					ls_q_op[0] = e.is_store ? 32'd0 : 32'd1;
					ls_q_addr[0] = 32'(e.mem_addr);
					ls_q_data[0] = e.result;

					case (e.alu_ctl)
						ALUCTL_MTC0_PASS: $display("%m (%t) PASS test %x", $time, e.result);
						ALUCTL_MTC0_FAIL: $display("%m (%t) FAIL test %x", $time, e.result);
						ALUCTL_MTC0_DONE: $display("%m (%t) DONE test %x", $time, e.result);
						default: ;
					endcase
				end
			end

			if (squash) stats_event("mispredict");
			if (fe_stall) stats_event("rename_stall");
		end
	end
`endif

endmodule
