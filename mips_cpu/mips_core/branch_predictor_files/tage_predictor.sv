/*
 * tage_predictor.sv
 *
 * A TAGE predictor (Seznec and Michaud, JILP 2006) with the same interface as
 * the tournament predictor it replaces, so the two can be swapped and compared
 * without touching anything else.
 *
 * The idea is a base bimodal predictor plus several tagged tables indexed with
 * geometrically increasing amounts of global history. A branch is looked up in
 * every table at once; the one with the longest history whose tag matches
 * provides the prediction. A branch that only needs a little context is caught
 * by a short table, one that needs a lot is caught by a long one, and a branch
 * that needs none at all falls through to the base predictor. That is the whole
 * point of it over a perceptron: the perceptron dots against a fixed history
 * length for every branch, so the length has to be a compromise, while TAGE
 * lets each branch pick its own.
 *
 * Fitting it to this machine:
 *
 *   - Prediction and training are separated by an arbitrary number of cycles,
 *     so this module is handed back the pc and the history that produced the
 *     prediction. Every index and tag here is a pure function of exactly those
 *     two, so training recomputes them rather than carrying them through the
 *     reorder buffer. TAGE therefore needs no extra state in the pipeline
 *     structs at all, which is what makes it a drop-in.
 *   - The provider and the alternate are recomputed at commit as well. They can
 *     differ from what predict saw, because other branches trained in between,
 *     but the entry being updated is then the one that is actually live, which
 *     is what wants updating.
 *   - o_req_perc reports the final prediction and o_req_gshare the base
 *     predictor's, so the existing per-component accuracy counters keep working
 *     and read as "TAGE" against "bimodal alone".
 *
 * The history is BP_HISTORY bits, which bounds the longest table. Real TAGE
 * designs run to hundreds of bits; this one is geometric inside what the
 * reorder buffer already carries, so the comparison against the tournament
 * predictor is at equal carried state rather than equal table budget.
 */
`include "mips_core.svh"

module tage_predictor (
	input clk,    // Clock
	input rst_n,  // Synchronous reset active low

	// ---- prediction, made in fetch ----
	input  logic i_req_valid,
	input  logic [`ADDR_WIDTH - 1 : 0] i_req_pc,
	// Only the path history predictor uses these; a direction history needs
	// neither the target nor the corrected pc in order to recover.
	input  logic [`ADDR_WIDTH - 1 : 0] i_req_target,
	output mips_core_pkg::BranchOutcome o_req_prediction,
	output logic [BP_IDX_W - 1 : 0] o_req_index,
	output logic [BP_SEQ_W - 1 : 0] o_req_seq,
	output logic o_req_weak,
	output mips_core_pkg::BranchOutcome o_req_perc,
	output mips_core_pkg::BranchOutcome o_req_gshare,

	// ---- training, at commit, in program order ----
	input  logic i_fb_valid,
	input  logic [`ADDR_WIDTH - 1 : 0] i_fb_pc,
	input  logic [BP_IDX_W - 1 : 0] i_fb_index,
	input  logic [BP_SEQ_W - 1 : 0] i_fb_seq,
	input  logic i_fb_weak,
	input  mips_core_pkg::BranchOutcome i_fb_perc,
	input  mips_core_pkg::BranchOutcome i_fb_gshare,
	input  mips_core_pkg::BranchOutcome i_fb_outcome,

	// ---- speculative history repair on a misprediction ----
	input  logic i_rec_valid,
	input  logic [BP_SEQ_W - 1 : 0] i_rec_seq,
	input  logic [`ADDR_WIDTH - 1 : 0] i_rec_pc,
	input  logic [`ADDR_WIDTH - 1 : 0] i_rec_target,
	input  logic i_rec_shift,
	input  mips_core_pkg::BranchOutcome i_rec_outcome
);

`ifdef SIMULATION
	import "DPI-C" function void stats_event (input string e);
`endif

	localparam int NT     = TAGE_TABLES;
	localparam int TIDX_W = TAGE_IDX_W;
	localparam int TENT   = 1 << TIDX_W;
	localparam int TAG_W  = TAGE_TAG_W;
	localparam int CTR_W  = 3;			// signed-ish 3 bit counter, 4 is weakly taken
	localparam int U_W    = 2;
	localparam int CTR_MAX = (1 << CTR_W) - 1;
	// How often the usefulness bits are aged. Without this a table that was
	// useful during one phase of the program keeps its entries forever and
	// nothing can allocate over them.
	localparam int U_RESET_W = 14;

	// Geometric history lengths, the shortest table catching branches that need
	// a little context and the longest those that need a lot. Spaced by a
	// constant ratio from HMIN up to BP_HISTORY, which for five tables over 160
	// bits is 5, 12, 28, 67, 160.
	localparam int HMIN = 5;

	function automatic int unsigned hlen (input int unsigned t);
		case (t)
			0: return HMIN;
			1: return 8;
			2: return 13;
			3: return 20;
			4: return 31;
			5: return 50;
			6: return 79;
			default: return BP_HISTORY;
		endcase
	endfunction

	// The live history plus every bit that has fallen out of it recently, so a
	// branch carries only the sequence number of its prediction. This is what
	// makes a 160 bit history affordable: one register of BP_HISTORY + BP_ROLL
	// bits and BP_SEQ_W bits per reorder buffer entry, against a full copy per
	// entry that would be BP_HISTORY * ROB_ENTRIES and grow with both.
	localparam int HW = BP_HISTORY + BP_ROLL;

	logic [HW - 1 : 0] hist_long;
	logic [BP_SEQ_W - 1 : 0] pred_seq;

	function automatic logic [HW - 1 : 0] roll_back (
		input logic [HW - 1 : 0] h,
		input logic [BP_SEQ_W - 1 : 0] now,
		input logic [BP_SEQ_W - 1 : 0] was);
		return h >> (now - was);
	endfunction

	logic [BP_HISTORY - 1 : 0] ghr;
	logic [BP_HISTORY - 1 : 0] fb_hist;

	assign ghr = hist_long[BP_HISTORY - 1 : 0];
	// Training reconstructs the history the branch predicted with, so every
	// index and tag below is recomputed from exactly the state that made the
	// prediction.
	assign fb_hist = BP_HISTORY'(roll_back(hist_long, pred_seq, i_fb_seq));

	logic [1:0] base_ctr [BP_TABLES];
	logic [CTR_W - 1 : 0] tg_ctr [NT][TENT];
	logic [TAG_W - 1 : 0] tg_tag [NT][TENT];
	logic [U_W - 1 : 0]   tg_u   [NT][TENT];

	logic [U_RESET_W - 1 : 0] u_timer;
	// Cheap pseudo-randomness for picking which of several free tables to
	// allocate in. Always taking the first biases every branch into the same
	// table and wastes the longer ones.
	logic [7:0] lfsr;

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Index and tag generation
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// The history is folded down onto the index and the tag separately, so that
	// two branches sharing an index are unlikely to share a tag as well.
	function automatic logic [TIDX_W - 1 : 0] tg_index (
		input logic [`ADDR_WIDTH - 1 : 0] pc,
		input logic [BP_HISTORY - 1 : 0] h,
		input int unsigned len);
		logic [TIDX_W - 1 : 0] f;
		f = '0;
		for (int i = 0; i < BP_HISTORY; i++)
			if (i < int'(len))
				f[i % TIDX_W] = f[i % TIDX_W] ^ h[i];
		return TIDX_W'(pc[TIDX_W + 1 : 2]) ^ f;
	endfunction

	function automatic logic [TAG_W - 1 : 0] tg_tagof (
		input logic [`ADDR_WIDTH - 1 : 0] pc,
		input logic [BP_HISTORY - 1 : 0] h,
		input int unsigned len);
		logic [TAG_W - 1 : 0] f;
		f = '0;
		for (int i = 0; i < BP_HISTORY; i++)
			if (i < int'(len))
				f[i % TAG_W] = f[(i + 1) % TAG_W] ^ h[i];
		return TAG_W'(pc[TAG_W + 1 : 2]) ^ TAG_W'(pc[`ADDR_WIDTH - 1 : TAG_W + 2]) ^ f;
	endfunction

	function automatic logic [BP_IDX_W - 1 : 0] base_index (
		input logic [`ADDR_WIDTH - 1 : 0] pc);
		return pc[BP_IDX_W + 1 : 2];
	endfunction

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Lookup
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// Used for both the prediction and, with the fed back pc and history, for
	// the update. Kept as one task-like block so the two cannot drift apart.
	logic [TIDX_W - 1 : 0] q_idx [NT];
	logic q_hit [NT];
	mips_core_pkg::BranchOutcome q_pred [NT];
	logic q_weak [NT];

	logic [TIDX_W - 1 : 0] f_idx [NT];
	logic f_hit [NT];
	mips_core_pkg::BranchOutcome f_pred [NT];

	always_comb
	begin
		for (int t = 0; t < NT; t++)
		begin
			automatic logic [TAG_W - 1 : 0] want = tg_tagof(i_req_pc, ghr, hlen(t));
			q_idx[t] = tg_index(i_req_pc, ghr, hlen(t));
			q_hit[t] = (tg_tag[t][q_idx[t]] == want);
			q_pred[t] = tg_ctr[t][q_idx[t]][CTR_W - 1] ? TAKEN : NOT_TAKEN;
			// A counter sitting either side of the midpoint has not committed
			// to a direction yet.
			q_weak[t] = (tg_ctr[t][q_idx[t]] == CTR_W'(3))
				|| (tg_ctr[t][q_idx[t]] == CTR_W'(4));
		end

		for (int t = 0; t < NT; t++)
		begin
			automatic logic [TAG_W - 1 : 0] want = tg_tagof(i_fb_pc, fb_hist, hlen(t));
			f_idx[t] = tg_index(i_fb_pc, fb_hist, hlen(t));
			f_hit[t] = (tg_tag[t][f_idx[t]] == want);
			f_pred[t] = tg_ctr[t][f_idx[t]][CTR_W - 1] ? TAKEN : NOT_TAKEN;
		end
	end

	// The longest matching table provides; the next longest is the alternate.
	localparam int TSEL_W = $clog2(TAGE_TABLES);

	logic q_prov_hit, q_alt_hit;
	logic [TSEL_W - 1 : 0] q_prov, q_alt;
	logic f_prov_hit, f_alt_hit;
	logic [TSEL_W - 1 : 0] f_prov, f_alt;

	always_comb
	begin
		q_prov_hit = 1'b0; q_prov = '0; q_alt_hit = 1'b0; q_alt = '0;
		for (int t = 0; t < NT; t++)
		begin
			if (q_hit[t])
			begin
				if (q_prov_hit)
				begin
					q_alt_hit = 1'b1;
					q_alt = q_prov;
				end
				q_prov_hit = 1'b1;
				q_prov = TSEL_W'(t);
			end
		end

		f_prov_hit = 1'b0; f_prov = '0; f_alt_hit = 1'b0; f_alt = '0;
		for (int t = 0; t < NT; t++)
		begin
			if (f_hit[t])
			begin
				if (f_prov_hit)
				begin
					f_alt_hit = 1'b1;
					f_alt = f_prov;
				end
				f_prov_hit = 1'b1;
				f_prov = TSEL_W'(t);
			end
		end
	end

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Prediction
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	mips_core_pkg::BranchOutcome base_pred, q_prov_pred;
	logic q_prov_weak;

	assign base_pred = base_ctr[base_index(i_req_pc)][1] ? TAKEN : NOT_TAKEN;

	// Unpacked arrays cannot be indexed by a wide value, so the provider is
	// muxed out by scanning.
	always_comb
	begin
		q_prov_pred = base_pred;
		q_prov_weak = 1'b0;
		for (int t = 0; t < NT; t++)
		begin
			if (q_prov_hit && (TSEL_W'(t) == q_prov))
			begin
				q_prov_pred = q_pred[t];
				q_prov_weak = q_weak[t];
			end
		end
	end

	// A provider whose counter is still weak has almost certainly just been
	// allocated and has seen this branch once. The alternate has usually been
	// there longer and is the better bet until the new entry has settled --
	// this is the single largest quality knob in TAGE after allocation itself.
	mips_core_pkg::BranchOutcome q_alt_pred;
	always_comb
	begin
		q_alt_pred = base_pred;
		for (int t = 0; t < NT; t++)
			if (q_alt_hit && (TSEL_W'(t) == q_alt))
				q_alt_pred = q_pred[t];
	end

	assign o_req_prediction = q_prov_hit
		? ((q_prov_weak) ? q_alt_pred : q_prov_pred)
		: base_pred;
	// Reported so the existing per-component counters keep meaning something:
	// the whole predictor against the base predictor on its own.
	assign o_req_perc = o_req_prediction;
	assign o_req_gshare = base_pred;
	assign o_req_index = base_index(i_req_pc);
	assign o_req_seq = pred_seq;
	assign o_req_weak = q_prov_hit ? q_prov_weak : 1'b1;

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Update
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	mips_core_pkg::BranchOutcome f_prov_pred, f_alt_pred;
	logic taken;
	logic prov_right, alt_right;

	assign taken = (i_fb_outcome == TAKEN);

	always_comb
	begin
		f_prov_pred = base_ctr[base_index(i_fb_pc)][1] ? TAKEN : NOT_TAKEN;
		f_alt_pred = base_ctr[base_index(i_fb_pc)][1] ? TAKEN : NOT_TAKEN;
		for (int t = 0; t < NT; t++)
		begin
			if (f_prov_hit && (TSEL_W'(t) == f_prov))
				f_prov_pred = f_pred[t];
			if (f_alt_hit && (TSEL_W'(t) == f_alt))
				f_alt_pred = f_pred[t];
		end
	end

	assign prov_right = (f_prov_pred == i_fb_outcome);
	assign alt_right = (f_alt_pred == i_fb_outcome);

	// A misprediction wants a new entry in a table longer than the provider.
	// Only entries whose usefulness has decayed to zero may be taken.
	logic can_alloc;
	logic [TSEL_W - 1 : 0] alloc_t;

	always_comb
	begin
		automatic int unsigned n_free = 0;
		automatic int unsigned pick = 0;
		can_alloc = 1'b0;
		alloc_t = '0;

		for (int t = 0; t < NT; t++)
			if ((!f_prov_hit || (TSEL_W'(t) > f_prov)) && (tg_u[t][f_idx[t]] == '0))
				n_free = n_free + 1;

		if (n_free != 0)
		begin
			pick = int'(lfsr) % n_free;
			for (int t = 0; t < NT; t++)
			begin
				if ((!f_prov_hit || (TSEL_W'(t) > f_prov)) && (tg_u[t][f_idx[t]] == '0))
				begin
					if (pick == 0)
					begin
						can_alloc = 1'b1;
						alloc_t = TSEL_W'(t);
					end
					pick = pick - 1;
				end
			end
		end
	end

	always_ff @(posedge clk)
	begin
		if (~rst_n)
		begin
			hist_long <= '0;
			pred_seq <= '0;
			u_timer <= '0;
			lfsr <= 8'hA5;
			// Blocking on purpose: these are large tables and nothing else
			// writes them on this edge, which is what keeps the reset loops
			// inside the simulator's unrolling budget.
			for (int i = 0; i < BP_TABLES; i++)
				base_ctr[i] <= 2'b01;
			// One '{default:} per unpacked dimension. Verilator applies the
			// keyword only one level deep, so a flat '{default:'0} on a
			// multidimensional array is rejected; nesting it to the array's own
			// depth is accepted, and unrolls to nothing, which keeps it under
			// yosys-slang's 4000-iteration limit as well.
			tg_ctr <= `FILL2(CTR_W'(4));
			tg_tag <= `FILL2('0);
			tg_u   <= `FILL2('0);
		end
		else
		begin
			lfsr <= {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};

			// ---- speculative history ----
			if (i_req_valid)
			begin
				hist_long <= {hist_long[HW - 2 : 0], (o_req_prediction == TAKEN)};
				pred_seq <= pred_seq + 1'b1;
			end

			// A misprediction puts back the history the offending branch
			// carried. A jr never enters the history, so its recovery restores
			// without shifting.
			if (i_rec_valid)
			begin
				automatic logic [HW - 1 : 0] rolled =
					roll_back(hist_long, pred_seq, i_rec_seq);
				hist_long <= i_rec_shift
					? {rolled[HW - 2 : 0], (i_rec_outcome == TAKEN)}
					: rolled;
				pred_seq <= i_rec_shift ? (i_rec_seq + 1'b1) : i_rec_seq;
			end

			// ---- ageing ----
			// One row across all the tables per cycle, walking the index. A
			// sweep of every entry at once would be a blocking write to an
			// array this block also writes non-blocking below, and the two
			// would silently fight over any entry trained on the same edge.
			// Walking it is both well defined and what hardware would do.
			u_timer <= u_timer + 1'b1;
			if (u_timer[U_RESET_W - 1 : TIDX_W] == '0)
				for (int t = 0; t < NT; t++)
					tg_u[t][u_timer[TIDX_W - 1 : 0]]
						<= {1'b0, tg_u[t][u_timer[TIDX_W - 1 : 0]][U_W - 1 : 1]};

			// ---- training ----
			if (i_fb_valid)
			begin
				// The provider's counter moves toward the outcome. With no
				// provider that is the base predictor.
				if (f_prov_hit)
				begin
					for (int t = 0; t < NT; t++)
					begin
						if (TSEL_W'(t) == f_prov)
						begin
							if (taken)
							begin
								if (tg_ctr[t][f_idx[t]] != CTR_W'(CTR_MAX))
									tg_ctr[t][f_idx[t]] <= tg_ctr[t][f_idx[t]] + CTR_W'(1);
							end
							else
							begin
								if (tg_ctr[t][f_idx[t]] != '0)
									tg_ctr[t][f_idx[t]] <= tg_ctr[t][f_idx[t]] - CTR_W'(1);
							end

							// Usefulness only moves when the provider and the
							// alternate disagreed, because only then did the
							// longer history actually decide anything.
							if (f_prov_pred != f_alt_pred)
							begin
								if (prov_right)
								begin
									if (tg_u[t][f_idx[t]] != U_W'(3))
										tg_u[t][f_idx[t]] <= tg_u[t][f_idx[t]] + U_W'(1);
								end
								else
								begin
									if (tg_u[t][f_idx[t]] != '0)
										tg_u[t][f_idx[t]] <= tg_u[t][f_idx[t]] - U_W'(1);
								end
							end
						end
					end
				end
				else
				begin
					if (taken)
					begin
						if (base_ctr[base_index(i_fb_pc)] != 2'b11)
							base_ctr[base_index(i_fb_pc)] <= base_ctr[base_index(i_fb_pc)] + 2'b01;
					end
					else
					begin
						if (base_ctr[base_index(i_fb_pc)] != 2'b00)
							base_ctr[base_index(i_fb_pc)] <= base_ctr[base_index(i_fb_pc)] - 2'b01;
					end
				end

				// ---- allocation ----
				// A wrong prediction gets a new entry in a longer table. If
				// nothing there has decayed, age the candidates instead so that
				// the next wrong prediction can take one.
				if (!prov_right)
				begin
					if (can_alloc)
					begin
						for (int t = 0; t < NT; t++)
						begin
							if (TSEL_W'(t) == alloc_t)
							begin
								tg_tag[t][f_idx[t]] <= tg_tagof(i_fb_pc, fb_hist, hlen(t));
								// Start weakly on the observed direction.
								tg_ctr[t][f_idx[t]] <= taken ? CTR_W'(4) : CTR_W'(3);
								tg_u[t][f_idx[t]] <= '0;
							end
						end
					end
					else
					begin
						for (int t = 0; t < NT; t++)
							if ((!f_prov_hit || (TSEL_W'(t) > f_prov)) && (tg_u[t][f_idx[t]] != '0))
								tg_u[t][f_idx[t]] <= tg_u[t][f_idx[t]] - U_W'(1);
					end
				end

			`ifdef SIMULATION
				// i_fb_perc is the prediction this predictor actually made for
				// this branch, so this is exact rather than reconstructed.
				if (i_fb_perc == i_fb_outcome) stats_event("bp_correct");
				else stats_event("bp_wrong");
				if (i_fb_gshare == i_fb_outcome) stats_event("bp_base_correct");
				if (f_prov_hit) stats_event("tage_provided");
				else stats_event("tage_base_only");
				if (!prov_right && can_alloc) stats_event("tage_alloc");
				if (!prov_right && !can_alloc) stats_event("tage_alloc_failed");
			`endif
			end
		end
	end

endmodule
