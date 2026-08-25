/*
 * ooo_backend.sv
 *
 * The out of order back end: rename and the reorder buffer, the issue queue,
 * the physical register file, the execution units and the load/store queue.
 *
 * The execute path is a single cycle. An instruction selected by the issue
 * queue reads the physical register file asynchronously, goes through its ALU,
 * and has its result written back on the same clock edge, which is what lets a
 * dependent instruction issue in the very next cycle without a bypass network.
 *
 * Memory instructions use their ALU only to add base and offset; the address
 * goes to the load/store queue instead of the register file. A store also
 * writes back immediately, but only to tell the reorder buffer its address and
 * data are known -- the cache is not touched until commit.
 */
`include "mips_core.svh"

module ooo_backend (
	input clk,    // Clock
	input rst_n,  // Synchronous reset active low

	// ---- from the front end ----
	input  dec_uop_t fe_uop [FE_WIDTH],
	output logic fe_stall,

	// ---- redirect back to the front end ----
	output logic ex_redirect_valid,
	output logic [`ADDR_WIDTH - 1 : 0] ex_redirect_pc,

	// ---- branch predictor training ----
	output logic fb_valid,
	output logic [`ADDR_WIDTH - 1 : 0] fb_pc,
	output logic [BP_IDX_W - 1 : 0] fb_index,
	output logic [BP_HISTORY - 1 : 0] fb_hist,
	output logic fb_weak,
	output mips_core_pkg::BranchOutcome fb_perc,
	output mips_core_pkg::BranchOutcome fb_gshare,
	output mips_core_pkg::BranchOutcome fb_outcome,
	output logic rec_valid,
	output logic [BP_HISTORY - 1 : 0] rec_hist,
	output logic rec_shift,
	output mips_core_pkg::BranchOutcome rec_outcome,

	// ---- D cache ----
	d_cache_input_ifc.out dc_in,
	cache_output_ifc.in dc_out,
	input  logic dc_miss_pending,
	input  mshr_id_t dc_mshr_id,
	input  logic dc_fill_valid,
	input  mshr_id_t dc_fill_id,

	output logic done
);

`ifdef SIMULATION
	import "DPI-C" function void stats_event (input string e);
`endif

	// ---- rename / reorder buffer ----
	uop_t rr_disp_uop [FE_WIDTH];
	logic [PHYS_REGS - 1 : 0] busy;
	rob_idx_t rob_head;
	logic [ROB_IDX_W : 0] rob_count;
	logic squash;
	rob_idx_t squash_head;
	logic [ROB_IDX_W : 0] squash_count;
	logic [ROB_IDX_W : 0] iq_free;
	logic [LSQ_IDX_W : 0] lsq_free;

	logic st_valid, st_done;
	logic [`ADDR_WIDTH - 1 : 0] st_addr;
	logic [`DATA_WIDTH - 1 : 0] st_data;

	logic commit_en [FE_WIDTH];
	rob_idx_t commit_rob_idx [FE_WIDTH];
	logic commit_is_mem [FE_WIDTH];

	// ---- writeback bus ----
	logic wb_valid [NUM_WB];
	rob_idx_t wb_rob_idx [NUM_WB];
	preg_t wb_pd [NUM_WB];
	logic wb_writes [NUM_WB];
	logic [`DATA_WIDTH - 1 : 0] wb_result [NUM_WB];
	logic wb_redirect [NUM_WB];
	logic [`ADDR_WIDTH - 1 : 0] wb_target [NUM_WB];
	mips_core_pkg::BranchOutcome wb_outcome [NUM_WB];
	logic [`ADDR_WIDTH - 1 : 0] wb_mem_addr [NUM_WB];
	logic [`DATA_WIDTH - 1 : 0] wb_mem_data [NUM_WB];

	// ---- dispatch, after the load/store queue has handed out its indices ----
	uop_t disp_uop [FE_WIDTH];
	lsq_idx_t disp_lsq_idx [FE_WIDTH];

	always_comb
	begin
		for (int k = 0; k < FE_WIDTH; k++)
		begin
			disp_uop[k] = rr_disp_uop[k];
			disp_uop[k].lsq_idx = disp_lsq_idx[k];
		end
	end

	rename_rob RENAME_ROB (
		.clk, .rst_n,
		.fe_uop, .fe_stall,
		.iq_free, .lsq_free,
		.disp_uop (rr_disp_uop),
		.busy,
		.wb_valid, .wb_rob_idx, .wb_pd, .wb_writes, .wb_result,
		.wb_redirect, .wb_target, .wb_outcome, .wb_mem_addr, .wb_mem_data,
		.mv_valid, .mv_rob_idx,
		.squash, .squash_head, .squash_count,
		.redirect_valid (ex_redirect_valid),
		.redirect_pc    (ex_redirect_pc),
		.st_valid, .st_addr, .st_data, .st_done,
		.rob_head_o  (rob_head),
		.rob_count_o (rob_count),
		.commit_en_o      (commit_en),
		.commit_rob_idx_o (commit_rob_idx),
		.commit_is_mem_o  (commit_is_mem),
		.fb_valid, .fb_pc, .fb_index, .fb_hist, .fb_weak,
		.fb_perc, .fb_gshare, .fb_outcome,
		.rec_valid, .rec_hist, .rec_shift, .rec_outcome,
		.done
	);

	// ---- issue queue ----
	logic issue_valid [ISSUE_WIDTH];
	uop_t issue_uop [ISSUE_WIDTH];

	logic lsq_accept, lsq_load_free, lsq_has_unresolved;
	logic mv_valid;
	rob_idx_t mv_rob_idx;
	rob_idx_t lsq_oldest_unresolved;

	issue_queue ISSUE_QUEUE (
		.clk, .rst_n,
		.disp_uop,
		.iq_free,
		.busy, .rob_head, .rob_count,
		.lsq_accept,
		.lsq_load_free,
		.lsq_has_unresolved_store (lsq_has_unresolved),
		.lsq_oldest_unresolved,
		.issue_valid, .issue_uop,
		.squash, .squash_head, .squash_count
	);

	// ---- physical register file ----
	preg_t prf_raddr [2 * ISSUE_WIDTH];
	logic [`DATA_WIDTH - 1 : 0] prf_rdata [2 * ISSUE_WIDTH];
	logic prf_wen [ISSUE_WIDTH + 1];
	preg_t prf_waddr [ISSUE_WIDTH + 1];
	logic [`DATA_WIDTH - 1 : 0] prf_wdata [ISSUE_WIDTH + 1];

	always_comb
	begin
		for (int s = 0; s < ISSUE_WIDTH; s++)
		begin
			prf_raddr[2 * s]     = issue_uop[s].ps1;
			prf_raddr[2 * s + 1] = issue_uop[s].ps2;
		end
	end

	prf PRF (
		.clk,
		.r_addr (prf_raddr), .r_data (prf_rdata),
		.w_en   (prf_wen),   .w_addr (prf_waddr), .w_data (prf_wdata)
	);

	// ---- execution units ----
	alu_input_ifc alu_in [ISSUE_WIDTH] ();
	alu_output_ifc alu_out [ISSUE_WIDTH] ();
	logic alu_done [ISSUE_WIDTH];

	// Flattened copies of the ALU outputs. An interface array cannot be indexed
	// by a loop variable, so the always_comb blocks below read these instead.
	logic [`DATA_WIDTH - 1 : 0] alu_result [ISSUE_WIDTH];
	mips_core_pkg::BranchOutcome alu_branch [ISSUE_WIDTH];

	genvar s;
	generate
		for (s = 0; s < ISSUE_WIDTH; s++)
		begin : exec
			assign alu_in[s].valid = issue_valid[s];
			assign alu_in[s].alu_ctl = issue_uop[s].alu_ctl;
			assign alu_in[s].op1 = prf_rdata[2 * s];
			assign alu_in[s].op2 = issue_uop[s].uses_imm
				? issue_uop[s].imm
				: prf_rdata[2 * s + 1];

			alu ALU (
				.in   (alu_in[s]),
				.out  (alu_out[s]),
				.done (alu_done[s])
			);

			assign alu_result[s] = alu_out[s].result;
			assign alu_branch[s] = alu_out[s].branch_outcome;
		end
	endgenerate

	// ---- writeback from the ALUs ----
	always_comb
	begin
		for (int i = 0; i < ISSUE_WIDTH; i++)
		begin
			automatic logic is_load = issue_uop[i].is_mem
				&& (issue_uop[i].mem_action == READ);
			automatic logic is_store = issue_uop[i].is_mem
				&& (issue_uop[i].mem_action == WRITE);
			// jr takes its target straight out of the register it read.
			automatic logic [`ADDR_WIDTH - 1 : 0] jr_target =
				prf_rdata[2 * i][`ADDR_WIDTH - 1 : 0];

			// A load is not finished here; the load/store queue reports it when
			// the data comes back. Everything else, stores included, retires
			// its reorder buffer entry now.
			wb_valid[i] = issue_valid[i] && !is_load;
			wb_rob_idx[i] = issue_uop[i].rob_idx;
			wb_pd[i] = issue_uop[i].pd;
			wb_writes[i] = issue_valid[i] && issue_uop[i].uses_rw && !issue_uop[i].is_mem;
			wb_result[i] = alu_result[i];
			wb_outcome[i] = alu_branch[i];
			wb_mem_addr[i] = alu_result[i][`ADDR_WIDTH - 1 : 0];
			wb_mem_data[i] = prf_rdata[2 * i + 1];

			// A conditional branch is wrong when the outcome differs from the
			// guess. A jr is wrong unless it happens to land on the
			// instruction after its own delay slot.
			wb_redirect[i] = issue_valid[i]
				&& ((issue_uop[i].is_branch
						&& (alu_branch[i] != issue_uop[i].prediction))
					|| (issue_uop[i].is_jump_reg
						&& (jr_target != issue_uop[i].seq_target)));
			wb_target[i] = issue_uop[i].is_jump_reg
				? jr_target
				: issue_uop[i].recovery_target;

			prf_wen[i] = wb_writes[i];
			prf_waddr[i] = issue_uop[i].pd;
			prf_wdata[i] = alu_result[i];

			// Silence the unused per-ALU done flag; MTC0_DONE is reported at
			// commit instead, where the instruction is known to be real.
			if (is_store) begin end
		end
	end

	// ---- load/store queue ----
	logic mem_issue;
	uop_t mem_uop;
	logic [`ADDR_WIDTH - 1 : 0] mem_addr;
	logic [`DATA_WIDTH - 1 : 0] mem_data;

	always_comb
	begin
		mem_issue = 1'b0;
		mem_uop = '0;
		mem_addr = '0;
		mem_data = '0;
		// The issue queue only ever selects one memory operation per cycle.
		for (int i = 0; i < ISSUE_WIDTH; i++)
		begin
			if (issue_valid[i] && issue_uop[i].is_mem)
			begin
				mem_issue = 1'b1;
				mem_uop = issue_uop[i];
				mem_addr = alu_result[i][`ADDR_WIDTH - 1 : 0];
				mem_data = prf_rdata[2 * i + 1];
			end
		end
	end

	logic ld_wb_valid, ld_wb_writes;
	rob_idx_t ld_wb_rob_idx;
	preg_t ld_wb_pd;
	logic [`DATA_WIDTH - 1 : 0] ld_wb_data;
	logic [`ADDR_WIDTH - 1 : 0] ld_wb_addr;

	lsq LSQ (
		.clk, .rst_n,
		// The queue assigns disp_lsq_idx, so it is given the pre-merge uop to
		// keep that from looking like a combinational cycle through the struct.
		.disp_uop (rr_disp_uop),
		.disp_lsq_idx, .lsq_free,
		.mem_issue, .mem_uop, .mem_addr, .mem_data,
		.o_accept             (lsq_accept),
		.o_load_free          (lsq_load_free),
		.o_has_unresolved     (lsq_has_unresolved),
		.o_oldest_unresolved  (lsq_oldest_unresolved),
		.rob_head,
		.o_mv_valid   (mv_valid),
		.o_mv_rob_idx (mv_rob_idx),
		.ld_wb_valid, .ld_wb_rob_idx, .ld_wb_pd, .ld_wb_writes,
		.ld_wb_data, .ld_wb_addr,
		.st_valid, .st_addr, .st_data, .st_done,
		.commit_en, .commit_rob_idx, .commit_is_mem,
		.squash, .squash_head, .squash_count,
		.dc_in, .dc_out,
		.dc_miss_pending, .dc_mshr_id, .dc_fill_valid, .dc_fill_id
	);

	// ---- writeback from returning loads ----
	always_comb
	begin
		wb_valid[ISSUE_WIDTH] = ld_wb_valid;
		wb_rob_idx[ISSUE_WIDTH] = ld_wb_rob_idx;
		wb_pd[ISSUE_WIDTH] = ld_wb_pd;
		wb_writes[ISSUE_WIDTH] = ld_wb_valid && ld_wb_writes;
		wb_result[ISSUE_WIDTH] = ld_wb_data;
		wb_redirect[ISSUE_WIDTH] = 1'b0;
		wb_target[ISSUE_WIDTH] = '0;
		wb_outcome[ISSUE_WIDTH] = NOT_TAKEN;
		wb_mem_addr[ISSUE_WIDTH] = ld_wb_addr;
		wb_mem_data[ISSUE_WIDTH] = '0;

		prf_wen[ISSUE_WIDTH] = ld_wb_valid && ld_wb_writes;
		prf_waddr[ISSUE_WIDTH] = ld_wb_pd;
		prf_wdata[ISSUE_WIDTH] = ld_wb_data;
	end

`ifdef SIMULATION
	always_ff @(posedge clk)
	begin
		if (rst_n)
		begin
			automatic int n = 0;
			for (int i = 0; i < ISSUE_WIDTH; i++)
				if (issue_valid[i]) n++;
			case (n)
				0: stats_event("issue_0");
				1: stats_event("issue_1");
				default: stats_event("issue_2");
			endcase
		end
	end
`endif

endmodule
