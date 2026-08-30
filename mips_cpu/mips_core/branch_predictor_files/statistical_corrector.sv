/*
 * statistical_corrector.sv
 *
 * The SC of TAGE-SC-L (Seznec, CBP-4/CBP-5), attached to the Firestorm shaped
 * TAGE in tage_m1.sv.
 *
 * A tagged predictor answers a branch by finding the longest history that has
 * seen this exact context before and replaying what happened. That fails in a
 * particular way: when the context matches but the outcome is only correlated,
 * not determined, the tagged entry commits to one answer and is confidently
 * wrong. Measured on this core, 36,378 of nqueens' 38,623 mispredictions are
 * that case -- a tagged entry matched and gave the wrong answer -- and only
 * 2,245 are branches with no tagged entry at all. Adding tables or history to
 * the TAGE does nothing about the first number.
 *
 * The corrector answers the same branch a different way. Instead of one entry
 * voting, many weakly correlated signed counters are SUMMED, the way a
 * perceptron sums its weights, and the sign of the sum is a second opinion. It
 * overrides the TAGE only when the magnitude of the sum clears an adaptive
 * threshold, so it is silent on the branches the TAGE already has right.
 *
 * Three families of counters, indexed three different ways:
 *
 *   bias   pc, then pc with the TAGE prediction, then pc with the TAGE
 *          prediction and its confidence. These learn the systematic error of
 *          the TAGE itself -- "at this branch, when the tables say weakly
 *          taken, it is really not taken".
 *
 *   path   GEHL banks folded from the two path history registers the TAGE
 *          indexes with. Same information, summed instead of matched.
 *
 *   local  GEHL banks over a per branch history of that branch's own recent
 *          outcomes. This is the family the TAGE has no equivalent of at all,
 *          and the one a backtracking search should like: the inner loop of
 *          nqueens revisits the same test with a pattern that is regular in
 *          its own past and invisible in the global path.
 *
 * The local history is kept twice. A speculative copy advances at prediction
 * so the front end sees a current history, and an architectural copy advances
 * at commit; a squash restores the speculative copy from the architectural
 * one. That restore is imprecise -- correct path branches between the commit
 * point and the redirect have already updated the speculative copy and their
 * updates are lost -- but it is bounded, self healing, and it is what the cost
 * of a precise per branch checkpoint buys out of. Training always uses the
 * architectural copy, so the trained history is never wrong, only stale.
 */
`include "mips_core.svh"

module statistical_corrector (
	input clk,    // Clock
	input rst_n,  // Synchronous reset active low

	// ---- query, in fetch, alongside the TAGE lookup ----
	input  logic i_q_valid,
	input  logic [`ADDR_WIDTH - 1 : 0] i_q_pc,
	input  logic [M1_PHRT_W - 1 : 0] i_q_phrt,
	input  logic [M1_PHRB_W - 1 : 0] i_q_phrb,
	input  mips_core_pkg::BranchOutcome i_q_tage,
	// 0 = no tagged table matched, 1 = matched but the counter is weak,
	// 2 = matched with a saturated counter.
	input  logic [1 : 0] i_q_conf,
	// The direction fetch will actually run with, after this module has had
	// its say. Feeding it back is what lets the speculative local history be
	// current rather than a commit old.
	input  mips_core_pkg::BranchOutcome i_q_final,
	input  logic [BP_SEQ_W - 1 : 0] i_q_seq,
	output mips_core_pkg::BranchOutcome o_q_pred,
	output logic o_q_use,

	// ---- train, at commit, in program order ----
	input  logic i_fb_valid,
	input  logic [`ADDR_WIDTH - 1 : 0] i_fb_pc,
	// The path histories as they were when this branch predicted, out of the
	// TAGE's checkpoint file.
	input  logic [M1_PHRT_W - 1 : 0] i_fb_phrt,
	input  logic [M1_PHRB_W - 1 : 0] i_fb_phrb,
	input  mips_core_pkg::BranchOutcome i_fb_tage,
	input  logic [1 : 0] i_fb_conf,
	input  mips_core_pkg::BranchOutcome i_fb_outcome,
	input  logic [BP_SEQ_W - 1 : 0] i_fb_seq,

	// ---- recovery ----
	input  logic i_rec_valid
);

`ifdef SIMULATION
	import "DPI-C" function void stats_event (input string e);
`endif

	localparam int CW    = SC_CTR_W;
	localparam int IW    = SC_IDX_W;
	localparam int ENT   = 1 << IW;
	localparam int BW    = SC_BIAS_W;
	localparam int BENT  = 1 << BW;
	localparam int LIW   = SC_LHT_IDX_W;
	localparam int LENT  = 1 << LIW;
	localparam int LHW   = SC_LHIST_W;

	localparam int NG    = SC_NG;
	localparam int NB    = SC_NB;
	localparam int NL    = SC_NL;

	localparam logic signed [CW - 1 : 0] CMAX =  CW'((1 << (CW - 1)) - 1);
	localparam logic signed [CW - 1 : 0] CMIN = -CW'(1 << (CW - 1));

	// Wide enough for every counter at full scale plus room to spare.
	localparam int SW = CW + 5;

	// Threshold bounds. Starting low makes the corrector loud early, which is
	// what the adaptation is there to walk back.
	localparam int THMIN = 5;
	localparam int THMAX = 255;
	localparam int TCMAX = 63;

	localparam int CKPT  = 1 << BP_SEQ_W;

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Bank history lengths
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// Roughly geometric, in the GEHL manner, and reaching the full width of
	// each register so the longest bank sees everything the TAGE's longest
	// table does.
	function automatic int unsigned glen (input int unsigned b);
		case (b)
			0: return 4;  1: return 8;  2: return 16;
			3: return 32; 4: return 64; default: return M1_PHRT_W;
		endcase
	endfunction

	function automatic int unsigned bqlen (input int unsigned b);
		case (b)
			0: return 2;  1: return 5;  2: return 10;
			3: return 20; default: return M1_PHRB_W;
		endcase
	endfunction

	function automatic int unsigned llen (input int unsigned b);
		case (b)
			0: return 2;  1: return 4;  2: return 8;
			default: return LHW;
		endcase
	endfunction

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Index folding
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// Each bank folds its own history length down onto the index width and
	// mixes in the pc, shifted by the bank number so two banks of similar
	// length do not collide on the same rows.
	function automatic logic [IW - 1 : 0] fold_t (
		input logic [`ADDR_WIDTH - 1 : 0] pc,
		input logic [M1_PHRT_W - 1 : 0] h,
		input int unsigned len,
		input int unsigned b);
		logic [IW - 1 : 0] f;
		f = '0;
		for (int i = 0; i < M1_PHRT_W; i++)
			if (i < int'(len))
				f[i % IW] = f[i % IW] ^ h[i];
		return f ^ IW'(pc[IW + 1 : 2]) ^ IW'(b);
	endfunction

	function automatic logic [IW - 1 : 0] fold_b (
		input logic [`ADDR_WIDTH - 1 : 0] pc,
		input logic [M1_PHRB_W - 1 : 0] h,
		input int unsigned len,
		input int unsigned b);
		logic [IW - 1 : 0] f;
		f = '0;
		for (int i = 0; i < M1_PHRB_W; i++)
			if (i < int'(len))
				f[i % IW] = f[i % IW] ^ h[i];
		return f ^ IW'(pc[IW + 1 : 2]) ^ IW'(b);
	endfunction

	function automatic logic [IW - 1 : 0] fold_l (
		input logic [`ADDR_WIDTH - 1 : 0] pc,
		input logic [LHW - 1 : 0] h,
		input int unsigned len,
		input int unsigned b);
		logic [IW - 1 : 0] f;
		f = '0;
		for (int i = 0; i < LHW; i++)
			if (i < int'(len))
				f[i % IW] = f[i % IW] ^ h[i];
		return f ^ IW'(pc[IW + 1 : 2]) ^ IW'(b);
	endfunction

	function automatic logic [LIW - 1 : 0] lht_index (
		input logic [`ADDR_WIDTH - 1 : 0] pc);
		return pc[LIW + 1 : 2];
	endfunction

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Storage
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	logic signed [CW - 1 : 0] g_tab [NG][ENT];
	logic signed [CW - 1 : 0] b_tab [NB][ENT];
	logic signed [CW - 1 : 0] l_tab [NL][ENT];

	// Three bias tables of rising specificity. The first is the branch's own
	// tendency, the second is that tendency conditioned on what the TAGE said,
	// the third adds how sure the TAGE was.
	logic signed [CW - 1 : 0] bias_p   [BENT];
	logic signed [CW - 1 : 0] bias_pt  [2 * BENT];
	logic signed [CW - 1 : 0] bias_ptc [8 * BENT];

	logic [LHW - 1 : 0] lht_spec [LENT];
	logic [LHW - 1 : 0] lht_arch [LENT];

	logic [8 : 0] thres;
	logic signed [7 : 0] tc;

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Query
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	logic [LHW - 1 : 0] q_lh;
	assign q_lh = lht_spec[lht_index(i_q_pc)];

	logic [BW - 1 : 0] q_bp;
	logic [BW : 0] q_bpt;
	logic [BW + 2 : 0] q_bptc;
	assign q_bp   = i_q_pc[BW + 1 : 2];
	assign q_bpt  = {i_q_pc[BW + 1 : 2], (i_q_tage == TAKEN)};
	assign q_bptc = {i_q_pc[BW + 1 : 2], (i_q_tage == TAKEN), i_q_conf};

	logic [IW - 1 : 0] q_gi [NG], q_bi [NB], q_li [NL];
	logic signed [SW - 1 : 0] q_sum;

	always_comb
	begin
	`ifdef SC_NO_BIAS
		q_sum = '0;
	`else
		q_sum = SW'(bias_p[q_bp]) + SW'(bias_pt[q_bpt]) + SW'(bias_ptc[q_bptc]);
	`endif
		for (int b = 0; b < NG; b++)
		begin
			q_gi[b] = fold_t(i_q_pc, i_q_phrt, glen(b), b);
		`ifndef SC_NO_PATH
			q_sum = q_sum + SW'(g_tab[b][q_gi[b]]);
		`endif
		end
		for (int b = 0; b < NB; b++)
		begin
			q_bi[b] = fold_b(i_q_pc, i_q_phrb, bqlen(b), b);
		`ifndef SC_NO_PATH
			q_sum = q_sum + SW'(b_tab[b][q_bi[b]]);
		`endif
		end
		for (int b = 0; b < NL; b++)
		begin
			q_li[b] = fold_l(i_q_pc, q_lh, llen(b), b);
		`ifndef SC_NO_LOCAL
			q_sum = q_sum + SW'(l_tab[b][q_li[b]]);
		`endif
		end
	end

	logic signed [SW - 1 : 0] q_mag;
	assign q_mag = (q_sum < 0) ? -q_sum : q_sum;

	assign o_q_pred = (q_sum >= 0) ? TAKEN : NOT_TAKEN;
	// Silent unless the sum is emphatic. Everything the TAGE already gets
	// right sits below this line and is left alone.
	assign o_q_use = (q_mag >= SW'(thres));

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Training
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// Recomputed at commit from the checkpointed path history and the
	// architectural local history, so the counters that are trained are the
	// ones that would have been read with correct state.
	logic [LHW - 1 : 0] f_lh;
	assign f_lh = lht_arch[lht_index(i_fb_pc)];

	logic [BW - 1 : 0] f_bp;
	logic [BW : 0] f_bpt;
	logic [BW + 2 : 0] f_bptc;
	assign f_bp   = i_fb_pc[BW + 1 : 2];
	assign f_bpt  = {i_fb_pc[BW + 1 : 2], (i_fb_tage == TAKEN)};
	assign f_bptc = {i_fb_pc[BW + 1 : 2], (i_fb_tage == TAKEN), i_fb_conf};

	// Only the INDICES are recomputed at commit. The sum itself is the one
	// that actually made the decision, carried down the pipeline in a file
	// indexed by the sequence number the branch already has.
	//
	// Recomputing the sum instead, which is what this did first, reads the
	// same rows but with whatever every branch since has trained into them.
	// The perceptron rule and the threshold both then adapt to a number the
	// machine never acted on. On coin that was worth 16,186 predictions: the
	// corrector was a net LOSS against the TAGE alone, on the one benchmark
	// where the TAGE is right 98.8% of the time and the threshold most needed
	// to learn to stay quiet.
	logic [IW - 1 : 0] f_gi [NG], f_bi [NB], f_li [NL];

	always_comb
	begin
		for (int b = 0; b < NG; b++)
			f_gi[b] = fold_t(i_fb_pc, i_fb_phrt, glen(b), b);
		for (int b = 0; b < NB; b++)
			f_bi[b] = fold_b(i_fb_pc, i_fb_phrb, bqlen(b), b);
		for (int b = 0; b < NL; b++)
			f_li[b] = fold_l(i_fb_pc, f_lh, llen(b), b);
	end

	logic signed [SW - 1 : 0] ck_sum [CKPT];
	logic signed [SW - 1 : 0] f_sum, f_mag;
	assign f_sum = ck_sum[i_fb_seq];
	assign f_mag = (f_sum < 0) ? -f_sum : f_sum;

	mips_core_pkg::BranchOutcome f_sc_pred;
	logic f_taken, f_train, f_spoke;
	assign f_sc_pred = (f_sum >= 0) ? TAKEN : NOT_TAKEN;
	assign f_taken = (i_fb_outcome == TAKEN);
	// The perceptron rule: train when wrong, and keep training while right but
	// unconvinced, so the counters grow until they clear the threshold.
	assign f_train = (f_sc_pred != i_fb_outcome) || (f_mag < SW'(thres));
	// The threshold only adapts on branches where the corrector actually had
	// an opinion that differed; agreeing with the TAGE says nothing about
	// whether the bar is in the right place.
	assign f_spoke = (f_sc_pred != i_fb_tage);

	function automatic logic signed [CW - 1 : 0] bump (
		input logic signed [CW - 1 : 0] c,
		input logic up);
		if (up)
			return (c == CMAX) ? c : CW'(c + CW'(1));
		else
			return (c == CMIN) ? c : CW'(c - CW'(1));
	endfunction

	always_ff @(posedge clk)
	begin
		if (~rst_n)
		begin
			thres <= 9'd20;
			tc <= '0;
			// Cleared whole rather than entry by entry: these three tables are
			// past Verilator's unroll limit, and a delayed assignment to an
			// unpacked array element inside a for loop is unsupported above it.
			bias_p   <= '{default: '0};
			bias_pt  <= '{default: '0};
			bias_ptc <= '{default: '0};
			// One '{default:} per unpacked dimension. Verilator applies the
			// keyword only one level deep, so a flat '{default:'0} on a
			// multidimensional array is rejected; nesting it to the array's own
			// depth is accepted, and unrolls to nothing, which keeps it under
			// yosys-slang's 4000-iteration limit as well.
			g_tab <= '{default: '{default: '0}};
			b_tab <= '{default: '{default: '0}};
			l_tab <= '{default: '{default: '0}};
			for (int i = 0; i < LENT; i++)
			begin
				lht_spec[i] <= '0;
				lht_arch[i] <= '0;
			end
			for (int i = 0; i < CKPT; i++)
				ck_sum[i] <= '0;
		end
		else
		begin
			// ---- speculative local history, and the sum that decided ----
			if (i_q_valid)
				ck_sum[i_q_seq] <= q_sum;
			if (i_q_valid)
				lht_spec[lht_index(i_q_pc)] <=
					{lht_spec[lht_index(i_q_pc)][LHW - 2 : 0], (i_q_final == TAKEN)};

			// ---- squash: fall back to the committed local histories ----
			// Written after the speculative update above so a redirect in the
			// same cycle wins.
			//
			// This is a flash copy of the whole table in one cycle, which is
			// what holds the table to 256 entries: 4 Kb of restore is the same
			// order as the rename map checkpoint the machine already flash
			// restores, and a larger local history file would have to be
			// repaired some other way.
			if (i_rec_valid)
				for (int i = 0; i < LENT; i++)
					lht_spec[i] <= lht_arch[i];

			if (i_fb_valid)
			begin
				lht_arch[lht_index(i_fb_pc)] <=
					{lht_arch[lht_index(i_fb_pc)][LHW - 2 : 0], f_taken};

				if (f_train)
				begin
					bias_p[f_bp] <= bump(bias_p[f_bp], f_taken);
					bias_pt[f_bpt] <= bump(bias_pt[f_bpt], f_taken);
					bias_ptc[f_bptc] <= bump(bias_ptc[f_bptc], f_taken);
					for (int b = 0; b < NG; b++)
						g_tab[b][f_gi[b]] <= bump(g_tab[b][f_gi[b]], f_taken);
					for (int b = 0; b < NB; b++)
						b_tab[b][f_bi[b]] <= bump(b_tab[b][f_bi[b]], f_taken);
					for (int b = 0; b < NL; b++)
						l_tab[b][f_li[b]] <= bump(l_tab[b][f_li[b]], f_taken);
				end

				// ---- adaptive threshold ----
				// Overriding and being right earns a lower bar; overriding and
				// being wrong raises it. The intermediate counter is what
				// keeps a single branch from moving the threshold.
				if (f_spoke)
				begin
					if (f_sc_pred == i_fb_outcome)
					begin
						if (tc == -8'sd63)
						begin
							if (thres > 9'(THMIN)) thres <= thres - 9'd1;
							tc <= '0;
						end
						else
							tc <= tc - 8'sd1;
					end
					else
					begin
						if (tc == 8'sd63)
						begin
							if (thres < 9'(THMAX)) thres <= thres + 9'd1;
							tc <= '0;
						end
						else
							tc <= tc + 8'sd1;
					end
				end

			`ifdef SIMULATION
				if (f_spoke && (f_mag >= SW'(thres)))
				begin
					stats_event("sc_override");
					if (f_sc_pred == i_fb_outcome) stats_event("sc_override_good");
					else stats_event("sc_override_bad");
				end
				if (f_train) stats_event("sc_train");
			`endif
			end
		end
	end

endmodule
