/*
 * tournament_predictor.sv
 *
 * A perceptron predictor (Jimenez and Lin, HPCA 2001) and a gshare predictor
 * running in parallel, with a per-PC chooser deciding which one to believe.
 *
 * The important structural point is that a prediction and its training are
 * separated by an arbitrary number of cycles in an out of order machine, and
 * the tables move in between. So this predictor hands back every piece of state
 * it used to make a prediction -- the table index, the history the perceptron
 * dotted against, whether the result was inside the training threshold, and
 * what each component said. That state rides with the branch through the
 * reorder buffer and comes back at commit, which is both in program order and
 * on the correct path. Training therefore uses exactly the state that produced
 * the prediction rather than whatever happens to be current.
 *
 * The global history register is speculative: it advances at predict time so
 * that closely spaced branches see each other, and is rewound on a
 * misprediction. What a branch carries for that rewind is not the history
 * itself but the sequence number of its prediction. The register here is longer
 * than the history the predictor uses -- it keeps every bit that has fallen out
 * of the live window in the last BP_ROLL predictions -- so recovering to a
 * branch is a right shift by the number of predictions made since, and the bits
 * that come back are the real ones rather than a saved copy.
 *
 * That matters for cost. A copy of the history in every reorder buffer entry is
 * BP_HISTORY * ROB_ENTRIES bits and grows with both, which is what made a long
 * history look unaffordable. This is one register plus BP_SEQ_W bits per entry,
 * and only the register grows when the history does. Training reconstructs the
 * predicting history the same way, so it still trains on exactly the state that
 * made the prediction.
 */
`include "mips_core.svh"

module tournament_predictor (
	input clk,    // Clock
	input rst_n,  // Synchronous reset active low

	// ---- prediction, made in decode ----
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

	localparam int WEIGHTS = BP_HISTORY + 1;
	localparam int WEIGHT_BITS = 8;
	localparam int WMAX = (1 << (WEIGHT_BITS - 1)) - 1;
	localparam int WMIN = -(1 << (WEIGHT_BITS - 1));
	// The training threshold from the paper: retrain whenever the dot product
	// is weak even if the direction happened to come out right.
	localparam int THRESHOLD = (193 * BP_HISTORY) / 100 + 14;

	// The live global history, plus every bit that has fallen out of it in the
	// last BP_ROLL predictions. Nothing is discarded until it is far enough back
	// that no recovery could reach it, which is what lets a rollback be an exact
	// right shift rather than a saved copy.
	localparam int HW = BP_HISTORY + BP_ROLL;

	logic [HW - 1 : 0] hist_long;
	logic [BP_SEQ_W - 1 : 0] pred_seq;

	// The history as of a given prediction: undo the shifts made since.
	function automatic logic [HW - 1 : 0] roll_back (
		input logic [HW - 1 : 0] h,
		input logic [BP_SEQ_W - 1 : 0] now,
		input logic [BP_SEQ_W - 1 : 0] was);
		return h >> (now - was);
	endfunction

	logic [BP_HISTORY - 1 : 0] ghr;
	logic [BP_HISTORY - 1 : 0] fb_hist;

	assign ghr = hist_long[BP_HISTORY - 1 : 0];
	// Training recomputes the history the branch predicted with, from the same
	// register, so it uses exactly the state that produced the prediction.
	assign fb_hist = BP_HISTORY'(roll_back(hist_long, pred_seq, i_fb_seq));

	logic signed [WEIGHT_BITS - 1 : 0] weights [BP_TABLES][WEIGHTS];
	logic [1:0] gshare_ctr [BP_TABLES];
	logic [1:0] chooser [BP_TABLES];

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Index generation
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// Instructions are word aligned, so pc[1:0] carries no information.
	// The perceptron is indexed by pc alone. The history is what the weights
	// are dotted against, so folding it into the index as well would scatter a
	// single branch's weights across many rows and it could never learn one.
	function automatic logic [BP_IDX_W - 1 : 0] perc_index (
		input logic [`ADDR_WIDTH - 1 : 0] pc,
		input logic [BP_HISTORY - 1 : 0] hist);
		return pc[BP_IDX_W + 1 : 2];
	endfunction

	function automatic logic [BP_IDX_W - 1 : 0] gshare_index (
		input logic [`ADDR_WIDTH - 1 : 0] pc,
		input logic [BP_HISTORY - 1 : 0] hist);
		return pc[BP_IDX_W + 1 : 2] ^ BP_IDX_W'(hist);
	endfunction

	function automatic logic [BP_IDX_W - 1 : 0] chooser_index (
		input logic [`ADDR_WIDTH - 1 : 0] pc);
		return pc[BP_IDX_W + 1 : 2];
	endfunction

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Prediction
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	logic [BP_IDX_W - 1 : 0] p_idx, g_idx, c_idx;
	logic signed [31:0] perc_sum;

	assign p_idx = perc_index(i_req_pc, ghr);
	assign g_idx = gshare_index(i_req_pc, ghr);
	assign c_idx = chooser_index(i_req_pc);

	always_comb
	begin
		// Bias weight, then one weight per history bit, added when the bit is
		// taken and subtracted when it is not.
		perc_sum = 32'(weights[p_idx][0]);
		for (int i = 1; i < WEIGHTS; i++)
		begin
			if (ghr[i - 1])
				perc_sum = perc_sum + 32'(weights[p_idx][i]);
			else
				perc_sum = perc_sum - 32'(weights[p_idx][i]);
		end
	end

	assign o_req_perc = (perc_sum >= 0) ? TAKEN : NOT_TAKEN;
	assign o_req_gshare = gshare_ctr[g_idx][1] ? TAKEN : NOT_TAKEN;
	// The chooser's high bit picks the component: 1 means trust gshare.
	assign o_req_prediction = chooser[c_idx][1] ? o_req_gshare : o_req_perc;

	assign o_req_index = p_idx;
	assign o_req_seq = pred_seq;
	assign o_req_weak = (perc_sum >= 0)
		? (perc_sum <= THRESHOLD)
		: (-perc_sum <= THRESHOLD);

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Update
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	function automatic logic signed [WEIGHT_BITS - 1 : 0] saturate (
		input logic signed [31:0] v);
		if (v > WMAX) return WEIGHT_BITS'(WMAX);
		else if (v < WMIN) return WEIGHT_BITS'(WMIN);
		else return WEIGHT_BITS'(v);
	endfunction

	logic [BP_IDX_W - 1 : 0] fb_g_idx, fb_c_idx;
	assign fb_g_idx = gshare_index(i_fb_pc, fb_hist);
	assign fb_c_idx = chooser_index(i_fb_pc);

	always_ff @(posedge clk)
	begin
		if (~rst_n)
		begin
			hist_long <= '0;
			pred_seq <= '0;
			// Blocking assignment for the table clear: these are large arrays
			// and a delayed assignment inside a loop is not supported. Nothing
			// else writes them on this edge, so the two forms are equivalent
			// here.
			for (int i = 0; i < BP_TABLES; i++)
			begin
				for (int j = 0; j < WEIGHTS; j++)
					weights[i][j] <= '0;
				gshare_ctr[i] <= 2'b01;		// weakly not taken
				chooser[i] <= 2'b01;			// weakly trust the perceptron
			end
		end
		else
		begin
			// ---- speculative history ----
			if (i_req_valid)
			begin
				hist_long <= {hist_long[HW - 2 : 0], (o_req_prediction == TAKEN)};
				pred_seq <= pred_seq + 1'b1;
			end

			// A misprediction wins over a prediction made the same cycle: the
			// front end is being redirected, so that prediction is discarded.
			// A conditional branch shifts its real outcome into the history it
			// saw. A jr never appears in the history at all, so its recovery
			// just puts back the history that was live when it decoded --
			// shifting there would inject a phantom branch.
			if (i_rec_valid)
			begin
				automatic logic [HW - 1 : 0] rolled =
					roll_back(hist_long, pred_seq, i_rec_seq);
				hist_long <= i_rec_shift
					? {rolled[HW - 2 : 0], (i_rec_outcome == TAKEN)}
					: rolled;
				pred_seq <= i_rec_shift ? (i_rec_seq + 1'b1) : i_rec_seq;
			`ifdef SIMULATION
				// The rollback window has to cover every prediction that can be
				// in flight. If this ever fires the history is being restored
				// from bits that were already shifted away.
				if ((pred_seq - i_rec_seq) > BP_SEQ_W'(BP_ROLL - BP_HISTORY))
					$fatal(1, "bp: rollback of %0d exceeds the history window",
						pred_seq - i_rec_seq);
			`endif
			end

			// ---- training ----
			if (i_fb_valid)
			begin
				automatic mips_core_pkg::BranchOutcome chosen =
					chooser[fb_c_idx][1] ? i_fb_gshare : i_fb_perc;

				// Perceptron: train on a wrong answer, or on a right answer
				// that was not confident enough.
				if ((i_fb_perc != i_fb_outcome) || i_fb_weak)
				begin
					for (int i = 0; i < WEIGHTS; i++)
					begin
						automatic logic hbit = (i == 0) ? 1'b1 : fb_hist[i - 1];
						automatic logic signed [31:0] delta =
							((i_fb_outcome == TAKEN) == hbit) ? 32'sd1 : -32'sd1;
						weights[i_fb_index][i] <=
							saturate(32'(weights[i_fb_index][i]) + delta);
					end
				end

				// gshare: plain saturating counter.
				if (i_fb_outcome == TAKEN)
				begin
					if (gshare_ctr[fb_g_idx] != 2'b11)
						gshare_ctr[fb_g_idx] <= gshare_ctr[fb_g_idx] + 2'b01;
				end
				else
				begin
					if (gshare_ctr[fb_g_idx] != 2'b00)
						gshare_ctr[fb_g_idx] <= gshare_ctr[fb_g_idx] - 2'b01;
				end

				// Chooser: only move when the two components disagree, towards
				// whichever one was right.
				if (i_fb_perc != i_fb_gshare)
				begin
					if (i_fb_gshare == i_fb_outcome)
					begin
						if (chooser[fb_c_idx] != 2'b11)
							chooser[fb_c_idx] <= chooser[fb_c_idx] + 2'b01;
					end
					else
					begin
						if (chooser[fb_c_idx] != 2'b00)
							chooser[fb_c_idx] <= chooser[fb_c_idx] - 2'b01;
					end
				end

			`ifdef SIMULATION
				if (chosen == i_fb_outcome) stats_event("bp_correct");
				else stats_event("bp_wrong");
				if (i_fb_perc == i_fb_outcome) stats_event("bp_perceptron_correct");
				if (i_fb_gshare == i_fb_outcome) stats_event("bp_gshare_correct");
			`endif
			end
		end
	end

endmodule
