/*
 * frontend.sv
 *
 * The in-order front end: fetch, a decoupling fetch buffer, decode, branch
 * prediction, and the control logic that decides how many instructions to hand
 * to rename each cycle.
 *
 * The fetch buffer is what makes a wide front end tractable. Fetch pushes
 * whatever the instruction cache returns for the current line, and decode pops
 * from the other end, so the two do not have to agree on a count in the same
 * cycle and a cache miss does not immediately starve rename.
 *
 * Delay slots drive most of the rules here. MIPS runs the instruction after a
 * branch or jump whichever way the branch goes, so a redirect must not take
 * effect until that instruction has been accepted:
 *   - if the delay slot is already in this decode group, accept both and
 *     redirect immediately,
 *   - otherwise accept up to the branch, remember the target, and redirect
 *     after the next cycle accepts the delay slot.
 * A group is also cut after the first conditional branch, so there is only ever
 * one prediction to make per cycle.
 */
`include "mips_core.svh"

module frontend (
	input clk,    // Clock
	input rst_n,  // Synchronous reset active low

	// ---- instruction supply ----
	output logic [`ADDR_WIDTH - 1 : 0] o_pc_current,
	output logic [`ADDR_WIDTH - 1 : 0] o_pc_next,
	input  logic i_inst_valid,
	input  logic [FE_WIDTH - 1 : 0] i_word_valid,
	input  logic [`DATA_WIDTH - 1 : 0] i_inst_data [FE_WIDTH],

	// ---- to rename ----
	output dec_uop_t fe_uop [FE_WIDTH],
	input  logic fe_stall,

	// ---- redirect from execute ----
	input  logic ex_redirect_valid,
	input  logic [`ADDR_WIDTH - 1 : 0] ex_redirect_pc,

	// ---- branch predictor ----
	output logic bp_req_valid,
	output logic [`ADDR_WIDTH - 1 : 0] bp_req_pc,
	input  mips_core_pkg::BranchOutcome bp_prediction,
	input  logic [BP_IDX_W - 1 : 0] bp_index,
	input  logic [BP_HISTORY - 1 : 0] bp_hist,
	input  logic bp_weak,
	input  mips_core_pkg::BranchOutcome bp_perc,
	input  mips_core_pkg::BranchOutcome bp_gshare
);

`ifdef SIMULATION
	import "DPI-C" function void stats_event (input string e);
`endif

	localparam int FB_DEPTH = 8;
	localparam int FB_IDX_W = 3;

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Fetch buffer
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	logic [`ADDR_WIDTH - 1 : 0] fb_pc [FB_DEPTH];
	logic [`DATA_WIDTH - 1 : 0] fb_inst [FB_DEPTH];
	logic [FB_IDX_W - 1 : 0] fb_head, fb_tail;
	logic [FB_IDX_W : 0] fb_count;

	logic [`ADDR_WIDTH - 1 : 0] pc_reg;
	logic [2:0] push_n;
	logic [2:0] pop_n;
	logic fb_flush;

	assign o_pc_current = pc_reg;

	// How many words the cache can give us for this line, limited by room in
	// the buffer.
	always_comb
	begin
		push_n = '0;
		if (i_inst_valid && !fb_flush)
		begin
			for (int j = 0; j < FE_WIDTH; j++)
			begin
				// Words must be contiguous: stop at the first one that falls
				// outside the cache line.
				if (i_word_valid[j] && (3'({1'b0, push_n}) == 3'(j))
					&& ({1'b0, fb_count} + {1'b0, push_n} + 1 <= FB_DEPTH))
					push_n = push_n + 1'b1;
			end
		end
	end

	// A decode redirect only counts once rename has actually taken the branch.
	// Redirecting while rename is stalled would move the pc away from the delay
	// slot that has not been accepted yet.
	logic dec_redirect_go;
	assign dec_redirect_go = dec_redirect && !fe_stall;

	assign o_pc_next = ex_redirect_valid ? ex_redirect_pc
		: (dec_redirect_go ? dec_redirect_pc
			: pc_reg + (`ADDR_WIDTH'(push_n) << 2));

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Decode
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	pc_ifc dec_pc [FE_WIDTH] ();
	cache_output_ifc dec_inst [FE_WIDTH] ();
	decoder_output_ifc dec_out [FE_WIDTH] ();

	// An interface array cannot be indexed by a loop variable, so the decoder
	// outputs are flattened into a plain struct array here, where the index is
	// a genvar, and everything below works on that.
	dec_uop_t dec_raw [FE_WIDTH];
	logic [`ADDR_WIDTH - 1 : 0] slot_pc [FE_WIDTH];
	logic slot_present [FE_WIDTH];

	genvar g;
	generate
		for (g = 0; g < FE_WIDTH; g++)
		begin : decoders
			assign slot_pc[g] = fb_pc[FB_IDX_W'(fb_head + FB_IDX_W'(g))];
			assign slot_present[g] = ({1'b0, FB_IDX_W'(g)} < fb_count);

			assign dec_pc[g].pc = slot_pc[g];
			assign dec_inst[g].valid = slot_present[g];
			assign dec_inst[g].data = fb_inst[FB_IDX_W'(fb_head + FB_IDX_W'(g))];

			decoder DECODER (
				.i_pc   (dec_pc[g]),
				.i_inst (dec_inst[g]),
				.out    (dec_out[g])
			);

			assign dec_raw[g].valid          = dec_out[g].valid;
			assign dec_raw[g].pc             = slot_pc[g];
			assign dec_raw[g].inst_nz        = (|fb_inst[FB_IDX_W'(fb_head + FB_IDX_W'(g))])
			                                   & dec_out[g].valid;
			assign dec_raw[g].alu_ctl        = dec_out[g].alu_ctl;
			assign dec_raw[g].is_branch_jump = dec_out[g].is_branch_jump;
			assign dec_raw[g].is_jump        = dec_out[g].is_jump;
			assign dec_raw[g].is_jump_reg    = dec_out[g].is_jump_reg;
			assign dec_raw[g].branch_target  = dec_out[g].branch_target;
			assign dec_raw[g].is_mem_access  = dec_out[g].is_mem_access;
			assign dec_raw[g].mem_action     = dec_out[g].mem_action;
			assign dec_raw[g].uses_rs        = dec_out[g].uses_rs;
			assign dec_raw[g].rs_addr        = dec_out[g].rs_addr;
			assign dec_raw[g].uses_rt        = dec_out[g].uses_rt;
			assign dec_raw[g].rt_addr        = dec_out[g].rt_addr;
			assign dec_raw[g].uses_immediate = dec_out[g].uses_immediate;
			assign dec_raw[g].immediate      = dec_out[g].immediate;
			assign dec_raw[g].uses_rw        = dec_out[g].uses_rw;
			assign dec_raw[g].rw_addr        = dec_out[g].rw_addr;
			assign dec_raw[g].prediction     = NOT_TAKEN;
			assign dec_raw[g].recovery_target= '0;
			assign dec_raw[g].bp_index       = '0;
			// Every instruction records the history live at its decode so
			// that a jr redirect can restore it too, not only a branch.
			assign dec_raw[g].bp_hist        = bp_hist;
			assign dec_raw[g].bp_weak        = 1'b0;
			assign dec_raw[g].bp_perc        = NOT_TAKEN;
			assign dec_raw[g].bp_gshare      = NOT_TAKEN;
		end
	endgenerate

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Group formation
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// pend_* remembers a redirect whose delay slot had not been fetched yet.
	logic pend_valid;
	logic [`ADDR_WIDTH - 1 : 0] pend_pc;

	logic present [FE_WIDTH];
	logic is_cond [FE_WIDTH];
	logic is_direct_jump [FE_WIDTH];
	logic want_redirect [FE_WIDTH];

	logic dec_redirect;
	logic [`ADDR_WIDTH - 1 : 0] dec_redirect_pc;
	logic set_pend;
	logic [`ADDR_WIDTH - 1 : 0] set_pend_pc;
	logic [2:0] accept_n;

	// Only the first conditional branch in the group gets a prediction, so the
	// single predictor port is enough.
	logic [2:0] cond_slot;
	logic cond_found;

	always_comb
	begin
		cond_found = 1'b0;
		cond_slot = '0;
		for (int k = 0; k < FE_WIDTH; k++)
		begin
			// An unsupported opcode decodes to valid = 0 with nop defaults.
			// It still has to be consumed, or the front end wedges on it.
			present[k] = slot_present[k];
			is_cond[k] = present[k] && dec_raw[k].is_branch_jump && !dec_raw[k].is_jump;
			is_direct_jump[k] = present[k] && dec_raw[k].is_jump && !dec_raw[k].is_jump_reg;
			if (is_cond[k] && !cond_found)
			begin
				cond_found = 1'b1;
				cond_slot = 3'(k);
			end
		end
	end

	assign bp_req_valid = cond_found && (accept_n > cond_slot) && !fe_stall;

	always_comb
	begin
		bp_req_pc = slot_pc[0];
		for (int k = 0; k < FE_WIDTH; k++)
		begin
			if (3'(k) == cond_slot)
				bp_req_pc = slot_pc[k];
		end
	end

	always_comb
	begin
		for (int k = 0; k < FE_WIDTH; k++)
		begin
			// A direct jump always redirects. A conditional branch redirects
			// only when it is predicted taken. A jr redirects from execute,
			// because its target lives in a register.
			want_redirect[k] = is_direct_jump[k]
				|| (is_cond[k] && (3'(k) == cond_slot) && (bp_prediction == TAKEN));
		end
	end

	always_comb
	begin
		automatic logic stop = 1'b0;
		accept_n = '0;
		dec_redirect = 1'b0;
		dec_redirect_pc = '0;
		set_pend = 1'b0;
		set_pend_pc = '0;

		for (int k = 0; k < FE_WIDTH; k++)
		begin
			if (!stop && present[k])
			begin
				accept_n = 3'(k) + 3'd1;

				if (pend_valid && (k == 0))
				begin
					// This is the delay slot of a branch accepted last cycle.
					dec_redirect = 1'b1;
					dec_redirect_pc = pend_pc;
					stop = 1'b1;
				end
				else if (want_redirect[k])
				begin
					if ((k + 1 < FE_WIDTH) && present[k + 1])
					begin
						accept_n = 3'(k) + 3'd2;	// take the delay slot too
						dec_redirect = 1'b1;
						dec_redirect_pc = dec_raw[k].branch_target;
					end
					else
					begin
						set_pend = 1'b1;
						set_pend_pc = dec_raw[k].branch_target;
					end
					stop = 1'b1;
				end
				else if (is_cond[k] || dec_raw[k].is_jump_reg)
				begin
					// Cut the group after a control instruction and its delay
					// slot so that only one prediction is needed per cycle and
					// the delay slot is never separated from its branch by a
					// group boundary that a squash could cut through.
					if ((k + 1 < FE_WIDTH) && present[k + 1])
						accept_n = 3'(k) + 3'd2;
					stop = 1'b1;
				end
			end
			else
				stop = 1'b1;
		end
	end

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Hand off to rename
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	always_comb
	begin
		for (int k = 0; k < FE_WIDTH; k++)
		begin
			fe_uop[k] = dec_raw[k];
			fe_uop[k].valid = ({1'b0, 3'(k)} < {1'b0, accept_n}) && !ex_redirect_valid;

			// Only the branch that was actually predicted carries predictor
			// state; everything else retires without training anything.
			if (is_cond[k] && (3'(k) == cond_slot))
			begin
				fe_uop[k].prediction = bp_prediction;
				fe_uop[k].recovery_target = (bp_prediction == TAKEN)
					? dec_raw[k].pc + `ADDR_WIDTH'd8
					: dec_raw[k].branch_target;
				fe_uop[k].bp_index = bp_index;
				fe_uop[k].bp_hist = bp_hist;
				fe_uop[k].bp_weak = bp_weak;
				fe_uop[k].bp_perc = bp_perc;
				fe_uop[k].bp_gshare = bp_gshare;
			end
		end
	end

	assign pop_n = fe_stall ? 3'd0 : accept_n;
	assign fb_flush = ex_redirect_valid || dec_redirect_go;

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Sequential state
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	always_ff @(posedge clk)
	begin
		if (~rst_n)
		begin
			pc_reg <= '0;
			fb_head <= '0;
			fb_tail <= '0;
			fb_count <= '0;
			pend_valid <= 1'b0;
		end
		else
		begin
			pc_reg <= o_pc_next;

			for (int j = 0; j < FE_WIDTH; j++)
			begin
				if ({1'b0, 3'(j)} < {1'b0, push_n})
				begin
					fb_pc[FB_IDX_W'(fb_tail + FB_IDX_W'(j))]
						<= pc_reg + `ADDR_WIDTH'(j << 2);
					fb_inst[FB_IDX_W'(fb_tail + FB_IDX_W'(j))] <= i_inst_data[j];
				end
			end

			if (fb_flush)
			begin
				// Everything behind a redirect is wrong path.
				fb_head <= '0;
				fb_tail <= '0;
				fb_count <= '0;
			end
			else
			begin
				fb_head <= FB_IDX_W'(fb_head + pop_n[FB_IDX_W - 1 : 0]);
				fb_tail <= FB_IDX_W'(fb_tail + push_n[FB_IDX_W - 1 : 0]);
				fb_count <= fb_count - {1'b0, pop_n} + {1'b0, push_n};
			end

			if (ex_redirect_valid)
				pend_valid <= 1'b0;
			else if (!fe_stall)
			begin
				if (set_pend)
				begin
					pend_valid <= 1'b1;
					pend_pc <= set_pend_pc;
				end
				else if (accept_n != 0)
					pend_valid <= 1'b0;
			end
		end
	end

`ifdef SIMULATION
	always_ff @(posedge clk)
	begin
		if (rst_n)
		begin
			if (!i_inst_valid) stats_event("ic_miss_cycle");
			if (fb_count == 0) stats_event("fetch_starved");
		end
	end
`endif

endmodule
