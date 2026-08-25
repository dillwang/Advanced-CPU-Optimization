/*
 * issue_queue.sv
 *
 * The instruction window. Dispatched instructions wait here until their
 * operands exist, then leave in whatever order they become ready -- this is
 * where the out of order behaviour actually comes from.
 *
 * Wakeup is not a broadcast CAM. Because the physical register file is written
 * at the end of the cycle an instruction executes and read asynchronously, a
 * result produced in cycle N is readable in cycle N + 1, and the busy table is
 * cleared on the same edge. So readiness is just a combinational look at the
 * busy bits of the two source tags, and dependent instructions still issue back
 * to back with no bypass network and no ready-bit bookkeeping.
 *
 * Select is oldest-first. Age comes from the distance between an entry's
 * reorder buffer index and the reorder buffer head, so it stays correct across
 * wraps and needs no age matrix.
 */
`include "mips_core.svh"

module issue_queue (
	input clk,    // Clock
	input rst_n,  // Synchronous reset active low

	// ---- dispatch ----
	input  uop_t disp_uop [FE_WIDTH],
	output logic [ROB_IDX_W : 0] iq_free,

	// ---- readiness ----
	input  logic [PHYS_REGS - 1 : 0] busy,
	input  rob_idx_t rob_head,
	input  logic [ROB_IDX_W : 0] rob_count,

	// ---- memory ordering constraints from the load/store queue ----
	input  logic lsq_accept,			// a memory op may start this cycle
	input  logic lsq_load_free,			// the D cache port is free for a load
	input  logic lsq_has_unresolved_store,
	input  rob_idx_t lsq_oldest_unresolved,

	// ---- issue ----
	output logic issue_valid [ISSUE_WIDTH],
	output uop_t issue_uop [ISSUE_WIDTH],

	// ---- squash ----
	input  logic squash,
	input  rob_idx_t squash_head,
	input  logic [ROB_IDX_W : 0] squash_count
);

	uop_t q [IQ_ENTRIES];
	logic q_valid [IQ_ENTRIES];

	logic [ROB_IDX_W : 0] age [IQ_ENTRIES];
	logic ready [IQ_ENTRIES];
	logic picked [IQ_ENTRIES];
	logic issue_hit [ISSUE_WIDTH];
	logic [$clog2(IQ_ENTRIES) - 1 : 0] issue_slot [ISSUE_WIDTH];

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Readiness
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	always_comb
	begin
		for (int i = 0; i < IQ_ENTRIES; i++)
		begin
			age[i] = {1'b0, rob_idx_t'(q[i].rob_idx - rob_head)};

			ready[i] = q_valid[i]
				&& !busy[q[i].ps1]
				&& !busy[q[i].ps2];

			// A branch or a jr may not resolve until its delay slot has been
			// dispatched. MIPS runs that instruction whatever the outcome, so
			// recovery keeps it, and it has to already be in the reorder
			// buffer for the squash range to be well defined.
			if ((q[i].is_branch || q[i].is_jump_reg) && (age[i] + 1 >= rob_count))
				ready[i] = 1'b0;

			// A load may not pass a store whose address is still unknown.
			// Older stores have all computed their addresses once no
			// unresolved store is older than this load.
			if (q[i].is_mem && (q[i].mem_action == READ)
				&& lsq_has_unresolved_store
				&& (age[i] > {1'b0, rob_idx_t'(lsq_oldest_unresolved - rob_head)}))
				ready[i] = 1'b0;

			// An entry this cycle's squash is about to kill must not start.
			// Letting one go would put a wrong path instruction into the
			// execution units, and a multi-cycle one could still be in flight
			// after its physical register had been freed and handed out again.
			if (squash
				&& ({1'b0, rob_idx_t'(q[i].rob_idx - squash_head)} >= squash_count))
				ready[i] = 1'b0;
		end
	end

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Select, oldest ready first
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	logic mem_taken;

	always_comb
	begin
		for (int i = 0; i < IQ_ENTRIES; i++)
			picked[i] = 1'b0;
		mem_taken = 1'b0;

		for (int s = 0; s < ISSUE_WIDTH; s++)
		begin
			automatic logic hit = 1'b0;
			automatic logic [ROB_IDX_W : 0] best = '0;
			automatic int best_i = 0;

			for (int i = 0; i < IQ_ENTRIES; i++)
			begin
				automatic logic ok = ready[i] && !picked[i];

				// Only one memory operation may start per cycle, and a load
				// additionally needs the cache port.
				if (ok && q[i].is_mem)
					ok = !mem_taken && lsq_accept
						&& ((q[i].mem_action == WRITE) || lsq_load_free);

				if (ok && (!hit || (age[i] < best)))
				begin
					hit = 1'b1;
					best = age[i];
					best_i = i;
				end
			end

			issue_hit[s] = hit;
			issue_slot[s] = $clog2(IQ_ENTRIES)'(best_i);
			issue_valid[s] = hit;
			issue_uop[s] = q[best_i];
			if (!hit)
				issue_uop[s].valid = 1'b0;

			if (hit)
			begin
				picked[best_i] = 1'b1;
				if (q[best_i].is_mem)
					mem_taken = 1'b1;
			end
		end
	end

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Allocation
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// Free slots are found by scanning, so an entry can be freed from anywhere
	// in the queue when it issues without any compaction.
	logic [ROB_IDX_W : 0] free_cnt;
	logic alloc_taken [IQ_ENTRIES];
	logic [$clog2(IQ_ENTRIES) - 1 : 0] alloc_slot [FE_WIDTH];
	logic alloc_hit [FE_WIDTH];

	always_comb
	begin
		free_cnt = '0;
		for (int i = 0; i < IQ_ENTRIES; i++)
		begin
			alloc_taken[i] = 1'b0;
			// An entry that issues this cycle frees up for the next one.
			if (!q_valid[i] || picked[i])
				free_cnt = free_cnt + 1'b1;
		end
		iq_free = free_cnt;

		for (int k = 0; k < FE_WIDTH; k++)
		begin
			automatic logic hit = 1'b0;
			automatic int slot = 0;
			for (int i = IQ_ENTRIES - 1; i >= 0; i--)
			begin
				// A slot being vacated by an instruction that issues this cycle
				// is available: the sequential block writes allocations after
				// it clears issued entries, so the allocation wins. This has to
				// match iq_free exactly -- if rename is told there is room and
				// the scan then finds none, the instruction lands in the
				// reorder buffer with no issue queue entry and can never
				// execute, which wedges the machine at commit.
				if ((!q_valid[i] || picked[i]) && !alloc_taken[i])
				begin
					hit = 1'b1;
					slot = i;
				end
			end
			alloc_hit[k] = hit && disp_uop[k].valid;
			alloc_slot[k] = $clog2(IQ_ENTRIES)'(slot);
			if (alloc_hit[k])
				alloc_taken[slot] = 1'b1;
		end
	end

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| State update
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	always_ff @(posedge clk)
	begin
		if (~rst_n)
		begin
			for (int i = 0; i < IQ_ENTRIES; i++)
				q_valid[i] <= 1'b0;
		end
		else
		begin
			// Issued entries leave.
			for (int s = 0; s < ISSUE_WIDTH; s++)
			begin
				if (issue_hit[s])
					q_valid[issue_slot[s]] <= 1'b0;
			end

			// Newly dispatched entries arrive.
			for (int k = 0; k < FE_WIDTH; k++)
			begin
				if (alloc_hit[k])
				begin
					q[alloc_slot[k]] <= disp_uop[k];
					q_valid[alloc_slot[k]] <= 1'b1;
				end
			end

			// Wrong path entries die. This runs last so that it also cancels a
			// dispatch made in the same cycle, though rename suppresses those.
			if (squash)
			begin
				for (int i = 0; i < IQ_ENTRIES; i++)
				begin
					if (q_valid[i]
						&& ({1'b0, rob_idx_t'(q[i].rob_idx - squash_head)} >= squash_count))
						q_valid[i] <= 1'b0;
				end
			end
		end
	end

	// A dispatched instruction that finds no slot would sit in the reorder
	// buffer forever with nothing able to execute it, and the machine would
	// simply stop retiring. Fail loudly instead of hanging.
`ifdef SIMULATION
	import "DPI-C" function void stats_event (input string e);

	always_ff @(posedge clk)
	begin
		if (rst_n)
		begin
			for (int k = 0; k < FE_WIDTH; k++)
			begin
				if (disp_uop[k].valid && !alloc_hit[k])
					$fatal(1, "issue_queue: dispatched pc=%x found no slot (iq_free=%0d)",
						disp_uop[k].pc, iq_free);
			end
		end
	end

	// How much parallelism the window actually holds, independent of how much
	// of it the two issue ports can take. A wider machine can only pay for
	// itself if there are regularly more than two ready instructions here, and
	// only if the single memory port is not what they are all waiting on.
	always_ff @(posedge clk)
	begin
		if (rst_n)
		begin
			automatic int n_ready = 0;
			automatic int n_ready_mem = 0;

			for (int i = 0; i < IQ_ENTRIES; i++)
			begin
				if (ready[i])
				begin
					n_ready = n_ready + 1;
					if (q[i].is_mem)
						n_ready_mem = n_ready_mem + 1;
				end
			end

			if (n_ready >= 1) stats_event("ready_ge1");
			if (n_ready >= 2) stats_event("ready_ge2");
			if (n_ready >= 3) stats_event("ready_ge3");
			if (n_ready >= 4) stats_event("ready_ge4");
			if (n_ready >= 6) stats_event("ready_ge6");
			if (n_ready_mem >= 2) stats_event("ready_mem_ge2");
		end
	end
`endif

endmodule
