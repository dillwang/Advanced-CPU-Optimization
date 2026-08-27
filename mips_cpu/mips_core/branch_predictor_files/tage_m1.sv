/*
 * tage_m1.sv
 *
 * A TAGE predictor shaped after the Apple Firestorm (M1 P core) conditional
 * branch predictor, as reverse engineered by Yavarzadeh et al, "Whisper: Timing
 * the Transient Execution of Apple Silicon" (arXiv 2411.13900). It exists to be
 * compared against the tournament predictor and against the textbook TAGE in
 * tage_predictor.sv, on the same machine and inside the same budget.
 *
 * Three things are copied from the paper, and they are the things that make it
 * different from a textbook TAGE:
 *
 *   - PATH history, not direction history. A textbook TAGE folds a register of
 *     taken/not-taken bits. Firestorm folds address bits, so the history
 *     records which branches ran and where they went rather than only which way
 *     they fell. Two branches that both fall through are the same event to a
 *     direction history and different events here.
 *
 *   - TWO history registers, updated from different places:
 *         PHRT_new = (PHRT_old << 1) ^ T[31:2]      target address
 *         PHRB_new = (PHRB_old << 1) ^ B[5:2]       branch address
 *     PHRT is long (100 bits) and carries where control went; PHRB is short
 *     (28 bits) and carries which branch it came from. Tables index on both.
 *
 *   - Six tables, four way set associative, with the paper's history lengths:
 *         table   1    2    3    4    5    6
 *         PHRT  100   57   32   18   11    6
 *         PHRB   28   28   28   18   11    6
 *     Associativity matters more here than in a direct mapped TAGE, because a
 *     path history aliases differently: four branches sharing an index can all
 *     keep an entry.
 *
 * What is not copied: the paper enumerates Firestorm's exact index and tag bit
 * groups only partially (things like PHRT[2]^PHRT[43]^PHRT[93]), so the folding
 * here is the standard one, striding by the width being folded onto. The shape
 * is the point, not the particular bit permutation. Firestorm has 44K entries
 * across its tables; this has 24K, to stay inside the budget the tournament
 * predictor sets.
 *
 * Recovery is the one place this design costs more than the others. A direction
 * history is a pure shift, so undoing k branches is a right shift and the
 * predictor needs nothing per branch beyond a sequence number. A path history
 * is (PHR << 1) ^ A, which is only invertible knowing A, so the registers have
 * to be checkpointed. They are checkpointed into one file indexed by the
 * sequence number branches already carry -- 256 entries covering every
 * prediction that can be in flight -- rather than into the reorder buffer.
 */
`include "mips_core.svh"

module tage_m1 (
	input clk,    // Clock
	input rst_n,  // Synchronous reset active low

	// ---- prediction, made in fetch ----
	input  logic i_req_valid,
	input  logic [`ADDR_WIDTH - 1 : 0] i_req_pc,
	// Where fetch is going after this branch. This is the T of the paper's
	// PHRT update and is what makes the history a path rather than a direction.
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

	// ---- recovery ----
	// The corrected pc and target are needed because the path history cannot be
	// rolled forward from a checkpoint without knowing where control actually
	// went.
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

	localparam int NT     = M1_TABLES;			// 6
	localparam int SET_W  = M1_SET_W;			// 1024 sets
	localparam int SETS   = 1 << SET_W;
	localparam int WAYS   = M1_WAYS;			// 4
	localparam int TAG_W  = M1_TAG_W;			// 11
	localparam int CTR_W  = 3;
	localparam int U_W    = 2;
	// The usefulness sweep walks one set per cycle, but only during the first
	// SETS cycles of each 2**U_PERIOD_W. The counter therefore has to be wide
	// enough to address every set AND to divide the period: sizing it to the
	// set index alone leaves the sets above it never aged, and sweeping every
	// cycle decays a useful entry to nothing in a few hundred cycles.
	localparam int U_PERIOD_W = 20;
	localparam int CTR_MAX = (1 << CTR_W) - 1;
	localparam int WSEL_W = $clog2(WAYS);
	localparam int TSEL_W = $clog2(NT);

	localparam int PHRT_W = M1_PHRT_W;			// 100
	localparam int PHRB_W = M1_PHRB_W;			// 28
	localparam int CKPT   = 1 << BP_SEQ_W;		// one per in-flight prediction

	// The paper's per table history lengths.
	function automatic int unsigned tlen (input int unsigned t);
		case (t)
			0: return 100; 1: return 57; 2: return 32;
			3: return 18;  4: return 11; default: return 6;
		endcase
	endfunction
	function automatic int unsigned blen (input int unsigned t);
		case (t)
			0: return 28; 1: return 28; 2: return 28;
			3: return 18; 4: return 11; default: return 6;
		endcase
	endfunction

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Path history
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	logic [PHRT_W - 1 : 0] phrt;
	logic [PHRB_W - 1 : 0] phrb;
	logic [BP_SEQ_W - 1 : 0] pred_seq;

	// Checkpoints, one per prediction in flight, indexed by the sequence number
	// the branch already carries. Written before the update so that recovery
	// can re-apply the real target.
	logic [PHRT_W - 1 : 0] ck_phrt [CKPT];
	logic [PHRB_W - 1 : 0] ck_phrb [CKPT];

	function automatic logic [PHRT_W - 1 : 0] phrt_next (
		input logic [PHRT_W - 1 : 0] h,
		input logic [`ADDR_WIDTH - 1 : 0] target);
		return {h[PHRT_W - 2 : 0], 1'b0} ^ PHRT_W'(target[`ADDR_WIDTH - 1 : 2]);
	endfunction

	function automatic logic [PHRB_W - 1 : 0] phrb_next (
		input logic [PHRB_W - 1 : 0] h,
		input logic [`ADDR_WIDTH - 1 : 0] pc);
		return {h[PHRB_W - 2 : 0], 1'b0} ^ PHRB_W'(pc[5:2]);
	endfunction

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Index and tag
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// Both histories are folded down onto the width being produced, striding by
	// that width, and mixed with several separate pc bits -- the paper notes
	// Apple and Qualcomm use more than one pc bit here where Intel uses one.
	function automatic logic [SET_W - 1 : 0] m1_index (
		input logic [`ADDR_WIDTH - 1 : 0] pc,
		input logic [PHRT_W - 1 : 0] ht,
		input logic [PHRB_W - 1 : 0] hb,
		input int unsigned lt,
		input int unsigned lb);
		logic [SET_W - 1 : 0] ft, fb;
		ft = '0;
		fb = '0;
		for (int i = 0; i < PHRT_W; i++)
			if (i < int'(lt))
				ft[i % SET_W] = ft[i % SET_W] ^ ht[i];
		for (int i = 0; i < PHRB_W; i++)
			if (i < int'(lb))
				fb[i % SET_W] = fb[i % SET_W] ^ hb[i];
		return SET_W'(pc[SET_W + 1 : 2]) ^ ft ^ fb;
	endfunction

	function automatic logic [TAG_W - 1 : 0] m1_tag (
		input logic [`ADDR_WIDTH - 1 : 0] pc,
		input logic [PHRT_W - 1 : 0] ht,
		input logic [PHRB_W - 1 : 0] hb,
		input int unsigned lt,
		input int unsigned lb);
		logic [TAG_W - 1 : 0] ft, fb;
		ft = '0;
		fb = '0;
		// Folded a bit differently from the index so that two branches sharing
		// a set are unlikely to share a tag as well.
		for (int i = 0; i < PHRT_W; i++)
			if (i < int'(lt))
				ft[(i + 1) % TAG_W] = ft[(i + 1) % TAG_W] ^ ht[i];
		for (int i = 0; i < PHRB_W; i++)
			if (i < int'(lb))
				fb[i % TAG_W] = fb[i % TAG_W] ^ hb[i];
		return TAG_W'(pc[TAG_W + 1 : 2]) ^ TAG_W'(pc[`ADDR_WIDTH - 1 : TAG_W + 2])
			^ ft ^ fb;
	endfunction

	function automatic logic [BP_IDX_W - 1 : 0] base_index (
		input logic [`ADDR_WIDTH - 1 : 0] pc);
		return pc[BP_IDX_W + 1 : 2];
	endfunction

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Storage
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	logic [1:0] base_ctr [BP_TABLES];
	logic [CTR_W - 1 : 0] tg_ctr [NT][SETS][WAYS];
	logic [TAG_W - 1 : 0] tg_tag [NT][SETS][WAYS];
	logic [U_W - 1 : 0]   tg_u   [NT][SETS][WAYS];
	// Without this an entry that has never been allocated still answers to any
	// branch whose tag folds to zero, and answers with a counter nobody set.
	logic                 tg_val [NT][SETS][WAYS];

	logic [U_PERIOD_W - 1 : 0] u_timer;
	// Whether a freshly allocated provider is worth believing yet. A provider
	// whose counter is still weak has seen this branch about once, and the
	// alternate has usually been there longer -- but that is a tendency, not a
	// rule, and on a program whose branches are simply hard the counters never
	// leave weak, so always preferring the alternate throws away the best
	// matching table on exactly the branches that matter. This counter learns
	// which way it goes instead.
	logic [3:0] use_alt;
	logic [7:0] lfsr;

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Lookup
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// The history a committing branch predicted with comes back out of the
	// checkpoint file, so training uses exactly the state that made the
	// prediction rather than whatever is current.
	logic [PHRT_W - 1 : 0] fb_phrt;
	logic [PHRB_W - 1 : 0] fb_phrb;
	logic [1:0] fb_conf;			// driven below, once the provider is known
	assign fb_phrt = ck_phrt[i_fb_seq];
	assign fb_phrb = ck_phrb[i_fb_seq];

	logic [SET_W - 1 : 0] q_set [NT], f_set [NT];
	logic q_hit [NT], f_hit [NT];
	logic [WSEL_W - 1 : 0] q_way [NT], f_way [NT];
	mips_core_pkg::BranchOutcome q_pred [NT], f_pred [NT];
	logic q_weak [NT];

	always_comb
	begin
		for (int t = 0; t < NT; t++)
		begin
			automatic logic [TAG_W - 1 : 0] want =
				m1_tag(i_req_pc, phrt, phrb, tlen(t), blen(t));
			q_set[t] = m1_index(i_req_pc, phrt, phrb, tlen(t), blen(t));
			q_hit[t] = 1'b0;
			q_way[t] = '0;
			for (int w = 0; w < WAYS; w++)
				if (tg_val[t][q_set[t]][w] && (tg_tag[t][q_set[t]][w] == want))
				begin
					q_hit[t] = 1'b1;
					q_way[t] = WSEL_W'(w);
				end
			q_pred[t] = tg_ctr[t][q_set[t]][q_way[t]][CTR_W - 1] ? TAKEN : NOT_TAKEN;
			q_weak[t] = (tg_ctr[t][q_set[t]][q_way[t]] == CTR_W'(3))
				|| (tg_ctr[t][q_set[t]][q_way[t]] == CTR_W'(4));
		end

		for (int t = 0; t < NT; t++)
		begin
			automatic logic [TAG_W - 1 : 0] want =
				m1_tag(i_fb_pc, fb_phrt, fb_phrb, tlen(t), blen(t));
			f_set[t] = m1_index(i_fb_pc, fb_phrt, fb_phrb, tlen(t), blen(t));
			f_hit[t] = 1'b0;
			f_way[t] = '0;
			for (int w = 0; w < WAYS; w++)
				if (tg_val[t][f_set[t]][w] && (tg_tag[t][f_set[t]][w] == want))
				begin
					f_hit[t] = 1'b1;
					f_way[t] = WSEL_W'(w);
				end
			f_pred[t] = tg_ctr[t][f_set[t]][f_way[t]][CTR_W - 1] ? TAKEN : NOT_TAKEN;
		end
	end

	// The longest matching table provides, the next longest is the alternate.
	logic q_prov_hit, q_alt_hit, f_prov_hit, f_alt_hit;
	logic [TSEL_W - 1 : 0] q_prov, q_alt, f_prov, f_alt;

	always_comb
	begin
		q_prov_hit = 1'b0; q_prov = '0; q_alt_hit = 1'b0; q_alt = '0;
		// Table 0 has the longest history, so scan downwards for the provider.
		for (int t = NT - 1; t >= 0; t--)
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

		f_prov_hit = 1'b0; f_prov = '0; f_alt_hit = 1'b0; f_alt = '0;
		for (int t = NT - 1; t >= 0; t--)
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

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Prediction
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	mips_core_pkg::BranchOutcome base_pred, q_prov_pred, q_alt_pred;
	logic q_prov_weak;

	assign base_pred = base_ctr[base_index(i_req_pc)][1] ? TAKEN : NOT_TAKEN;

	always_comb
	begin
		q_prov_pred = base_pred;
		q_alt_pred = base_pred;
		q_prov_weak = 1'b0;
		for (int t = 0; t < NT; t++)
		begin
			if (q_prov_hit && (TSEL_W'(t) == q_prov))
			begin
				q_prov_pred = q_pred[t];
				q_prov_weak = q_weak[t];
			end
			if (q_alt_hit && (TSEL_W'(t) == q_alt))
				q_alt_pred = q_pred[t];
		end
	end

	// A provider whose counter is still weak has just been allocated and seen
	// this branch once; the alternate has usually been there longer.
	mips_core_pkg::BranchOutcome q_tage;
	logic [1:0] q_conf;
	assign q_tage = q_prov_hit
		? ((q_prov_weak && use_alt[3]) ? q_alt_pred : q_prov_pred)
		: base_pred;
	assign q_conf = !q_prov_hit ? 2'd0 : (q_prov_weak ? 2'd1 : 2'd2);

	// The statistical corrector gets the last word, but only where the sum of
	// its counters is emphatic enough to clear its own adaptive threshold.
	mips_core_pkg::BranchOutcome sc_pred;
	logic sc_use;

	statistical_corrector SC (
		.clk, .rst_n,
		.i_q_valid   (i_req_valid),
		.i_q_pc      (i_req_pc),
		.i_q_phrt    (phrt),
		.i_q_phrb    (phrb),
		.i_q_tage    (q_tage),
		.i_q_conf    (q_conf),
		.i_q_final   (o_req_prediction),
		.i_q_seq     (pred_seq),
		.o_q_pred    (sc_pred),
		.o_q_use     (sc_use),

		.i_fb_valid  (i_fb_valid),
		.i_fb_pc     (i_fb_pc),
		.i_fb_phrt   (fb_phrt),
		.i_fb_phrb   (fb_phrb),
		.i_fb_tage   (i_fb_gshare),
		.i_fb_conf   (fb_conf),
		.i_fb_outcome(i_fb_outcome),
		.i_fb_seq    (i_fb_seq),

		.i_rec_valid (i_rec_valid)
	);

	assign o_req_prediction = sc_use ? sc_pred : q_tage;
	assign o_req_perc = o_req_prediction;
	// Spare feedback channel, repurposed to carry the TAGE's own answer back
	// to commit. Allocation has to be driven by whether the TAGE was wrong,
	// not by whether the corrected prediction was, or the tables stop learning
	// on every branch the corrector rescues.
	assign o_req_gshare = q_tage;
	assign o_req_index = base_index(i_req_pc);
	assign o_req_seq = pred_seq;
	assign o_req_weak = q_prov_hit ? q_prov_weak : 1'b1;

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Update
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	mips_core_pkg::BranchOutcome f_prov_pred, f_alt_pred;
	logic f_prov_weak;
	logic taken, prov_right, alt_right;
	assign taken = (i_fb_outcome == TAKEN);

	always_comb
	begin
		f_prov_pred = base_ctr[base_index(i_fb_pc)][1] ? TAKEN : NOT_TAKEN;
		f_alt_pred = f_prov_pred;
		f_prov_weak = 1'b0;
		for (int t = 0; t < NT; t++)
		begin
			if (f_prov_hit && (TSEL_W'(t) == f_prov))
			begin
				f_prov_pred = f_pred[t];
				f_prov_weak = (tg_ctr[t][f_set[t]][f_way[t]] == CTR_W'(3))
					|| (tg_ctr[t][f_set[t]][f_way[t]] == CTR_W'(4));
			end
			if (f_alt_hit && (TSEL_W'(t) == f_alt))
				f_alt_pred = f_pred[t];
		end
	end

	assign prov_right = (f_prov_pred == i_fb_outcome);
	assign alt_right = (f_alt_pred == i_fb_outcome);
	// What the TAGE alone said, carried back from the prediction, so that the
	// allocation decision matches the prediction that was really made rather
	// than a provider recomputed at commit against tables that have since
	// moved. i_fb_gshare is that channel; i_fb_perc carries the final answer.
	logic pred_right;
	assign pred_right = (i_fb_gshare == i_fb_outcome);

	// Confidence as it was at prediction time, reconstructed for the corrector
	// from the checkpointed lookup.
	assign fb_conf = !f_prov_hit ? 2'd0 : (f_prov_weak ? 2'd1 : 2'd2);

	// Allocation goes into a table with a longer history than the provider,
	// into a way whose usefulness has decayed. Four ways means a set can hold
	// four branches before anything has to be evicted.
	logic can_alloc;
	logic [TSEL_W - 1 : 0] alloc_t;
	logic [WSEL_W - 1 : 0] alloc_w;

	// Per table, whether this set has a way worth taking and which one. An
	// invalid way is preferred over a valid one whose usefulness has decayed,
	// since taking the invalid one costs nothing.
	logic t_free [NT];
	logic [WSEL_W - 1 : 0] t_wsel [NT];

	always_comb
	begin
		for (int t = 0; t < NT; t++)
		begin
			t_free[t] = 1'b0;
			t_wsel[t] = '0;
			for (int w = WAYS - 1; w >= 0; w--)
				if (tg_val[t][f_set[t]][w] && (tg_u[t][f_set[t]][w] == '0))
				begin
					t_free[t] = 1'b1;
					t_wsel[t] = WSEL_W'(w);
				end
			for (int w = WAYS - 1; w >= 0; w--)
				if (!tg_val[t][f_set[t]][w])
				begin
					t_free[t] = 1'b1;
					t_wsel[t] = WSEL_W'(w);
				end
		end
	end

	// Allocation goes into the table with the SHORTEST history still longer
	// than the provider's, stepping one further out at random. Table NT-1 has
	// the shortest history, so that is a scan downwards from the provider.
	//
	// Picking uniformly among every longer table instead, which is what this
	// did first, sends a quarter of nqueens' allocations into table 0 -- 100
	// bits of path history, which on a backtracking search never repeats, so
	// the entry is written and never read. Half the allocations went to the two
	// tables that between them serve 0.3% of that benchmark's predictions.
	always_comb
	begin
		automatic logic skip;
		skip = lfsr[0];
		can_alloc = 1'b0;
		alloc_t = '0;
		alloc_w = '0;

		for (int t = NT - 1; t >= 0; t--)
			if (!can_alloc && (!f_prov_hit || (TSEL_W'(t) < f_prov)) && t_free[t])
			begin
				if (skip)
					skip = 1'b0;
				else
				begin
					can_alloc = 1'b1;
					alloc_t = TSEL_W'(t);
					alloc_w = t_wsel[t];
				end
			end

		// The skip may have stepped over the only candidate there was.
		if (!can_alloc)
			for (int t = NT - 1; t >= 0; t--)
				if (!can_alloc && (!f_prov_hit || (TSEL_W'(t) < f_prov)) && t_free[t])
				begin
					can_alloc = 1'b1;
					alloc_t = TSEL_W'(t);
					alloc_w = t_wsel[t];
				end
	end

	always_ff @(posedge clk)
	begin
		if (~rst_n)
		begin
			phrt <= '0;
			phrb <= '0;
			pred_seq <= '0;
			u_timer <= '0;
			lfsr <= 8'h5A;
			use_alt <= 4'd8;
			for (int i = 0; i < BP_TABLES; i++)
				base_ctr[i] = 2'b01;
			for (int t = 0; t < NT; t++)
				for (int i = 0; i < SETS; i++)
					for (int w = 0; w < WAYS; w++)
					begin
						tg_ctr[t][i][w] = CTR_W'(4);
						tg_tag[t][i][w] = '0;
						tg_u[t][i][w] = '0;
						tg_val[t][i][w] = 1'b0;
					end
			for (int i = 0; i < CKPT; i++)
			begin
				ck_phrt[i] <= '0;
				ck_phrb[i] <= '0;
			end
		end
		else
		begin
			lfsr <= {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};

			// ---- path history advances on every prediction ----
			if (i_req_valid)
			begin
				ck_phrt[pred_seq] <= phrt;
				ck_phrb[pred_seq] <= phrb;
				phrt <= phrt_next(phrt, i_req_target);
				phrb <= phrb_next(phrb, i_req_pc);
				pred_seq <= pred_seq + 1'b1;
			end

			// ---- recovery ----
			// Restore the checkpoint, then re-apply the branch with where
			// control actually went. A path history cannot be rolled forward
			// without that, which is why the target is fed back here.
			if (i_rec_valid)
			begin
				if (i_rec_shift)
				begin
					phrt <= phrt_next(ck_phrt[i_rec_seq], i_rec_target);
					phrb <= phrb_next(ck_phrb[i_rec_seq], i_rec_pc);
					pred_seq <= i_rec_seq + 1'b1;
				end
				else
				begin
					phrt <= ck_phrt[i_rec_seq];
					phrb <= ck_phrb[i_rec_seq];
					pred_seq <= i_rec_seq;
				end
			end

			// ---- usefulness ageing ----
			// One set across all the tables per cycle, sweeping every set once
			// per 2**U_PERIOD_W cycles. Both halves of that matter: the index
			// must cover every set, and the sweep must be slow enough that an
			// entry earning its keep is not decayed out from under itself.
			u_timer <= u_timer + 1'b1;
			if (u_timer[U_PERIOD_W - 1 : SET_W] == '0)
				for (int t = 0; t < NT; t++)
					for (int w = 0; w < WAYS; w++)
						tg_u[t][u_timer[SET_W - 1 : 0]][w]
							<= {1'b0, tg_u[t][u_timer[SET_W - 1 : 0]][w][U_W - 1 : 1]};

			// ---- training ----
			if (i_fb_valid)
			begin
				// Learn whether a newly allocated provider or the alternate is
				// the better bet, rather than assuming the alternate always is.
				if (f_prov_hit && f_prov_weak && (f_prov_pred != f_alt_pred))
				begin
					if (alt_right && !prov_right)
					begin
						if (use_alt != 4'd15) use_alt <= use_alt + 4'd1;
					end
					else if (prov_right && !alt_right)
					begin
						if (use_alt != 4'd0) use_alt <= use_alt - 4'd1;
					end
				end

				if (f_prov_hit)
				begin
					for (int t = 0; t < NT; t++)
						if (TSEL_W'(t) == f_prov)
						begin
							if (taken)
							begin
								if (tg_ctr[t][f_set[t]][f_way[t]] != CTR_W'(CTR_MAX))
									tg_ctr[t][f_set[t]][f_way[t]]
										<= tg_ctr[t][f_set[t]][f_way[t]] + CTR_W'(1);
							end
							else
							begin
								if (tg_ctr[t][f_set[t]][f_way[t]] != '0)
									tg_ctr[t][f_set[t]][f_way[t]]
										<= tg_ctr[t][f_set[t]][f_way[t]] - CTR_W'(1);
							end

							if (f_prov_pred != f_alt_pred)
							begin
								if (prov_right)
								begin
									if (tg_u[t][f_set[t]][f_way[t]] != U_W'(3))
										tg_u[t][f_set[t]][f_way[t]]
											<= tg_u[t][f_set[t]][f_way[t]] + U_W'(1);
								end
								else
								begin
									if (tg_u[t][f_set[t]][f_way[t]] != '0)
										tg_u[t][f_set[t]][f_way[t]]
											<= tg_u[t][f_set[t]][f_way[t]] - U_W'(1);
								end
							end
						end
				end
				else
				begin
					if (taken)
					begin
						if (base_ctr[base_index(i_fb_pc)] != 2'b11)
							base_ctr[base_index(i_fb_pc)]
								<= base_ctr[base_index(i_fb_pc)] + 2'b01;
					end
					else
					begin
						if (base_ctr[base_index(i_fb_pc)] != 2'b00)
							base_ctr[base_index(i_fb_pc)]
								<= base_ctr[base_index(i_fb_pc)] - 2'b01;
					end
				end

				if (!pred_right)
				begin
					if (can_alloc)
					begin
						// One loop, with the way selected by index rather than by
						// a second loop: a nested loop writing a three
						// dimensional array non-blocking is more than the
						// simulator will unroll.
						for (int t = 0; t < NT; t++)
							if (TSEL_W'(t) == alloc_t)
							begin
								tg_tag[t][f_set[t]][alloc_w] <=
									m1_tag(i_fb_pc, fb_phrt, fb_phrb, tlen(t), blen(t));
								tg_ctr[t][f_set[t]][alloc_w] <= taken ? CTR_W'(4) : CTR_W'(3);
								tg_u[t][f_set[t]][alloc_w] <= '0;
								tg_val[t][f_set[t]][alloc_w] <= 1'b1;
							end
					end
					else
					begin
						for (int t = 0; t < NT; t++)
							if (!f_prov_hit || (TSEL_W'(t) < f_prov))
								for (int w = 0; w < WAYS; w++)
									if (tg_u[t][f_set[t]][w] != '0)
										tg_u[t][f_set[t]][w]
											<= tg_u[t][f_set[t]][w] - U_W'(1);
					end
				end

			`ifdef SIMULATION
				if (i_fb_perc == i_fb_outcome) stats_event("bp_correct");
				else stats_event("bp_wrong");
				if (i_fb_gshare == i_fb_outcome) stats_event("tage_only_correct");
				if (f_prov_hit) stats_event("tage_provided");
				else stats_event("tage_base_only");
				if (!pred_right && can_alloc) stats_event("tage_alloc");
				if (!pred_right && !can_alloc) stats_event("tage_alloc_failed");
					// Where the misses come from: a branch with no tagged entry
					// falls all the way back to a plain bimodal, which is the one
					// place this design is weaker than a perceptron.
					if (!pred_right && !f_prov_hit) stats_event("wrong_base");
					if (!pred_right && f_prov_hit) stats_event("wrong_prov");
					if (!pred_right && f_prov_hit && f_prov_weak) stats_event("wrong_prov_weak");
					if (f_prov_hit && f_prov == TSEL_W'(0)) stats_event("prov_t0");
					if (f_prov_hit && f_prov == TSEL_W'(1)) stats_event("prov_t1");
					if (f_prov_hit && f_prov == TSEL_W'(2)) stats_event("prov_t2");
					if (f_prov_hit && f_prov == TSEL_W'(3)) stats_event("prov_t3");
					if (f_prov_hit && f_prov == TSEL_W'(4)) stats_event("prov_t4");
					if (f_prov_hit && f_prov == TSEL_W'(5)) stats_event("prov_t5");
					if (!pred_right && can_alloc && alloc_t == TSEL_W'(0)) stats_event("alc_t0");
					if (!pred_right && can_alloc && alloc_t == TSEL_W'(1)) stats_event("alc_t1");
					if (!pred_right && can_alloc && alloc_t == TSEL_W'(2)) stats_event("alc_t2");
					if (!pred_right && can_alloc && alloc_t == TSEL_W'(3)) stats_event("alc_t3");
					if (!pred_right && can_alloc && alloc_t == TSEL_W'(4)) stats_event("alc_t4");
					if (!pred_right && can_alloc && alloc_t == TSEL_W'(5)) stats_event("alc_t5");
			`endif
			end
		end
	end

endmodule
