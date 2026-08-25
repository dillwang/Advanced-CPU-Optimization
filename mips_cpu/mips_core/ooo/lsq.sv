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

	enum logic [1:0] {
		M_IDLE,
		M_LOAD,
		M_STORE
	} state, next_state;

	// The load currently being fetched from the cache.
	rob_idx_t ld_rob;
	preg_t ld_pd;
	logic ld_writes;
	logic [`ADDR_WIDTH - 1 : 0] ld_addr;
	logic ld_killed;

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

	assign start_load = mem_issue && (mem_uop.mem_action == READ) && !fwd_hit
		&& (state == M_IDLE);
	assign start_store = st_valid && (state == M_IDLE) && !start_load;

	assign o_accept = (state == M_IDLE) || (state == M_LOAD && dc_out.valid)
		|| (state == M_STORE && dc_out.valid);
	// A load can only be set up when nothing else is claiming the port, since
	// the cache SRAM has to be addressed a cycle in advance.
	assign o_load_free = (state == M_IDLE) && !st_valid;
	// The D-cache prefetcher borrows the tag array while nothing else needs it.
	// It may only do so when no access is being set up, because a request is
	// presented to the cache one cycle after its address appears on addr_next.
	assign o_pf_allow = (state == M_IDLE) && !st_valid && !start_load && !mem_issue;

	always_comb
	begin
		dc_in.valid = 1'b0;
		dc_in.mem_action = READ;
		dc_in.addr = '0;
		dc_in.data = '0;
		dc_in.addr_next = '0;

		case (state)
			M_LOAD:
			begin
				dc_in.valid = ~ld_killed;
				dc_in.mem_action = READ;
				dc_in.addr = ld_addr;
				dc_in.addr_next = ld_addr;
			end

			M_STORE:
			begin
				dc_in.valid = 1'b1;
				dc_in.mem_action = WRITE;
				dc_in.addr = st_addr;
				dc_in.data = st_data;
				dc_in.addr_next = st_addr;
			end

			default:
			begin
				// Set up the SRAM read for whatever starts next cycle.
				if (start_load)
					dc_in.addr_next = mem_addr;
				else if (st_valid)
					dc_in.addr_next = st_addr;
			end
		endcase
	end

	assign st_done = (state == M_STORE) && dc_out.valid;

	always_comb
	begin
		next_state = state;
		case (state)
			M_IDLE:
				if (start_load)
					next_state = M_LOAD;
				else if (st_valid)
					next_state = M_STORE;
			M_LOAD:
				if (dc_out.valid || ld_killed)
					next_state = M_IDLE;
			M_STORE:
				if (dc_out.valid)
					next_state = M_IDLE;
		endcase
	end

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
		&& ({1'b0, rob_idx_t'(ld_rob - squash_head)} >= squash_count);

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
			ld_wb_valid = (state == M_LOAD) && dc_out.valid && !ld_killed
				&& !ld_squashed;
			ld_wb_rob_idx = ld_rob;
			ld_wb_pd = ld_pd;
			ld_wb_writes = ld_writes;
			ld_wb_data = dc_out.data;
			ld_wb_addr = ld_addr;
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
			state <= M_IDLE;
			fwd_pending <= 1'b0;
			ld_killed <= 1'b0;
		end
		else
		begin
			state <= next_state;
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

				if (mem_uop.mem_action == READ)
				begin
					if (fwd_hit)
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
					else
					begin
						ld_rob <= mem_uop.rob_idx;
						ld_pd <= mem_uop.pd;
						ld_writes <= mem_uop.uses_rw;
						ld_addr <= mem_addr;
						ld_killed <= 1'b0;
					end
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
				// Let the access finish but throw the answer away.
				if ((state == M_LOAD)
					&& ({1'b0, rob_idx_t'(ld_rob - squash_head)} >= squash_count))
					ld_killed <= 1'b1;

				lsq_count <= survivors - dealloc_n;
				lsq_tail <= lsq_idx_t'(lsq_head + dealloc_n[LSQ_IDX_W - 1 : 0]
					+ (survivors[LSQ_IDX_W - 1 : 0] - dealloc_n[LSQ_IDX_W - 1 : 0]));
			end
		end
	end

endmodule
