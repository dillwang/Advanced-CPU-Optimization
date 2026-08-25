/*
 * stream_buffer.sv
 *
 * A next-line hardware prefetcher with a Jouppi-style stream buffer sitting
 * beside the instruction cache, on its own memory read port (read master id 2).
 *
 * Instruction fetch is overwhelmingly sequential, and a miss here costs about a
 * hundred cycles of memory latency, so the lines after the one being fetched
 * are almost always worth having on the way. The buffer keeps a small window of
 * consecutive lines running ahead of the program counter:
 *
 *   - when fetch misses in the instruction cache and misses here too, the
 *     stream is (re)started just past the line that missed,
 *   - while there is room, the buffer keeps requesting further lines,
 *   - when fetch lands on a line the buffer already holds, the words are handed
 *     straight to the front end and the lines behind it are dropped.
 *
 * The requests are pipelined. A single outstanding request would only ever put
 * the buffer one line ahead, and one line is four instructions -- perhaps four
 * cycles of cover against a hundred cycle miss, which is worthless. The memory
 * model accepts several reads per master id and answers them in order, so up to
 * MAX_OUTSTANDING lines are kept in flight and their latencies overlap.
 *
 * A restart abandons the lines already in flight. Rather than trying to cancel
 * them, each request carries the stream generation it was issued under, and a
 * reply whose generation no longer matches is dropped on arrival.
 *
 * The instruction cache is left to refill normally in the background, so lines
 * still become resident there and a loop that fits will hit in the cache on its
 * next pass. The buffer only covers the streaming case that the cache is bad
 * at, which is exactly the compulsory miss on each newly touched line.
 */
`include "mips_core.svh"

module stream_buffer #(
	parameter int BLOCK_OFFSET_WIDTH = 2,
	parameter int DEPTH = 8,
	parameter int MAX_OUTSTANDING = 4
	)(
	// General signals
	input clk,    // Clock
	input rst_n,  // Synchronous reset active low

	// Fetch request being made to the instruction cache this cycle
	pc_ifc.in i_pc_current,
	input logic i_cache_hit,

	// Response, merged with the instruction cache's by the core
	fetch_output_ifc.out out,

	// Memory interface
	axi_read_address.master mem_read_address,
	axi_read_data.master mem_read_data
);

`ifdef SIMULATION
	import "DPI-C" function void stats_event (input string e);
`endif

	localparam int LINE_SIZE = 1 << BLOCK_OFFSET_WIDTH;
	localparam int LINE_ADDR_W = `ADDR_WIDTH - BLOCK_OFFSET_WIDTH - 2;
	localparam int PTR_W = $clog2(DEPTH);
	localparam int OUT_W = $clog2(MAX_OUTSTANDING);

	typedef logic [LINE_ADDR_W - 1 : 0] line_addr_t;

	// Slots are content addressed rather than a ring. A ring would need its
	// pointers kept in step with the content-based invalidation done when the
	// program counter walks past a line, and the two drift apart easily.
	logic slot_valid [DEPTH];	// holds a complete line
	logic slot_busy [DEPTH];	// reserved for a request still in flight
	line_addr_t line_addr [DEPTH];
	logic [`DATA_WIDTH - 1 : 0] line_data [DEPTH][LINE_SIZE];

	// The next line the stream will ask for, and the line that last caused a
	// restart. The latter keeps a long refill from restarting the stream on
	// every one of its cycles.
	line_addr_t stream_next;
	line_addr_t restart_line;
	logic restart_valid;
	logic [1:0] gen;

	// Requests in flight, in the order the memory will answer them.
	logic [PTR_W - 1 : 0] pend_slot [MAX_OUTSTANDING];
	line_addr_t pend_addr [MAX_OUTSTANDING];
	logic [1:0] pend_gen [MAX_OUTSTANDING];
	logic [OUT_W - 1 : 0] pend_head, pend_tail;
	logic [OUT_W : 0] pend_count;
	logic [BLOCK_OFFSET_WIDTH - 1 : 0] fill_word;

	enum logic {
		REQ_IDLE,
		REQ_SEND
	} req_state;

	line_addr_t req_addr;
	logic [PTR_W - 1 : 0] req_slot;
	logic [1:0] req_gen;

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Lookup
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	line_addr_t cur_line;
	logic [BLOCK_OFFSET_WIDTH - 1 : 0] cur_offset;

	assign cur_line = i_pc_current.pc[`ADDR_WIDTH - 1 : BLOCK_OFFSET_WIDTH + 2];
	assign cur_offset = i_pc_current.pc[BLOCK_OFFSET_WIDTH + 1 : 2];

	logic hit;
	logic [PTR_W - 1 : 0] hit_slot;

	always_comb
	begin
		hit = 1'b0;
		hit_slot = '0;
		for (int i = 0; i < DEPTH; i++)
		begin
			if (slot_valid[i] && (line_addr[i] == cur_line))
			begin
				hit = 1'b1;
				hit_slot = PTR_W'(i);
			end
		end
	end

	always_comb
	begin
		out.valid = hit;
		for (int j = 0; j < FETCH_WIDTH; j++)
		begin
			automatic int off = int'(cur_offset) + j;
			out.word_valid[j] = hit && (off < LINE_SIZE);
			out.data[j] = line_data[hit_slot][off % LINE_SIZE];
		end
	end

	// A restart is wanted when fetch found the line in neither structure. The
	// line is remembered so that the hundred or so cycles the instruction cache
	// spends refilling it do not each look like a fresh restart.
	logic want_restart;
	assign want_restart = ~i_cache_hit && ~hit
		&& !(restart_valid && (restart_line == cur_line));

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// |||| Prefetch engine
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// A slot can be reused when it is idle and either empty, already passed by
	// the program counter, or so far ahead that control clearly went elsewhere.
	// Without that last case a backwards jump that keeps hitting in the cache
	// would leave every slot holding an unreachable line and prefetching would
	// never restart.
	line_addr_t window_end;
	assign window_end = cur_line + LINE_ADDR_W'(DEPTH);

	logic has_free;
	logic [PTR_W - 1 : 0] free_slot;

	always_comb
	begin
		has_free = 1'b0;
		free_slot = '0;
		for (int i = DEPTH - 1; i >= 0; i--)
		begin
			if (!slot_busy[i]
				&& (!slot_valid[i] || (line_addr[i] < cur_line)
					|| (line_addr[i] > window_end)))
			begin
				has_free = 1'b1;
				free_slot = PTR_W'(i);
			end
		end
	end

	// Only chase a stream that is still just ahead of the program counter,
	// otherwise an old stream keeps fetching lines nobody wants.
	logic stream_active;
	assign stream_active = (stream_next > cur_line) && (stream_next <= window_end);

	logic can_request;
	assign can_request = !want_restart && has_free && stream_active
		&& (pend_count < MAX_OUTSTANDING[OUT_W : 0]);

	always_comb
	begin
		mem_read_address.ARADDR = {req_addr, {BLOCK_OFFSET_WIDTH + 2{1'b0}}};
		mem_read_address.ARLEN = LINE_SIZE;
		mem_read_address.ARVALID = (req_state == REQ_SEND);
		mem_read_address.ARID = 4'd2;
		mem_read_data.RREADY = 1'b1;
	end

	// A request being accepted and a line completing can land on the same edge.
	// pend_count therefore gets a single assignment computed from both events;
	// separate increment and decrement statements would lose one of them and
	// the queue of outstanding requests would slide out of step with the
	// replies, filling slots with the wrong lines.
	logic pend_push, pend_pop;
	assign pend_push = (req_state == REQ_SEND) && mem_read_address.ARREADY;
	assign pend_pop = mem_read_data.RVALID && (pend_count != 0) && mem_read_data.RLAST;

	always_ff @(posedge clk)
	begin
		if (~rst_n)
		begin
			for (int i = 0; i < DEPTH; i++)
			begin
				slot_valid[i] <= 1'b0;
				slot_busy[i] <= 1'b0;
			end
			req_state <= REQ_IDLE;
			pend_head <= '0;
			pend_tail <= '0;
			pend_count <= '0;
			fill_word <= '0;
			restart_valid <= 1'b0;
			stream_next <= '0;
			gen <= '0;
		end
		else
		begin
			// ---- retire lines the program counter has walked past ----
			for (int i = 0; i < DEPTH; i++)
			begin
				if (slot_valid[i]
					&& ((line_addr[i] < cur_line) || (line_addr[i] > window_end)))
					slot_valid[i] <= 1'b0;
			end

			// ---- restart ----
			// Lines already in flight belonged to the abandoned stream. They
			// are not cancelled, just tagged stale by bumping the generation.
			if (want_restart)
			begin
				for (int i = 0; i < DEPTH; i++)
					slot_valid[i] <= 1'b0;
				stream_next <= cur_line + 1'b1;
				restart_line <= cur_line;
				restart_valid <= 1'b1;
				gen <= gen + 1'b1;
			`ifdef SIMULATION
				stats_event("SB_restart");
			`endif
			end

			// ---- request side ----
			case (req_state)
				REQ_IDLE:
				begin
					if (can_request)
					begin
						req_addr <= stream_next;
						req_slot <= free_slot;
						req_gen <= gen;
						slot_busy[free_slot] <= 1'b1;
						// The slot may still be holding a line the program
						// counter has walked past. Its data is about to be
						// overwritten a word at a time, so it has to stop
						// answering lookups now, not when the fill completes --
						// a loop branching back onto that address would
						// otherwise be handed a half rewritten line.
						slot_valid[free_slot] <= 1'b0;
						stream_next <= stream_next + 1'b1;
						req_state <= REQ_SEND;
					end
				end

				REQ_SEND:
				begin
					if (mem_read_address.ARREADY)
					begin
						pend_slot[pend_tail] <= req_slot;
						pend_addr[pend_tail] <= req_addr;
						pend_gen[pend_tail] <= req_gen;
						pend_tail <= OUT_W'(pend_tail + 1'b1);
						req_state <= REQ_IDLE;
					end
				end
			endcase

			// ---- reply side ----
			// Replies for one master id come back in order, so they belong to
			// the oldest outstanding request.
			if (mem_read_data.RVALID && (pend_count != 0))
			begin
				line_data[pend_slot[pend_head]][fill_word] <= mem_read_data.RDATA;
				fill_word <= fill_word + 1'b1;

				if (mem_read_data.RLAST)
				begin
					fill_word <= '0;
					slot_busy[pend_slot[pend_head]] <= 1'b0;
					// Only keep it if the stream it belonged to is still live.
					if ((pend_gen[pend_head] == gen) && !want_restart)
					begin
						slot_valid[pend_slot[pend_head]] <= 1'b1;
						line_addr[pend_slot[pend_head]] <= pend_addr[pend_head];
					end
					pend_head <= OUT_W'(pend_head + 1'b1);
				end
			end

			pend_count <= pend_count + {2'b0, pend_push} - {2'b0, pend_pop};
		end
	end

`ifdef SIMULATION
	always_ff @(posedge clk)
	begin
		if (rst_n)
		begin
			if (hit && !i_cache_hit) stats_event("SB_hit");
			if (!hit && !i_cache_hit) stats_event("SB_miss");
		end
	end
`endif

endmodule
