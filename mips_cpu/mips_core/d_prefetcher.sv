/*
 * d_prefetcher.sv
 *
 * A data-side prefetcher with both a spatial and a temporal engine, sitting
 * beside the data cache on its own memory read port (read master id 4).
 *
 * This is the second attempt. The first was a stride predictor built into the
 * cache itself, and it was deleted, because it was worth 0.002% on esift2 and
 * was NEGATIVE on nqueens. The measurement that explains why is worth keeping:
 * the miss addresses were highly predictable all along -- 51.3% same-delta on
 * quickSort, 99.5% on esift2 -- so prediction was never what failed. What
 * failed was absorption. The cache was blocking, with four miss status
 * registers on a single AXI id, so a prefetch could only ever occupy a resource
 * that a demand miss was about to need. It stole from the thing it was meant
 * to help.
 *
 * What changed: the cache is non-blocking with eight registers across two AXI
 * ids, and lines are eight words instead of four. So this version is built the
 * other way round -- as a structure OFF to the side that never competes for a
 * miss register, with its own port, its own storage and its own id.
 *
 *   - It is asked about a line only at the moment the cache takes a demand
 *     miss. On a hit the whole line is handed over in one cycle and latched
 *     into the miss register, so a hit here turns a hundred cycle miss into a
 *     fill that starts immediately.
 *   - It never installs into the cache and never probes the cache's tags, so
 *     it cannot put two ways of a set under the same tag, and it does not need
 *     the bank read port that the demand path owns.
 *   - Prefetch traffic on its own AXI id cannot fill the queue the demand
 *     misses use, which is the specific failure of the first attempt.
 *
 * Two engines feed one queue of candidate lines:
 *
 *   SPATIAL. A small table of streams, each remembering the last line it saw
 *   and the delta between the two before that. A repeated delta promotes the
 *   stream to confident and it then runs DEGREE lines ahead. A new stream
 *   starts at next-line, which costs nothing to guess and is right often
 *   enough on a scan. Streams are matched by nearness rather than by pc,
 *   because the cache is never told which instruction missed.
 *
 *   TEMPORAL. A table remembering, for each line that missed, which line
 *   missed after it. That catches the repeats a stride cannot -- a pointer
 *   chase, or a recursion revisiting the same sequence of blocks -- and it is
 *   the engine that has any chance on quickSort's partition/recurse pattern
 *   once the scan itself is covered by the spatial engine.
 *
 * Requests are pipelined, up to MAX_OUTSTANDING, for the reason the
 * instruction-side buffer is: one outstanding line is a few cycles of cover
 * against a hundred cycle latency and is worthless.
 */
`include "mips_core.svh"

module d_prefetcher #(
	parameter int BLOCK_OFFSET_WIDTH = 3,
	parameter int DEPTH = 16,			// lines held
	parameter int STREAMS = 8,			// spatial detectors
	parameter int MARKOV_IDX_W = 10,	// temporal table entries
	parameter int MAX_OUTSTANDING = 4,
	parameter int DEGREE = 4,			// lines run ahead of a confident stream
	parameter int NEAR = 16				// lines apart still counted one stream
	)(
	// General signals
	input clk,    // Clock
	input rst_n,  // Synchronous reset active low

	// Every demand miss the cache takes, for training and for triggering.
	input logic i_miss_valid,
	input logic [`ADDR_WIDTH - 1 : 0] i_miss_addr,

	// Asked in that same cycle: is this line already here? On a hit the line
	// leaves in one go and the slot is freed, so nothing has to be locked
	// against reuse while a fill drains.
	output logic o_hit,
	output logic [`DATA_WIDTH - 1 : 0] o_line [1 << BLOCK_OFFSET_WIDTH],

	// A line leaving the cache dirty. Whatever is held here for that address
	// came from memory and is now stale, so it has to go -- including when the
	// request for it is still in flight, which is what the kill flag is for.
	input logic i_inv_valid,
	input logic [`ADDR_WIDTH - 1 : 0] i_inv_addr,

	// Memory interface
	axi_read_address.master mem_read_address,
	axi_read_data.master mem_read_data
);

`ifdef SIMULATION
	import "DPI-C" function void stats_event (input string e);
`endif

	localparam int LINE_SIZE   = 1 << BLOCK_OFFSET_WIDTH;
	localparam int LINE_ADDR_W = `ADDR_WIDTH - BLOCK_OFFSET_WIDTH - 2;
	localparam int PTR_W       = $clog2(DEPTH);
	localparam int SPTR_W      = $clog2(STREAMS);
	localparam int QDEPTH      = 8;
	localparam int QPTR_W      = $clog2(QDEPTH);
	localparam int MK_ENT      = 1 << MARKOV_IDX_W;

	typedef logic [LINE_ADDR_W - 1 : 0] line_addr_t;

	line_addr_t miss_line, inv_line;
	assign miss_line = i_miss_addr[`ADDR_WIDTH - 1 : BLOCK_OFFSET_WIDTH + 2];
	assign inv_line  = i_inv_addr[`ADDR_WIDTH - 1 : BLOCK_OFFSET_WIDTH + 2];

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Line storage
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// Content addressed rather than a ring, for the reason the instruction
	// side buffer is: a ring's pointers and its content-based invalidation
	// drift apart.
	logic slot_valid [DEPTH];		// holds a complete line
	logic slot_busy  [DEPTH];		// reserved for a request in flight
	logic slot_kill  [DEPTH];		// invalidated while still in flight
	line_addr_t slot_line [DEPTH];
	logic [`DATA_WIDTH - 1 : 0] slot_data [DEPTH][LINE_SIZE];

	// ---- lookup ----
	logic hit_any;
	logic [PTR_W - 1 : 0] hit_slot;

	always_comb
	begin
		hit_any = 1'b0;
		hit_slot = '0;
		for (int i = 0; i < DEPTH; i++)
			if (slot_valid[i] && !slot_busy[i] && (slot_line[i] == miss_line))
			begin
				hit_any = 1'b1;
				hit_slot = PTR_W'(i);
			end
	end

	assign o_hit = i_miss_valid && hit_any;
	always_comb
		for (int b = 0; b < LINE_SIZE; b++)
			o_line[b] = slot_data[hit_slot][b];

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Spatial engine
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	logic st_valid [STREAMS];
	line_addr_t st_last [STREAMS];
	logic signed [LINE_ADDR_W - 1 : 0] st_stride [STREAMS];
	logic [1:0] st_conf [STREAMS];
	logic [SPTR_W - 1 : 0] st_victim;	// round robin allocation

	logic st_match;
	logic [SPTR_W - 1 : 0] st_idx;
	logic signed [LINE_ADDR_W - 1 : 0] st_delta;

	// Declared here rather than inside the loop: an automatic with an
	// initialiser in a conditional scope leaves paths on which it is never
	// assigned, and the simulator infers a latch in what has to be pure
	// combinational logic.
	logic signed [LINE_ADDR_W - 1 : 0] st_d, st_ad;

	always_comb
	begin
		st_match = 1'b0;
		st_idx = '0;
		st_delta = '0;
		st_d = '0;
		st_ad = '0;
		for (int i = 0; i < STREAMS; i++)
			if (st_valid[i])
			begin
				st_d = $signed(miss_line) - $signed(st_last[i]);
				st_ad = (st_d < 0) ? -st_d : st_d;
				// Near, and not the same line again.
				if ((st_ad != 0) && (st_ad <= LINE_ADDR_W'(NEAR)))
				begin
					st_match = 1'b1;
					st_idx = SPTR_W'(i);
					st_delta = st_d;
				end
			end
	end

	// A stream is confident once it has seen the same delta twice running.
	logic st_confident;
	assign st_confident = st_match && (st_delta == st_stride[st_idx])
		&& (st_conf[st_idx] != 2'd0);

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Temporal engine
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// One entry per hashed line: what missed next, last time this line missed.
	logic mk_valid [MK_ENT];
	line_addr_t mk_next [MK_ENT];
	line_addr_t prev_line;
	logic prev_valid;

	function automatic logic [MARKOV_IDX_W - 1 : 0] mk_hash (input line_addr_t l);
		return MARKOV_IDX_W'(l) ^ MARKOV_IDX_W'(l >> MARKOV_IDX_W);
	endfunction

	logic [MARKOV_IDX_W - 1 : 0] mk_rd, mk_wr;
	assign mk_rd = mk_hash(miss_line);
	assign mk_wr = mk_hash(prev_line);

	logic mk_avail;
	line_addr_t mk_cand;
	assign mk_avail = mk_valid[mk_rd] && (mk_next[mk_rd] != miss_line);
	assign mk_cand = mk_next[mk_rd];

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Candidate queue
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	line_addr_t q_line [QDEPTH];
	logic [QPTR_W - 1 : 0] q_head, q_tail;
	logic [QPTR_W : 0] q_count;

	logic q_empty, q_full;
	assign q_empty = (q_count == '0);
	assign q_full  = (q_count == (QPTR_W + 1)'(QDEPTH));

	// How many candidates this miss produces. The spatial engine contributes
	// DEGREE lines when confident and one next-line guess otherwise; the
	// temporal engine contributes at most one.
	localparam int MAXPUSH = DEGREE + 1;

	line_addr_t cand [MAXPUSH];
	logic cand_valid [MAXPUSH];

	always_comb
	begin
		for (int k = 0; k < MAXPUSH; k++)
		begin
			cand[k] = '0;
			cand_valid[k] = 1'b0;
		end

		if (i_miss_valid)
		begin
			if (st_confident)
			begin
				for (int k = 0; k < DEGREE; k++)
				begin
					cand[k] = miss_line
						+ line_addr_t'(st_stride[st_idx] * LINE_ADDR_W'(k + 1));
					cand_valid[k] = 1'b1;
				end
			end
			else
			begin
				// Next line costs nothing to guess and is right often enough
				// on a scan to be worth having before the stream is trusted.
				cand[0] = miss_line + line_addr_t'(1);
				cand_valid[0] = 1'b1;
			end

			if (mk_avail)
			begin
				cand[DEGREE] = mk_cand;
				cand_valid[DEGREE] = 1'b1;
			end
		end
	end

	// Position each valid candidate would take in the queue, and how many of
	// them actually fit. A burst that does not fit is dropped rather than made
	// to wait, because a prefetch that waits is usually late anyway.
	logic [QPTR_W : 0] cand_rank [MAXPUSH];
	logic [QPTR_W : 0] n_push;
	logic [QPTR_W : 0] q_space;

	assign q_space = (QPTR_W + 1)'(QDEPTH) - q_count;

	always_comb
	begin
		automatic logic [QPTR_W : 0] r = '0;
		for (int k = 0; k < MAXPUSH; k++)
		begin
			cand_rank[k] = r;
			if (cand_valid[k])
				r = r + (QPTR_W + 1)'(1);
		end
		n_push = (r > q_space) ? q_space : r;
	end

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Issue
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	logic [$clog2(MAX_OUTSTANDING + 1) - 1 : 0] outstanding;
	logic free_any;
	logic [PTR_W - 1 : 0] free_slot;
	logic [PTR_W - 1 : 0] slot_victim;	// round robin, for when nothing is free

	// A slot is released when a demand miss takes its line, and a prefetch
	// that is never asked for would otherwise hold one forever. Without a
	// victim the buffer fills once with lines nobody wants and stops issuing
	// for the rest of the run: quickSort found a confident stream 7,806 times
	// and got 146 requests out of it, because 16 slots had silted up. esift2
	// hid the bug completely, since its stream is exactly sequential and every
	// line it fetches is demanded.
	always_comb
	begin
		free_any = 1'b0;
		free_slot = slot_victim;
		for (int i = DEPTH - 1; i >= 0; i--)
			if (!slot_valid[i] && !slot_busy[i])
			begin
				free_any = 1'b1;
				free_slot = PTR_W'(i);
			end
		// Nothing free: overwrite the round robin victim, so long as it is not
		// itself waiting on data.
		if (!free_any && !slot_busy[slot_victim])
			free_any = 1'b1;
	end

	// Is the queue head already here or on its way? Checked at issue rather
	// than at push, because it may have arrived in between.
	logic head_present;
	always_comb
	begin
		head_present = 1'b0;
		for (int i = 0; i < DEPTH; i++)
			if ((slot_valid[i] || slot_busy[i]) && (slot_line[i] == q_line[q_head]))
				head_present = 1'b1;
	end

	logic can_issue, do_issue, do_drop, pop_one;
	assign can_issue = !q_empty && free_any
		&& (outstanding != $clog2(MAX_OUTSTANDING + 1)'(MAX_OUTSTANDING));
	assign do_drop  = !q_empty && head_present;
	assign do_issue = can_issue && !head_present;
	assign pop_one = (do_issue && mem_read_address.ARREADY) || do_drop;

	always_comb
	begin
		mem_read_address.ARADDR = {q_line[q_head], {BLOCK_OFFSET_WIDTH + 2{1'b0}}};
		mem_read_address.ARLEN = 4'(LINE_SIZE);
		mem_read_address.ARVALID = do_issue;
		mem_read_address.ARID = 4'd4;
		mem_read_data.RREADY = 1'b1;
	end

	logic ar_sent;
	assign ar_sent = mem_read_address.ARVALID && mem_read_address.ARREADY;

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Returning data
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// Replies on one id come back in order, so a queue of the slots that were
	// reserved is enough to know where each line belongs.
	logic [PTR_W - 1 : 0] fill_q [MAX_OUTSTANDING];
	logic [$clog2(MAX_OUTSTANDING) - 1 : 0] fill_head, fill_tail;
	logic [BLOCK_OFFSET_WIDTH - 1 : 0] fill_beat;

	logic [PTR_W - 1 : 0] fill_slot;
	assign fill_slot = fill_q[fill_head];

	logic fill_last;
	assign fill_last = mem_read_data.RVALID
		&& (fill_beat == BLOCK_OFFSET_WIDTH'(LINE_SIZE - 1));

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Sequential state
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	always_ff @(posedge clk)
	begin
		if (~rst_n)
		begin
			for (int i = 0; i < DEPTH; i++)
			begin
				slot_valid[i] = 1'b0;
				slot_busy[i] = 1'b0;
				slot_kill[i] = 1'b0;
				slot_line[i] = '0;
			end
			for (int i = 0; i < STREAMS; i++)
			begin
				st_valid[i] = 1'b0;
				st_last[i] = '0;
				st_stride[i] = '0;
				st_conf[i] = '0;
			end
			for (int i = 0; i < MK_ENT; i++)
				mk_valid[i] = 1'b0;
			st_victim <= '0;
			slot_victim <= '0;
			q_head <= '0;
			q_tail <= '0;
			q_count <= '0;
			outstanding <= '0;
			fill_head <= '0;
			fill_tail <= '0;
			fill_beat <= '0;
			prev_line <= '0;
			prev_valid <= 1'b0;
		end
		else
		begin
			// ---- a demand miss trains both engines ----
			if (i_miss_valid)
			begin
				if (st_match)
				begin
					st_last[st_idx] <= miss_line;
					if (st_delta == st_stride[st_idx])
					begin
						if (st_conf[st_idx] != 2'd3)
							st_conf[st_idx] <= st_conf[st_idx] + 2'd1;
					end
					else
					begin
						st_stride[st_idx] <= st_delta;
						st_conf[st_idx] <= '0;
					end
				end
				else
				begin
					// A new stream. Round robin rather than LRU: the table is
					// small and every entry is equally speculative.
					st_valid[st_victim] <= 1'b1;
					st_last[st_victim] <= miss_line;
					st_stride[st_victim] <= LINE_ADDR_W'(1);
					st_conf[st_victim] <= '0;
					st_victim <= SPTR_W'(st_victim + 1'b1);
				end

				if (prev_valid && (prev_line != miss_line))
				begin
					mk_valid[mk_wr] <= 1'b1;
					mk_next[mk_wr] <= miss_line;
				end
				prev_line <= miss_line;
				prev_valid <= 1'b1;
			end

			// ---- a dirty line leaving the cache makes our copy stale ----
			if (i_inv_valid)
				for (int i = 0; i < DEPTH; i++)
					if (slot_line[i] == inv_line)
					begin
						if (slot_valid[i])
							slot_valid[i] <= 1'b0;
						if (slot_busy[i])
							slot_kill[i] <= 1'b1;
					end

			// ---- a hit hands the line over and frees the slot ----
			if (o_hit)
			begin
				slot_valid[hit_slot] <= 1'b0;
				slot_busy[hit_slot] <= 1'b0;
			end

			// ---- candidates in ----
			// A confident stream must enqueue the WHOLE run of DEGREE lines,
			// not just the furthest. Queueing only line + DEGREE * stride
			// leaves every line between here and there to miss on demand, and
			// the prefetcher then never gets ahead of anything.
			for (int k = 0; k < MAXPUSH; k++)
				if (cand_valid[k] && (int'(cand_rank[k]) < int'(n_push)))
					q_line[QPTR_W'(q_tail + QPTR_W'(cand_rank[k]))] <= cand[k];

			// ---- issue, and dropping candidates that arrived meanwhile ----
			if (do_issue && ar_sent)
			begin
				slot_busy[free_slot] <= 1'b1;
				slot_valid[free_slot] <= 1'b0;
				slot_kill[free_slot] <= 1'b0;
				slot_line[free_slot] <= q_line[q_head];
				slot_victim <= PTR_W'(slot_victim + 1'b1);
				fill_q[fill_tail] <= free_slot;
				fill_tail <= $clog2(MAX_OUTSTANDING)'(fill_tail + 1'b1);
			end

			// ---- returning beats ----
			if (mem_read_data.RVALID)
			begin
				slot_data[fill_slot][fill_beat] <= mem_read_data.RDATA;
				if (fill_last)
				begin
					fill_beat <= '0;
					slot_busy[fill_slot] <= 1'b0;
					slot_kill[fill_slot] <= 1'b0;
					// A line invalidated while it was in flight is dropped on
					// arrival rather than installed stale.
					slot_valid[fill_slot] <= !slot_kill[fill_slot];
					fill_head <= $clog2(MAX_OUTSTANDING)'(fill_head + 1'b1);
				end
				else
					fill_beat <= BLOCK_OFFSET_WIDTH'(fill_beat + 1'b1);
			end

			// ---- queue and outstanding accounting ----
			// Written once each so a push and a pop on the same edge cannot
			// lose one another.
			if (n_push != '0)
				q_tail <= QPTR_W'(q_tail + QPTR_W'(n_push));
			if (pop_one)
				q_head <= QPTR_W'(q_head + 1'b1);
			q_count <= q_count + (QPTR_W + 1)'(n_push)
							   - {{QPTR_W{1'b0}}, pop_one};

			outstanding <= outstanding
				+ {{($clog2(MAX_OUTSTANDING + 1) - 1){1'b0}}, (do_issue && ar_sent)}
				- {{($clog2(MAX_OUTSTANDING + 1) - 1){1'b0}}, fill_last};

		`ifdef SIMULATION
			if (do_issue && ar_sent) stats_event("pf_issued");
			if (o_hit) stats_event("pf_hit");
			if (i_miss_valid && !hit_any) stats_event("pf_miss");
			if (do_drop) stats_event("pf_dropped");
			if (fill_last && slot_kill[fill_slot]) stats_event("pf_killed");
			if (do_issue && ar_sent && slot_valid[free_slot]) stats_event("pf_evicted");
			if (!q_empty && !free_any) stats_event("pf_no_slot");
			if (i_miss_valid && st_confident) stats_event("pf_spatial");
			if (i_miss_valid && mk_avail) stats_event("pf_temporal");
		`endif
		end
	end

endmodule
