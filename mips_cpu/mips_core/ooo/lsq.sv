/*
 * lsq.sv
 *
 * The load/store queue. It holds every memory instruction in program order from
 * dispatch until commit and owns the single D cache port.
 *
 * Ordering rules:
 *   - Stores never touch the cache speculatively. A store computes its address
 *     and data when it issues, sits in the queue, and is written to the cache
 *     only when the reorder buffer retires it. A squashed store therefore
 *     cannot have changed memory.
 *   - A load may issue ahead of older stores only once every older store has
 *     computed its address (the issue queue enforces this using
 *     o_oldest_unresolved). At that point the load can be disambiguated
 *     exactly, so no replay mechanism is needed.
 *   - A load that matches an older store in the queue takes its value straight
 *     from the queue instead of the cache (store to load forwarding). The
 *     youngest matching older store wins.
 *
 * The D cache reads its SRAM using addr_next a cycle ahead of addr, so an
 * access is set up in the cycle the address is computed and presented in the
 * following one.
 */
`include "mips_core.svh"

module lsq (
	input clk,    // Clock
	input rst_n,  // Synchronous reset active low

	// ---- dispatch ----
	input  uop_t disp_uop [FE_WIDTH],
	output lsq_idx_t disp_lsq_idx [FE_WIDTH],
	output logic [LSQ_IDX_W : 0] lsq_free,

	// ---- issue of a memory operation ----
	// The address comes from the ALU on the issuing port, the store data from
	// the second source operand.
	input  logic mem_issue,
	input  uop_t mem_uop,
	input  logic [`ADDR_WIDTH - 1 : 0] mem_addr,
	input  logic [`DATA_WIDTH - 1 : 0] mem_data,

	// ---- constraints published back to the issue queue ----
	output logic o_accept,
	output logic o_load_free,
	output logic o_pf_allow,
	output logic o_has_unresolved,
	output rob_idx_t o_oldest_unresolved,
	input  rob_idx_t rob_head,

	// ---- load writeback ----
	output logic ld_wb_valid,
	output rob_idx_t ld_wb_rob_idx,
	output preg_t ld_wb_pd,
	output logic ld_wb_writes,
	output logic [`DATA_WIDTH - 1 : 0] ld_wb_data,
	output logic [`ADDR_WIDTH - 1 : 0] ld_wb_addr,

	// ---- the committing store ----
	input  logic st_valid,
	input  logic [`ADDR_WIDTH - 1 : 0] st_addr,
	input  logic [`DATA_WIDTH - 1 : 0] st_data,
	output logic st_done,

	// ---- deallocation, driven by commit ----
	input  logic commit_en [FE_WIDTH],
	input  rob_idx_t commit_rob_idx [FE_WIDTH],
	input  logic commit_is_mem [FE_WIDTH],

	// ---- squash ----
	input  logic squash,
	input  rob_idx_t squash_head,
	input  logic [ROB_IDX_W : 0] squash_count,

	// ---- D cache ----
	d_cache_input_ifc.out dc_in,
	cache_output_ifc.in dc_out
);

`ifdef SIMULATION
	import "DPI-C" function void stats_event (input string e);
`endif

	typedef struct packed {
		logic valid;
		logic is_store;
		rob_idx_t rob_idx;
		logic addr_valid;
		logic [`ADDR_WIDTH - 1 : 0] addr;
		logic [`DATA_WIDTH - 1 : 0] data;
	} lsq_entry_t;

	lsq_entry_t e [LSQ_ENTRIES];
	lsq_idx_t lsq_head, lsq_tail;
	logic [LSQ_IDX_W : 0] lsq_count;

	// The access presented to the D cache this cycle. This is a one deep
	// pipeline register rather than a state machine: the cache addresses its
	// SRAM from addr_next and compares tags against addr, which are a cycle
	// apart, so an access can be set up in the same cycle that the previous one
	// completes. An idle-per-access state machine cannot do that and caps the
	// port at one access every two cycles, which on a load heavy program is the
	// binding limit long before the cache itself is.
	logic acc_valid;
	logic acc_is_store;
	logic [`ADDR_WIDTH - 1 : 0] acc_addr;
	logic [`DATA_WIDTH - 1 : 0] acc_data;	// store data
	rob_idx_t acc_rob;						// load identity
	preg_t acc_pd;
	logic acc_writes;
	logic acc_killed;

	// The access to present next cycle, and whose address goes out on
	// addr_next now.
	logic nxt_valid;
	logic nxt_is_store;
	logic [`ADDR_WIDTH - 1 : 0] nxt_addr;
	logic [`DATA_WIDTH - 1 : 0] nxt_data;
	rob_idx_t nxt_rob;
	preg_t nxt_pd;
	logic nxt_writes;
	logic nxt_killed;

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Disambiguation
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// The oldest store that has not yet produced an address. The issue queue
	// uses this to hold back any load younger than it.
	always_comb
	begin
		o_has_unresolved = 1'b0;
		o_oldest_unresolved = '0;
		for (int i = 0; i < LSQ_ENTRIES; i++)
		begin
			automatic logic [ROB_IDX_W : 0] a =
				{1'b0, rob_idx_t'(e[i].rob_idx - rob_head)};
			if (e[i].valid && e[i].is_store && !e[i].addr_valid)
			begin
				if (!o_has_unresolved
					|| (a < {1'b0, rob_idx_t'(o_oldest_unresolved - rob_head)}))
				begin
					o_has_unresolved = 1'b1;
					o_oldest_unresolved = e[i].rob_idx;
				end
			end
		end
	end

	// Store to load forwarding: the youngest store that is older than the
	// issuing load and hits the same word supplies the data.
	logic fwd_hit;
	logic [`DATA_WIDTH - 1 : 0] fwd_data;
	logic [ROB_IDX_W : 0] issue_age;

	always_comb
	begin
		automatic logic [ROB_IDX_W : 0] best_age = '0;

		issue_age = {1'b0, rob_idx_t'(mem_uop.rob_idx - rob_head)};
		fwd_hit = 1'b0;
		fwd_data = '0;

		for (int i = 0; i < LSQ_ENTRIES; i++)
		begin
			automatic logic [ROB_IDX_W : 0] a =
				{1'b0, rob_idx_t'(e[i].rob_idx - rob_head)};
			if (e[i].valid && e[i].is_store && e[i].addr_valid
				&& (a < issue_age) && (e[i].addr == mem_addr))
			begin
				// Keep the youngest match, which is the store that would have
				// been the last to write this word before the load runs.
				if (!fwd_hit || (a > best_age))
				begin
					fwd_hit = 1'b1;
					fwd_data = e[i].data;
					best_age = a;
				end
			end
		end
	end

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| D cache port
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// A commit store has priority; loads use the port when it is free.
	logic start_load;
	logic start_store;
	logic acc_abandon;		// a squashed load, whose answer nobody wants
	logic acc_done;
	logic port_free;

	assign acc_abandon = acc_valid && !acc_is_store && acc_killed;
	assign acc_done = acc_valid && (dc_out.valid || acc_abandon);
	// The port can take a new access whenever it is empty or the access on it
	// finishes this cycle. That last case is what makes it a pipeline: the
	// finishing access is still being compared against addr while the next one
	// is already addressing the SRAM through addr_next.
	assign port_free = !acc_valid || acc_done;

	assign start_load = mem_issue && (mem_uop.mem_action == READ) && !fwd_hit
		&& port_free;
	// A store that is already on the port must not be launched a second time;
	// st_valid stays asserted until st_done answers it.
	assign start_store = st_valid && port_free && !start_load
		&& !(acc_valid && acc_is_store);

	// A memory operation may issue whenever the port could take it. Holding
	// issue back to this also keeps at most one load completing per cycle,
	// which is what lets the forwarding path and the cache path share a single
	// writeback port.
	assign o_accept = port_free;
	// A load can only be set up when nothing else is claiming the port, since
	// the cache SRAM has to be addressed a cycle in advance.
	assign o_load_free = port_free && !st_valid;

	always_comb
	begin
		nxt_valid = 1'b0;
		nxt_is_store = 1'b0;
		nxt_addr = '0;
		nxt_data = '0;
		nxt_rob = '0;
		nxt_pd = '0;
		nxt_writes = 1'b0;
		nxt_killed = 1'b0;

		if (acc_valid && !acc_done)
		begin
			// Still waiting on the cache: hold everything, including addr_next,
			// so the SRAM read is set up again for when the refill finishes.
			nxt_valid = 1'b1;
			nxt_is_store = acc_is_store;
			nxt_addr = acc_addr;
			nxt_data = acc_data;
			nxt_rob = acc_rob;
			nxt_pd = acc_pd;
			nxt_writes = acc_writes;
			nxt_killed = acc_killed
				|| (squash && !acc_is_store
					&& ({1'b0, rob_idx_t'(acc_rob - squash_head)} >= squash_count));
		end
		else if (start_load)
		begin
			nxt_valid = 1'b1;
			nxt_addr = mem_addr;
			nxt_rob = mem_uop.rob_idx;
			nxt_pd = mem_uop.pd;
			nxt_writes = mem_uop.uses_rw;
		end
		else if (start_store)
		begin
			nxt_valid = 1'b1;
			nxt_is_store = 1'b1;
			nxt_addr = st_addr;
			nxt_data = st_data;
		end
	end

	// The D-cache prefetcher borrows the tag array while nothing else needs it.
	// It may only do so when no access is being set up, because a request is
	// presented to the cache one cycle after its address appears on addr_next.
	assign o_pf_allow = !nxt_valid && !mem_issue && !st_valid;

	always_comb
	begin
		dc_in.valid = acc_valid && !acc_abandon;
		dc_in.mem_action = acc_is_store ? WRITE : READ;
		dc_in.addr = acc_addr;
		dc_in.data = acc_data;
		// The address the cache should read its SRAM at for next cycle. When
		// nothing follows, leave the current address there rather than zero, so
		// a stalled access keeps its own row selected.
		dc_in.addr_next = nxt_valid ? nxt_addr : acc_addr;
	end

	assign st_done = acc_valid && acc_is_store && dc_out.valid;

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Load writeback
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// A forwarded load is answered the cycle after it issues; a load that went
	// to the cache is answered when the cache returns.
	logic fwd_pending;
	rob_idx_t fwd_rob;
	preg_t fwd_pd;
	logic fwd_writes;
	logic [`DATA_WIDTH - 1 : 0] fwd_val;
	logic [`ADDR_WIDTH - 1 : 0] fwd_addr;

	// A squash landing on the same cycle as a completion cancels that
	// completion only when the load is genuinely on the wrong path. Cancelling
	// unconditionally would drop the result of a load that survived, and its
	// reorder buffer entry would then never complete.
	logic fwd_squashed, ld_squashed;
	assign fwd_squashed = squash
		&& ({1'b0, rob_idx_t'(fwd_rob - squash_head)} >= squash_count);
	assign ld_squashed = squash
		&& ({1'b0, rob_idx_t'(acc_rob - squash_head)} >= squash_count);

	always_comb
	begin
		if (fwd_pending)
		begin
			ld_wb_valid = ~fwd_squashed;
			ld_wb_rob_idx = fwd_rob;
			ld_wb_pd = fwd_pd;
			ld_wb_writes = fwd_writes;
			ld_wb_data = fwd_val;
			ld_wb_addr = fwd_addr;
		end
		else
		begin
			ld_wb_valid = acc_valid && !acc_is_store && dc_out.valid
				&& !acc_killed && !ld_squashed;
			ld_wb_rob_idx = acc_rob;
			ld_wb_pd = acc_pd;
			ld_wb_writes = acc_writes;
			ld_wb_data = dc_out.data;
			ld_wb_addr = acc_addr;
		end
	end

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Allocation
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	logic [LSQ_IDX_W : 0] alloc_n;

	always_comb
	begin
		alloc_n = '0;
		for (int k = 0; k < FE_WIDTH; k++)
		begin
			disp_lsq_idx[k] = lsq_idx_t'(lsq_tail + alloc_n[LSQ_IDX_W - 1 : 0]);
			if (disp_uop[k].valid && disp_uop[k].is_mem)
				alloc_n = alloc_n + 1'b1;
		end
		lsq_free = (LSQ_ENTRIES - 1) - lsq_count;
	end

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| State update
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	logic [LSQ_IDX_W : 0] dealloc_n;
	logic [LSQ_IDX_W : 0] survivors;

	always_ff @(posedge clk)
	begin
		if (~rst_n)
		begin
			for (int i = 0; i < LSQ_ENTRIES; i++)
			begin
				e[i].valid <= 1'b0;
				e[i].addr_valid <= 1'b0;
			end
			lsq_head <= '0;
			lsq_tail <= '0;
			lsq_count <= '0;
			acc_valid <= 1'b0;
			acc_is_store <= 1'b0;
			acc_killed <= 1'b0;
			fwd_pending <= 1'b0;
		end
		else
		begin
			// The D cache port, advanced by one access.
			acc_valid <= nxt_valid;
			acc_is_store <= nxt_is_store;
			acc_addr <= nxt_addr;
			acc_data <= nxt_data;
			acc_rob <= nxt_rob;
			acc_pd <= nxt_pd;
			acc_writes <= nxt_writes;
			acc_killed <= nxt_killed;
			// Driven from exactly one place, so that the squash handling below
			// cannot silently override a forward being set this cycle.
			fwd_pending <= mem_issue && (mem_uop.mem_action == READ) && fwd_hit;

			// ---- issue: record the address, and the data for a store ----
			if (mem_issue)
			begin
				e[mem_uop.lsq_idx].addr <= mem_addr;
				e[mem_uop.lsq_idx].addr_valid <= 1'b1;
				if (mem_uop.mem_action == WRITE)
					e[mem_uop.lsq_idx].data <= mem_data;

				// A load that misses the forwarding path is picked up by the
				// port logic above, which owns acc_* outright so that a squash
				// arriving on the same edge cannot race it.
				if ((mem_uop.mem_action == READ) && fwd_hit)
				begin
					fwd_rob <= mem_uop.rob_idx;
					fwd_pd <= mem_uop.pd;
					fwd_writes <= mem_uop.uses_rw;
					fwd_val <= fwd_data;
					fwd_addr <= mem_addr;
				`ifdef SIMULATION
					stats_event("store_forward");
				`endif
				end
			end

			// ---- allocation ----
			for (int k = 0; k < FE_WIDTH; k++)
			begin
				if (disp_uop[k].valid && disp_uop[k].is_mem)
				begin
					e[disp_lsq_idx[k]].valid <= 1'b1;
					e[disp_lsq_idx[k]].is_store <= (disp_uop[k].mem_action == WRITE);
					e[disp_lsq_idx[k]].rob_idx <= disp_uop[k].rob_idx;
					e[disp_lsq_idx[k]].addr_valid <= 1'b0;
				end
			end

			// ---- deallocation on commit ----
			dealloc_n = '0;
			for (int k = 0; k < FE_WIDTH; k++)
			begin
				if (commit_en[k] && commit_is_mem[k])
				begin
					e[lsq_idx_t'(lsq_head + dealloc_n[LSQ_IDX_W - 1 : 0])].valid <= 1'b0;
					e[lsq_idx_t'(lsq_head + dealloc_n[LSQ_IDX_W - 1 : 0])].addr_valid <= 1'b0;
					dealloc_n = dealloc_n + 1'b1;
				end
			end

			lsq_head <= lsq_idx_t'(lsq_head + dealloc_n[LSQ_IDX_W - 1 : 0]);
			lsq_tail <= lsq_idx_t'(lsq_tail + alloc_n[LSQ_IDX_W - 1 : 0]);
			lsq_count <= lsq_count - dealloc_n + alloc_n;

			// ---- squash ----
			if (squash)
			begin
				survivors = '0;
				for (int i = 0; i < LSQ_ENTRIES; i++)
				begin
					if (e[i].valid)
					begin
						if ({1'b0, rob_idx_t'(e[i].rob_idx - squash_head)} >= squash_count)
						begin
							e[i].valid <= 1'b0;
							e[i].addr_valid <= 1'b0;
						end
						else
							survivors = survivors + 1'b1;
					end
				end

				// A load already talking to the cache may now be wrong path.
				// That is handled where acc_* is computed, which carries the
				// kill into nxt_killed rather than writing acc_killed from two
				// places on the same edge.

				lsq_count <= survivors - dealloc_n;
				lsq_tail <= lsq_idx_t'(lsq_head + dealloc_n[LSQ_IDX_W - 1 : 0]
					+ (survivors[LSQ_IDX_W - 1 : 0] - dealloc_n[LSQ_IDX_W - 1 : 0]));
			end
		end
	end

endmodule
