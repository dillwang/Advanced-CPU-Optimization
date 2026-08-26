/* mips_core.sv
* Author: Pravin P. Prabhu, Dean Tullsen, and Zinsser Zhang
* Last Revision: 03/13/2022
* Abstract:
*   The core module for the MIPS32 processor. The original five stage in-order
* pipeline has been replaced with a superscalar out of order machine:
*
*   FETCH -> fetch buffer -> DECODE/PREDICT -> RENAME/DISPATCH
*                                                    |
*                                     +--------------+--------------+
*                                     |              |              |
*                                 issue queue   reorder buffer  load/store
*                                     |                             queue
*                                  execute -----> writeback -----> commit
*
* The front end, rename and commit are all in program order and FE_WIDTH wide.
* Everything between dispatch and writeback runs out of order, bounded by the
* issue queue and the reorder buffer. All architectural state changes -- the
* architectural map, freeing physical registers, stores reaching the D cache,
* and the simulation event stream -- happen at commit, so a squashed
* instruction can never be observed.
*
* All addresses used in this scope are byte addresses (26-bit)
*/
`include "mips_core.svh"

module mips_core (
	// General signals
	input clk,    // Clock
	input rst_n,  // Synchronous reset active low
	output done,  // Execution is done

	// AXI interfaces
	input AWREADY,
	output AWVALID,
	output [3:0] AWID,
	output [3:0] AWLEN,
	output [`ADDR_WIDTH - 1 : 0] AWADDR,

	input WREADY,
	output WVALID,
	output WLAST,
	output [3:0] WID,
	output [`DATA_WIDTH - 1 : 0] WDATA,

	output BREADY,
	input BVALID,
	input [3:0] BID,

	input ARREADY,
	output ARVALID,
	output [3:0] ARID,
	output [3:0] ARLEN,
	output [`ADDR_WIDTH - 1 : 0] ARADDR,

	output RREADY,
	input RVALID,
	input RLAST,
	input [3:0] RID,
	input [`DATA_WIDTH - 1 : 0] RDATA
);

	// |||| Front end
	pc_ifc if_pc_current();
	pc_ifc if_pc_next();
	fetch_output_ifc if_i_cache_output();
	fetch_output_ifc if_sb_output();

	// Instruction supply seen by the front end: the cache when it hits, the
	// stream buffer when the cache does not and the prefetcher ran far enough
	// ahead to have the line.
	logic fe_inst_valid;
	logic [FETCH_WIDTH - 1 : 0] fe_word_valid;
	logic [`DATA_WIDTH - 1 : 0] fe_inst_data [FETCH_WIDTH];

	dec_uop_t fe_uop [FE_WIDTH];
	logic fe_stall;

	// |||| Redirect from execute
	logic ex_redirect_valid;
	logic [`ADDR_WIDTH - 1 : 0] ex_redirect_pc;

	// |||| Branch predictor
	logic bp_req_valid;
	logic [`ADDR_WIDTH - 1 : 0] bp_req_pc;
	mips_core_pkg::BranchOutcome bp_prediction;
	logic [BP_IDX_W - 1 : 0] bp_index;
	logic [BP_SEQ_W - 1 : 0] bp_seq;
	logic bp_weak;
	mips_core_pkg::BranchOutcome bp_perc;
	mips_core_pkg::BranchOutcome bp_gshare;

	logic fb_valid;
	logic [`ADDR_WIDTH - 1 : 0] fb_pc;
	logic [BP_IDX_W - 1 : 0] fb_index;
	logic [BP_SEQ_W - 1 : 0] fb_seq;
	logic fb_weak;
	mips_core_pkg::BranchOutcome fb_perc;
	mips_core_pkg::BranchOutcome fb_gshare;
	mips_core_pkg::BranchOutcome fb_outcome;
	logic rec_valid;
	logic [BP_SEQ_W - 1 : 0] rec_seq;
	logic [`ADDR_WIDTH - 1 : 0] rec_pc;
	logic [`ADDR_WIDTH - 1 : 0] rec_target;
	logic [`ADDR_WIDTH - 1 : 0] bp_req_target;
	logic rec_shift;
	mips_core_pkg::BranchOutcome rec_outcome;

	// |||| Memory
	d_cache_input_ifc mem_d_cache_input();
	cache_output_ifc mem_d_cache_output();
	logic mem_d_cache_miss_pending;
	mips_core_pkg::mshr_id_t mem_d_cache_mshr_id;
	logic mem_d_cache_fill_valid;
	mips_core_pkg::mshr_id_t mem_d_cache_fill_id;

	axi_write_address axi_write_address();
	axi_write_data axi_write_data();
	axi_write_response axi_write_response();
	axi_read_address axi_read_address();
	axi_read_data axi_read_data();

	axi_write_address mem_write_address[1]();
	axi_write_data mem_write_data[1]();
	axi_write_response mem_write_response[1]();
	axi_read_address mem_read_address[3]();
	axi_read_data mem_read_data[3]();

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Front end
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	frontend FRONTEND (
		.clk, .rst_n,

		.o_pc_current (if_pc_current.pc),
		.o_pc_next    (if_pc_next.pc),
		.i_inst_valid (fe_inst_valid),
		.i_word_valid (fe_word_valid),
		.i_inst_data  (fe_inst_data),

		.fe_uop, .fe_stall,

		.ex_redirect_valid, .ex_redirect_pc,

		.bp_req_valid, .bp_req_pc, .bp_req_target,
		.bp_prediction, .bp_index, .bp_seq, .bp_weak,
		.bp_perc, .bp_gshare
	);

	i_cache I_CACHE(
		.clk, .rst_n,

		.mem_read_address(mem_read_address[0]),
		.mem_read_data   (mem_read_data[0]),

		.i_pc_current (if_pc_current),
		.i_pc_next    (if_pc_next),

		.out          (if_i_cache_output)
	);

	stream_buffer STREAM_BUFFER (
		.clk, .rst_n,

		.i_pc_current (if_pc_current),
		.i_cache_hit  (if_i_cache_output.valid),

		.out (if_sb_output),

		.mem_read_address (mem_read_address[2]),
		.mem_read_data    (mem_read_data[2])
	);

	always_comb
	begin
		fe_inst_valid = if_i_cache_output.valid | if_sb_output.valid;
		for (int j = 0; j < FETCH_WIDTH; j++)
		begin
			fe_word_valid[j] = if_i_cache_output.valid
				? if_i_cache_output.word_valid[j]
				: if_sb_output.word_valid[j];
			fe_inst_data[j] = if_i_cache_output.valid
				? if_i_cache_output.data[j]
				: if_sb_output.data[j];
		end
	end

	tournament_predictor PREDICTOR (
		.clk, .rst_n,

		.i_req_valid      (bp_req_valid),
		.i_req_pc         (bp_req_pc),
		.i_req_target     (bp_req_target),
		.o_req_prediction (bp_prediction),
		.o_req_index      (bp_index),
		.o_req_seq        (bp_seq),
		.o_req_weak       (bp_weak),
		.o_req_perc       (bp_perc),
		.o_req_gshare     (bp_gshare),

		.i_fb_valid   (fb_valid),
		.i_fb_pc      (fb_pc),
		.i_fb_index   (fb_index),
		.i_fb_seq     (fb_seq),
		.i_fb_weak    (fb_weak),
		.i_fb_perc    (fb_perc),
		.i_fb_gshare  (fb_gshare),
		.i_fb_outcome (fb_outcome),

		.i_rec_valid   (rec_valid),
		.i_rec_seq     (rec_seq),
		.i_rec_pc      (rec_pc),
		.i_rec_target  (rec_target),
		.i_rec_shift   (rec_shift),
		.i_rec_outcome (rec_outcome)
	);

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Out of order back end
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	ooo_backend BACKEND (
		.clk, .rst_n,

		.fe_uop, .fe_stall,
		.ex_redirect_valid, .ex_redirect_pc,

		.fb_valid, .fb_pc, .fb_index, .fb_seq, .fb_weak,
		.fb_perc, .fb_gshare, .fb_outcome,
		.rec_valid, .rec_seq, .rec_pc, .rec_target, .rec_shift, .rec_outcome,

		.dc_in  (mem_d_cache_input),
		.dc_out (mem_d_cache_output),
		.dc_miss_pending (mem_d_cache_miss_pending),
		.dc_mshr_id      (mem_d_cache_mshr_id),
		.dc_fill_valid   (mem_d_cache_fill_valid),
		.dc_fill_id      (mem_d_cache_fill_id),

		.done
	);

	d_cache D_CACHE (
		.clk, .rst_n,

		.in(mem_d_cache_input),
		.out(mem_d_cache_output),

		.o_miss_pending(mem_d_cache_miss_pending),
		.o_mshr_id     (mem_d_cache_mshr_id),
		.o_fill_valid  (mem_d_cache_fill_valid),
		.o_fill_id     (mem_d_cache_fill_id),

		.mem_read_address(mem_read_address[1]),
		.mem_read_data   (mem_read_data[1]),

		.mem_write_address(mem_write_address[0]),
		.mem_write_data(mem_write_data[0]),
		.mem_write_response(mem_write_response[0])
	);

	// xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
	// xxxx Memory Arbiter
	// xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
	memory_arbiter #(.WRITE_MASTERS(1), .READ_MASTERS(3)) MEMORY_ARBITER (
		.clk, .rst_n,
		.axi_write_address,
		.axi_write_data,
		.axi_write_response,
		.axi_read_address,
		.axi_read_data,

		.mem_write_address,
		.mem_write_data,
		.mem_write_response,
		.mem_read_address,
		.mem_read_data
	);

	assign axi_write_address.AWREADY = AWREADY;
	assign AWVALID = axi_write_address.AWVALID;
	assign AWID = axi_write_address.AWID;
	assign AWLEN = axi_write_address.AWLEN;
	assign AWADDR = axi_write_address.AWADDR;

	assign axi_write_data.WREADY = WREADY;
	assign WVALID = axi_write_data.WVALID;
	assign WLAST = axi_write_data.WLAST;
	assign WID = axi_write_data.WID;
	assign WDATA = axi_write_data.WDATA;

	assign axi_write_response.BVALID = BVALID;
	assign axi_write_response.BID = BID;
	assign BREADY = axi_write_response.BREADY;

	assign axi_read_address.ARREADY = ARREADY;
	assign ARVALID = axi_read_address.ARVALID;
	assign ARID = axi_read_address.ARID;
	assign ARLEN = axi_read_address.ARLEN;
	assign ARADDR = axi_read_address.ARADDR;

	assign RREADY = axi_read_data.RREADY;
	assign axi_read_data.RVALID = RVALID;
	assign axi_read_data.RLAST = RLAST;
	assign axi_read_data.RID = RID;
	assign axi_read_data.RDATA = RDATA;

	// The pc / write back / load store event stream that the C++ harness diffs
	// against the golden trace is raised from commit inside rename_rob, since
	// that is the only place instructions are known to be in program order and
	// on the correct path.

endmodule
