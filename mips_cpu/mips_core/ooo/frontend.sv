/*
 * frontend.sv
 *
 * The in-order front end: fetch, branch prediction, a decoupling fetch buffer,
 * decode, and the control logic that decides how many instructions to hand to
 * rename each cycle.
 *
 * The fetch buffer is what makes a wide front end tractable. Fetch pushes
 * whatever the instruction cache returns for the current line, and decode pops
 * from the other end, so the two do not have to agree on a count in the same
 * cycle and a cache miss does not immediately starve rename.
 *
 * Fetch is deliberately wider than decode: FETCH_WIDTH words in, FE_WIDTH out.
 * At equal widths the front end delivered a single instruction on half of
 * coin's cycles without ever looking starved, because two things each cost a
 * half-width cycle and neither empties the buffer:
 *
 *   - a fetch pair straddling the end of a cache line. The second word belongs
 *     to a different line and would need a second lookup, so it is simply not
 *     offered. 5.86 M cycles on coin.
 *   - the cycle after a taken branch whose delay slot fell outside the pair.
 *     MIPS has to run that instruction, so fetch spends a cycle collecting it
 *     alone before going to the target. 7.01 M cycles on coin -- almost exactly
 *     one per conditional branch, of which coin has one every five
 *     instructions.
 *
 * Reading a whole line at a time removes the first outright and confines the
 * second to a branch in the last word of the group. Decode still takes two per
 * cycle off the other end; the buffer absorbs the difference.
 *
 * Prediction happens in fetch, not decode. A branch target buffer is probed
 * with the pc being fetched, in parallel with the instruction cache access for
 * that same pc, and answers whether the instruction there is a control
 * instruction and where it goes. If it is, and the direction predictor says
 * taken, the next fetch address is already the target. Nothing on the wrong
 * path is ever fetched, so nothing has to be thrown away: the fetch buffer
 * keeps its contents across a taken branch instead of draining and refilling
 * from empty. Predicting in decode instead costs a flush per taken branch,
 * which on a loop heavy program is very nearly a lost cycle per branch.
 *
 * Decode still checks the front end's work, because the target buffer can miss.
 * Each fetch buffer entry records where fetch went after it, decode computes
 * where it should have gone, and a redirect is raised only when the two differ.
 * A static branch therefore misses once, is filled into the target buffer from
 * decode, and costs nothing from then on. jr and jalr never enter the target
 * buffer at all -- their target comes out of a register and changes from one
 * execution to the next -- so they keep taking their redirect from execute.
 *
 * Delay slots drive most of the remaining rules. MIPS runs the instruction
 * after a branch or jump whichever way the branch goes, so a redirect must not
 * take effect until that instruction has been dealt with. That now applies in
 * both places:
 *   - in fetch, if the delay slot did not come back from the cache in the same
 *     cycle as its branch, the target is held in pend_fe and fetch spends one
 *     more cycle going sequentially to pick the delay slot up,
 *   - in decode, the same idea with pend_valid, for the redirects that fetch
 *     did not already handle.
 * A group is also cut after any control instruction and its delay slot, so
 * there is only ever one prediction in flight per cycle and a squash can never
 * cut between a branch and its delay slot.
 */
`include "mips_core.svh"

module frontend (
	input clk,    // Clock
	input rst_n,  // Synchronous reset active low

	// ---- instruction supply ----
	output logic [`ADDR_WIDTH - 1 : 0] o_pc_current,
	output logic [`ADDR_WIDTH - 1 : 0] o_pc_next,
	input  logic i_inst_valid,
	input  logic [FETCH_WIDTH - 1 : 0] i_word_valid,
	input  logic [`DATA_WIDTH - 1 : 0] i_inst_data [FETCH_WIDTH],

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

	localparam int FB_DEPTH = 16;
	localparam int FB_IDX_W = 4;

	// What fetch decided about one instruction, carried alongside it through
	// the fetch buffer so that decode can check the decision and commit can
	// train the predictor with exactly the state that produced it.
	typedef struct packed {
		logic btb_hit;					// the target buffer knew this pc
		logic [`ADDR_WIDTH - 1 : 0] btb_target;
		logic redir;					// fetch steered to btb_target after it
		logic bp_valid;					// the direction predictor was consulted
		logic bp_taken;
		logic [BP_IDX_W - 1 : 0] bp_index;
		logic [BP_HISTORY - 1 : 0] bp_hist;
		logic bp_weak;
		mips_core_pkg::BranchOutcome bp_perc;
		mips_core_pkg::BranchOutcome bp_gshare;
	} fe_pred_t;

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Fetch buffer
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	logic [`ADDR_WIDTH - 1 : 0] fb_pc [FB_DEPTH];
	logic [`DATA_WIDTH - 1 : 0] fb_inst [FB_DEPTH];
	fe_pred_t fb_pred [FB_DEPTH];
	logic [FB_IDX_W - 1 : 0] fb_head, fb_tail;
	logic [FB_IDX_W : 0] fb_count;

	logic [`ADDR_WIDTH - 1 : 0] pc_reg;
	logic [2:0] push_n;
	logic [2:0] pop_n;
	logic fb_flush;

	assign o_pc_current = pc_reg;

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Branch target buffer lookup
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	logic [`ADDR_WIDTH - 1 : 0] fetch_pc [FETCH_WIDTH];
	logic btb_hit [FETCH_WIDTH];
	logic btb_uncond [FETCH_WIDTH];
	logic [`ADDR_WIDTH - 1 : 0] btb_target [FETCH_WIDTH];

	logic btb_wr_valid;
	logic [`ADDR_WIDTH - 1 : 0] btb_wr_pc;
	logic [`ADDR_WIDTH - 1 : 0] btb_wr_target;
	logic btb_wr_uncond;

	genvar gf;
	generate
		for (gf = 0; gf < FETCH_WIDTH; gf++)
		begin : fetch_addr
			assign fetch_pc[gf] = pc_reg + `ADDR_WIDTH'(gf << 2);
		end
	endgenerate

	btb BTB (
		.clk, .rst_n,
		.i_rd_pc     (fetch_pc),
		.o_hit       (btb_hit),
		.o_uncond    (btb_uncond),
		.o_target    (btb_target),
		.i_wr_valid  (btb_wr_valid),
		.i_wr_pc     (btb_wr_pc),
		.i_wr_target (btb_wr_target),
		.i_wr_uncond (btb_wr_uncond)
	);

	// pend_fe holds a fetch redirect whose delay slot had not come back from
	// the cache yet. While it is set, fetch pushes exactly the delay slot and
	// then takes the redirect.
	logic pend_fe_valid;
	logic [`ADDR_WIDTH - 1 : 0] pend_fe_pc;

	// The first fetched word this cycle that the target buffer recognises. Only
	// one is acted on: the word after it is that branch's delay slot, and a
	// branch inside a delay slot is not something MIPS defines.
	logic hit_found;
	logic [2:0] hit_slot;

	always_comb
	begin
		hit_found = 1'b0;
		hit_slot = '0;
		if (!pend_fe_valid)
		begin
			for (int j = FETCH_WIDTH - 1; j >= 0; j--)
			begin
				if (btb_hit[j])
				begin
					hit_found = 1'b1;
					hit_slot = 3'(j);
				end
			end
		end
	end

	// Fetch never runs past the delay slot of a recognised branch, so an
	// unpredicted branch can never slip into the buffer behind a predicted one
	// and only one prediction is ever in flight per cycle. At FETCH_WIDTH = 4
	// this does bind: a branch recognised in the first word stops the push at
	// two. That is still a full decode group, which is the point of fetching
	// wider than decode -- the cost lands on fetch, where there is slack, and
	// not on the buffer, which keeps handing decode two per cycle.
	logic [2:0] push_limit;
	always_comb
	begin
		if (pend_fe_valid)
			push_limit = 3'd1;
		else if (hit_found)
			push_limit = hit_slot + 3'd2;
		else
			push_limit = 3'(FETCH_WIDTH);
	end

	// How many words the cache can give us for this line, limited by room in
	// the buffer and by the branch limit above.
	always_comb
	begin
		push_n = '0;
		if (i_inst_valid && !fb_flush)
		begin
			for (int j = 0; j < FETCH_WIDTH; j++)
			begin
				// Words must be contiguous: stop at the first one that falls
				// outside the cache line.
				if (i_word_valid[j] && (3'({1'b0, push_n}) == 3'(j))
					&& ({1'b0, fb_count} + {1'b0, push_n} + 1 <= FB_DEPTH)
					&& (push_n < push_limit))
					push_n = push_n + 1'b1;
			end
		end
	end

	// The direction predictor is consulted for a recognised conditional branch
	// that is actually entering the buffer this cycle. That is exactly once per
	// fetched branch, which is what keeps the speculative global history in
	// step with the instruction stream.
	// The recognised entry, muxed out of the per-slot lookup results. An
	// unpacked array cannot be indexed by a wide value, so this is a scan.
	logic hit_uncond;
	logic [`ADDR_WIDTH - 1 : 0] hit_target;
	logic [`ADDR_WIDTH - 1 : 0] hit_pc;

	always_comb
	begin
		hit_uncond = 1'b0;
		hit_target = '0;
		hit_pc = fetch_pc[0];
		for (int j = 0; j < FETCH_WIDTH; j++)
		begin
			if (3'(j) == hit_slot)
			begin
				hit_uncond = btb_uncond[j];
				hit_target = btb_target[j];
				hit_pc = fetch_pc[j];
			end
		end
	end

	logic branch_pushed;
	assign branch_pushed = hit_found && (push_n > hit_slot);
	assign bp_req_valid = branch_pushed && !hit_uncond;
	assign bp_req_pc = hit_pc;

	logic fe_taken;
	assign fe_taken = branch_pushed && (hit_uncond || (bp_prediction == TAKEN));

	// Did the delay slot make it into the buffer in the same cycle?
	logic slot_pushed;
	assign slot_pushed = (push_n > (hit_slot + 3'd1));

	logic set_pend_fe;
	assign set_pend_fe = fe_taken && !slot_pushed;

	logic [`ADDR_WIDTH - 1 : 0] fetch_next_pc;

	always_comb
	begin
		if (pend_fe_valid && (push_n != 0))
			fetch_next_pc = pend_fe_pc;			// delay slot taken, now go
		else if (fe_taken && slot_pushed)
			fetch_next_pc = hit_target;
		else
			fetch_next_pc = pc_reg + (`ADDR_WIDTH'(push_n) << 2);
	end

	// A decode redirect only counts once rename has actually taken the branch.
	// Redirecting while rename is stalled would move the pc away from the delay
	// slot that has not been accepted yet.
	logic dec_redirect;
	logic [`ADDR_WIDTH - 1 : 0] dec_redirect_pc;
	logic dec_redirect_go;
	assign dec_redirect_go = dec_redirect && !fe_stall;

	assign o_pc_next = ex_redirect_valid ? ex_redirect_pc
		: (dec_redirect_go ? dec_redirect_pc : fetch_next_pc);

	// What gets written into each buffer slot filled this cycle. Only the
	// recognised branch carries a prediction; every entry records the live
	// history, so that a jr redirect can restore it too and not only a branch.
	fe_pred_t push_pred [FETCH_WIDTH];
	always_comb
	begin
		for (int j = 0; j < FETCH_WIDTH; j++)
		begin
			push_pred[j] = '0;
			push_pred[j].bp_perc = NOT_TAKEN;
			push_pred[j].bp_gshare = NOT_TAKEN;
			push_pred[j].bp_hist = bp_hist;

			if (hit_found && (3'(j) == hit_slot))
			begin
				push_pred[j].btb_hit = 1'b1;
				push_pred[j].btb_target = hit_target;
				push_pred[j].redir = fe_taken;
				push_pred[j].bp_valid = bp_req_valid;
				push_pred[j].bp_taken = (bp_prediction == TAKEN);
				push_pred[j].bp_index = bp_index;
				push_pred[j].bp_weak = bp_weak;
				push_pred[j].bp_perc = bp_perc;
				push_pred[j].bp_gshare = bp_gshare;
			end
		end
	end

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
	fe_pred_t slot_pred [FE_WIDTH];

	// Where fetch actually went after this instruction and its delay slot,
	// against where decode now says it should have gone.
	logic [`ADDR_WIDTH - 1 : 0] fetch_tgt [FE_WIDTH];
	logic [`ADDR_WIDTH - 1 : 0] want_tgt [FE_WIDTH];

	genvar g;
	generate
		for (g = 0; g < FE_WIDTH; g++)
		begin : decoders
			assign slot_pc[g] = fb_pc[FB_IDX_W'(fb_head + FB_IDX_W'(g))];
			assign slot_present[g] = ({1'b0, FB_IDX_W'(g)} < fb_count);
			assign slot_pred[g] = fb_pred[FB_IDX_W'(fb_head + FB_IDX_W'(g))];

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

			// The prediction was made in fetch and travelled here with the
			// instruction. A target buffer miss reads as not taken, which is
			// what fetch did, and execute is then what corrects it.
			assign dec_raw[g].prediction     = (slot_pred[g].bp_valid
			                                    & slot_pred[g].bp_taken)
			                                   ? TAKEN : NOT_TAKEN;
			assign dec_raw[g].recovery_target= (slot_pred[g].bp_valid
			                                    & slot_pred[g].bp_taken)
			                                   ? (slot_pc[g] + `ADDR_WIDTH'd8)
			                                   : dec_out[g].branch_target;
			assign dec_raw[g].bp_valid       = slot_pred[g].bp_valid;
			assign dec_raw[g].bp_index       = slot_pred[g].bp_index;
			assign dec_raw[g].bp_hist        = slot_pred[g].bp_hist;
			assign dec_raw[g].bp_weak        = slot_pred[g].bp_weak;
			assign dec_raw[g].bp_perc        = slot_pred[g].bp_perc;
			assign dec_raw[g].bp_gshare      = slot_pred[g].bp_gshare;

			// Fetch either steered to the target buffer's answer, or ran on
			// sequentially -- which for a control instruction means past its
			// delay slot, to pc + 8.
			assign fetch_tgt[g] = slot_pred[g].redir
				? slot_pred[g].btb_target
				: (slot_pc[g] + `ADDR_WIDTH'd8);
		end
	endgenerate

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Group formation
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// pend_* remembers a decode redirect whose delay slot had not been fetched.
	logic pend_valid;
	logic [`ADDR_WIDTH - 1 : 0] pend_pc;

	logic present [FE_WIDTH];
	logic is_ctrl [FE_WIDTH];
	logic is_cond [FE_WIDTH];
	logic is_direct_jump [FE_WIDTH];
	logic want_redirect [FE_WIDTH];
	logic want_btb_fill [FE_WIDTH];

	logic set_pend;
	logic [`ADDR_WIDTH - 1 : 0] set_pend_pc;
	logic [2:0] accept_n;

	always_comb
	begin
		for (int k = 0; k < FE_WIDTH; k++)
		begin
			// An unsupported opcode decodes to valid = 0 with nop defaults.
			// It still has to be consumed, or the front end wedges on it.
			present[k] = slot_present[k];
			is_ctrl[k] = present[k] && dec_raw[k].is_branch_jump;
			is_cond[k] = is_ctrl[k] && !dec_raw[k].is_jump;
			is_direct_jump[k] = is_ctrl[k] && dec_raw[k].is_jump
				&& !dec_raw[k].is_jump_reg;

			// A direct jump always goes to its target. A conditional branch
			// goes there when the prediction fetch made says taken. A jr is
			// resolved in execute, so the front end runs on sequentially.
			want_tgt[k] = (is_direct_jump[k]
				|| (is_cond[k] && (dec_raw[k].prediction == TAKEN)))
				? dec_raw[k].branch_target
				: (slot_pc[k] + `ADDR_WIDTH'd8);

			// The only reason left to redirect from decode is that fetch got
			// it wrong, which now means the target buffer missed or held a
			// stale target.
			want_redirect[k] = is_ctrl[k] && (fetch_tgt[k] != want_tgt[k]);

			// Fill the target buffer for anything with a fixed target that it
			// does not already hold correctly. This is what makes the miss
			// above happen only once per static branch.
			want_btb_fill[k] = is_ctrl[k] && !dec_raw[k].is_jump_reg
				&& (!slot_pred[k].btb_hit
					|| (slot_pred[k].btb_target != dec_raw[k].branch_target));
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
				else if (is_ctrl[k])
				begin
					// Cut the group after a control instruction and its delay
					// slot, so that only one prediction is in flight per cycle
					// and the delay slot is never separated from its branch by
					// a group boundary that a squash could cut through.
					if ((k + 1 < FE_WIDTH) && present[k + 1])
						accept_n = 3'(k) + 3'd2;

					if (want_redirect[k])
					begin
						if (accept_n == 3'(k) + 3'd2)
						begin
							dec_redirect = 1'b1;
							dec_redirect_pc = want_tgt[k];
						end
						else
						begin
							set_pend = 1'b1;
							set_pend_pc = want_tgt[k];
						end
					end
					stop = 1'b1;
				end
			end
			else
				stop = 1'b1;
		end
	end

	// One target buffer fill per cycle, taken from the oldest control
	// instruction in the accepted group that needs one.
	always_comb
	begin
		btb_wr_valid = 1'b0;
		btb_wr_pc = '0;
		btb_wr_target = '0;
		btb_wr_uncond = 1'b0;

		for (int k = FE_WIDTH - 1; k >= 0; k--)
		begin
			if (want_btb_fill[k] && ({1'b0, 3'(k)} < {1'b0, accept_n}) && !fe_stall)
			begin
				btb_wr_valid = 1'b1;
				btb_wr_pc = slot_pc[k];
				btb_wr_target = dec_raw[k].branch_target;
				btb_wr_uncond = dec_raw[k].is_jump;
			end
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

			// Only a conditional branch carries predictor state; nothing else
			// trains anything, whatever it happened to be fetched alongside.
			if (!is_cond[k])
				fe_uop[k].bp_valid = 1'b0;
		end
	end

`ifdef SIMULATION
	// Why the front end offered rename fewer than FE_WIDTH instructions. The
	// three fetch-side reasons are exclusive and are counted only on cycles the
	// cache actually answered, so they attribute a short push rather than a
	// missing one.
	always_ff @(posedge clk)
	begin
		if (rst_n)
		begin
			if (i_inst_valid && !fb_flush)
			begin
				// The cache could not offer two words: the pair straddles the
				// end of a line, which needs a second lookup.
				if (!i_word_valid[FETCH_WIDTH - 1]) stats_event("fe_line_edge");
				if (push_n == 0) stats_event("fe_push_0");
				if (push_n == 1) stats_event("fe_push_1");
				if (push_n == 2) stats_event("fe_push_2");
				if (push_n == 3) stats_event("fe_push_3");
				if (push_n == 4) stats_event("fe_push_4");
				// ...and of the short pushes, which constraint bound.
				if ((push_n < 3'(FETCH_WIDTH)) && !i_word_valid[FETCH_WIDTH - 1])
					stats_event("fe_push1_line");
				else if ((push_n == 1) && pend_fe_valid)
					stats_event("fe_push1_pend");
				else if ((push_n == 1) && (push_n == push_limit))
					stats_event("fe_push1_btb");
				else if (push_n == 1)
					stats_event("fe_push1_room");
			end
			// What decode found waiting for it.
			if (!slot_present[0]) stats_event("fb_none");
			else if (!slot_present[FE_WIDTH - 1]) stats_event("fb_only1");
			else stats_event("fb_full");
			// And what it handed on.
			if (accept_n == 1) stats_event("fe_accept_1");
			if (accept_n == 2) stats_event("fe_accept_2");
		end
	end
`endif

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
			pend_fe_valid <= 1'b0;
		end
		else
		begin
			pc_reg <= o_pc_next;

			for (int j = 0; j < FETCH_WIDTH; j++)
			begin
				if ({1'b0, 3'(j)} < {1'b0, push_n})
				begin
					fb_pc[FB_IDX_W'(fb_tail + FB_IDX_W'(j))]
						<= pc_reg + `ADDR_WIDTH'(j << 2);
					fb_inst[FB_IDX_W'(fb_tail + FB_IDX_W'(j))] <= i_inst_data[j];
					fb_pred[FB_IDX_W'(fb_tail + FB_IDX_W'(j))] <= push_pred[j];
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
				fb_head <= FB_IDX_W'(fb_head + FB_IDX_W'(pop_n));
				fb_tail <= FB_IDX_W'(fb_tail + FB_IDX_W'(push_n));
				fb_count <= fb_count - {1'b0, pop_n} + {1'b0, push_n};
			end

			// ---- fetch side delay slot pending ----
			if (fb_flush)
				pend_fe_valid <= 1'b0;
			else if (set_pend_fe)
			begin
				pend_fe_valid <= 1'b1;
				pend_fe_pc <= hit_target;
			end
			else if (pend_fe_valid && (push_n != 0))
				pend_fe_valid <= 1'b0;

			// ---- decode side delay slot pending ----
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
			if (dec_redirect_go) stats_event("btb_redirect");
		end
	end
`endif

endmodule
