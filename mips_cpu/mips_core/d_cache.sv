/*
 * d_cache.sv
 * Author: Zinsser Zhang
 * Revision : Sankara
 * Revision : non-blocking rewrite with miss status holding registers
 *
 * A set associative, write-back, write-allocate data cache that does not block
 * on a miss.
 *
 * The original cache ran one miss at a time: an access that missed took the
 * whole cache into a refill state machine, and every later access -- including
 * ones that would have hit -- waited out the full memory latency behind it.
 * Measured on quickSort that was 22,179 misses at 112 cycles each, 47% of the
 * entire run, with none of them overlapping.
 *
 * Miss status holding registers (Kroft, 1981) remove that. Each entry records
 * one line fill that is in flight: its address, the way it will land in, and
 * nothing else -- the requests waiting on it are tracked by the load/store
 * queue, which replays them once the line arrives. On a miss the cache
 * allocates an entry and answers "pending" rather than stalling, so the very
 * next cycle it can serve a hit or take another miss. Up to NUM_MSHR fills are
 * outstanding, and their latencies overlap.
 *
 * Three things make this tractable here:
 *
 *   - Reads on one AXI id are returned in order, so the register file is a FIFO
 *     and returning data always belongs to the entry at its head. No matching
 *     of replies to entries is needed.
 *   - A second access to a line already in flight merges into the existing
 *     entry instead of allocating a new one, and shares its memory request.
 *   - Dirty evictions are decoupled. The victim line is copied out of the data
 *     banks into a writeback queue in the cycle the miss is taken, and the way
 *     is invalidated immediately, so the refill can land whenever it likes. The
 *     queue drains to memory on its own.
 *
 * The one ordering rule that has to be enforced by hand: the memory model
 * delays writes by 120 cycles and reads by 100, so a read issued after a write
 * to the same address can still overtake it. An access whose line is sitting in
 * the writeback queue is therefore refused until that writeback has been
 * acknowledged, and the load/store queue retries it.
 *
 * An access gets exactly one of three answers in the cycle it is presented:
 *   out.valid       -- it hit, data is on out.data
 *   o_miss_pending  -- it missed and is now covered by MSHR o_mshr_id
 *   neither         -- refused; present it again
 *
 * Because we need a hit latency of 1 cycle we need an asynchronous read port,
 * but SRAMs only support synchronous read. Hence both a registered address
 * (addr) and a non-registered one (addr_next) -- the banks are addressed from
 * addr_next in the cycle before the tags are compared against addr.
 */
`include "mips_core.svh"

interface d_cache_input_ifc ();
    logic valid;
    mips_core_pkg::MemAccessType mem_action;
    logic [`ADDR_WIDTH - 1 : 0] addr;
    logic [`ADDR_WIDTH - 1 : 0] addr_next;
    logic [`DATA_WIDTH - 1 : 0] data;

    modport in  (input valid, mem_action, addr, addr_next, data);
    modport out (output valid, mem_action, addr, addr_next, data);
endinterface

module d_cache #(
    parameter INDEX_WIDTH = 8,  // 4 ways x 256 sets x 4 words = 16 KB
    parameter BLOCK_OFFSET_WIDTH = 2,
    parameter ASSOCIATIVITY = 4
    )(
    // General signals
    input clk,    // Clock
    input rst_n,  // Synchronous reset active low

    // Request
    d_cache_input_ifc.in in,

    // Response
    cache_output_ifc.out out,

    // Miss response. o_miss_pending means the access did not hit but has been
    // taken on by MSHR o_mshr_id, so the requester should stop presenting it
    // and wait. If neither out.valid nor o_miss_pending is asserted for a valid
    // access, the cache could not take it and it must be presented again.
    output logic o_miss_pending,
    output mips_core_pkg::mshr_id_t o_mshr_id,

    // A line has landed and the MSHR covering it has retired. Everything
    // waiting on this id may now be replayed, and will hit.
    output logic o_fill_valid,
    output mips_core_pkg::mshr_id_t o_fill_id,

    // AXI interfaces
    axi_write_address.master mem_write_address,
    axi_write_data.master mem_write_data,
    axi_write_response.master mem_write_response,
    axi_read_address.master mem_read_address,
    axi_read_data.master mem_read_data
);
    localparam TAG_WIDTH = `ADDR_WIDTH - INDEX_WIDTH - BLOCK_OFFSET_WIDTH - 2;
    localparam LINE_SIZE = 1 << BLOCK_OFFSET_WIDTH;
    localparam DEPTH = 1 << INDEX_WIDTH;
    localparam WAY_W = $clog2(ASSOCIATIVITY);

    `ifdef SIMULATION
        import "DPI-C" function void stats_event(input string e);
    `endif

    // Check if the parameters are set correctly
    generate
        if(TAG_WIDTH <= 0 || LINE_SIZE > 16)
        begin
            INVALID_D_CACHE_PARAM invalid_d_cache_param ();
        end
    endgenerate

    // Parsing
    logic [TAG_WIDTH - 1 : 0] i_tag;
    logic [INDEX_WIDTH - 1 : 0] i_index;
    logic [BLOCK_OFFSET_WIDTH - 1 : 0] i_block_offset;
    logic [INDEX_WIDTH - 1 : 0] i_index_next;

    assign {i_tag, i_index, i_block_offset} = in.addr[`ADDR_WIDTH - 1 : 2];
    assign i_index_next = in.addr_next[BLOCK_OFFSET_WIDTH + 2 +: INDEX_WIDTH];

    // ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
    // |||| Storage
    // ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
    logic [LINE_SIZE - 1 : 0] databank_we[ASSOCIATIVITY];
    logic [`DATA_WIDTH - 1 : 0] databank_wdata;
    logic [INDEX_WIDTH - 1 : 0] databank_waddr;
    logic [INDEX_WIDTH - 1 : 0] databank_raddr;
    logic [`DATA_WIDTH - 1 : 0] databank_rdata [ASSOCIATIVITY][LINE_SIZE];

    genvar g, w;
    generate
        for (g = 0; g < LINE_SIZE; g++)
        begin : datasets
            for (w = 0; w < ASSOCIATIVITY; w++)
            begin : databanks
                cache_bank #(
                    .DATA_WIDTH (`DATA_WIDTH),
                    .ADDR_WIDTH (INDEX_WIDTH)
                ) databank (
                    .clk,
                    .i_we (databank_we[w][g]),
                    .i_wdata(databank_wdata),
                    .i_waddr(databank_waddr),
                    .i_raddr(databank_raddr),
                    .o_rdata(databank_rdata[w][g])
                );
            end
        end
    endgenerate

    logic tagbank_we[ASSOCIATIVITY];
    logic [TAG_WIDTH - 1 : 0] tagbank_wdata;
    logic [INDEX_WIDTH - 1 : 0] tagbank_waddr;
    logic [INDEX_WIDTH - 1 : 0] tagbank_raddr;
    logic [TAG_WIDTH - 1 : 0] tagbank_rdata[ASSOCIATIVITY];

    generate
        for (w = 0; w < ASSOCIATIVITY; w++)
        begin: tagbanks
            cache_bank #(
                .DATA_WIDTH (TAG_WIDTH),
                .ADDR_WIDTH (INDEX_WIDTH)
            ) tagbank (
                .clk,
                .i_we    (tagbank_we[w]),
                .i_wdata (tagbank_wdata),
                .i_waddr (tagbank_waddr),
                .i_raddr (tagbank_raddr),
                .o_rdata (tagbank_rdata[w])
            );
        end
    endgenerate

    logic [DEPTH - 1 : 0] valid_bits[ASSOCIATIVITY];
    logic [DEPTH - 1 : 0] dirty_bits[ASSOCIATIVITY];

    // True LRU. lru_age holds a permutation of 0..ASSOCIATIVITY-1 per set: 0 is
    // most recently used and ASSOCIATIVITY-1 is the victim.
    logic [WAY_W - 1 : 0] lru_age [ASSOCIATIVITY][DEPTH];

    // The banks are addressed a cycle ahead of the tag compare, always from the
    // requester's next address. Nothing else competes for the read ports: line
    // fills use the write port, and a dirty victim is copied out of the read
    // port in the same cycle its miss is taken.
    assign databank_raddr = i_index_next;
    assign tagbank_raddr = i_index_next;

    // ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
    // |||| Miss status holding registers
    // ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
    // A FIFO, because reads on one AXI id come back in order.
    logic [NUM_MSHR - 1 : 0] m_valid;
    logic [TAG_WIDTH - 1 : 0] m_tag [NUM_MSHR];
    logic [INDEX_WIDTH - 1 : 0] m_index [NUM_MSHR];
    logic [WAY_W - 1 : 0] m_way [NUM_MSHR];

    mshr_id_t m_head;       // the fill that returning data belongs to
    mshr_id_t m_send;       // the next fill whose read request must go out
    mshr_id_t m_tail;       // the next free entry
    logic [MSHR_IDX_W : 0] m_count;

    // ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
    // |||| Writeback queue
    // ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
    // Dirty victims are lifted out of the data banks whole and drain from here,
    // so that evicting a dirty line never delays the fill that replaced it.
    logic [TAG_WIDTH - 1 : 0] f_tag [NUM_MSHR];
    logic [INDEX_WIDTH - 1 : 0] f_index [NUM_MSHR];
    logic [`DATA_WIDTH - 1 : 0] f_data [NUM_MSHR][LINE_SIZE];

    mshr_id_t f_head;       // oldest writeback still unacknowledged
    mshr_id_t f_send;       // next writeback to put on the bus
    mshr_id_t f_tail;       // next free slot
    logic [MSHR_IDX_W : 0] f_count;

    // ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
    // |||| Lookup
    // ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
    logic tag_hit;
    logic [WAY_W - 1 : 0] hit_way;
    logic hit, miss;

    // A refill beat owns the data banks' single write port for that cycle, so a
    // store cannot commit its word at the same time. Loads are unaffected; they
    // use the read port.
    logic bank_write_busy;
    assign bank_write_busy = mem_read_data.RVALID;

    logic store_defer;

    always_comb
    begin
        tag_hit = 1'b0;
        hit_way = '0;
        for (int i = 0; i < ASSOCIATIVITY; i++)
        begin
            if ((i_tag == tagbank_rdata[i]) && valid_bits[i][i_index])
            begin
                tag_hit = 1'b1;
                hit_way = WAY_W'(i);
            end
        end

        // A store whose line is present but whose word cannot be written this
        // cycle is neither a hit nor a miss -- it is simply refused, and comes
        // back. Calling it a miss would fetch a line the cache already holds.
        store_defer = in.valid & tag_hit
            & (in.mem_action == WRITE) & bank_write_busy;
        hit = in.valid & tag_hit & ~store_defer;
        miss = in.valid & ~tag_hit;
    end

    assign out.valid = hit;
    assign out.data = databank_rdata[hit_way][i_block_offset];

    // ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
    // |||| Miss classification
    // ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
    logic mshr_match;               // the line is already being fetched
    mshr_id_t mshr_match_id;
    logic wb_conflict;              // the line is waiting to be written back
    logic [ASSOCIATIVITY - 1 : 0] way_reserved;
    logic have_victim;
    logic [WAY_W - 1 : 0] victim_way;
    logic victim_dirty;

    always_comb
    begin
        mshr_match = 1'b0;
        mshr_match_id = '0;
        way_reserved = '0;

        for (int i = 0; i < NUM_MSHR; i++)
        begin
            if (m_valid[i] && (m_index[i] == i_index))
            begin
                // A way that a fill is already aimed at cannot be picked again.
                way_reserved[m_way[i]] = 1'b1;
                if (m_tag[i] == i_tag)
                begin
                    mshr_match = 1'b1;
                    mshr_match_id = mshr_id_t'(i);
                end
            end
        end

        // Everything between f_head and f_tail is a line whose current contents
        // exist only in the writeback queue, so it may not be read from memory
        // until the write has been acknowledged.
        wb_conflict = 1'b0;
        for (int i = 0; i < NUM_MSHR; i++)
        begin
            automatic logic [MSHR_IDX_W : 0] pos =
                {1'b0, mshr_id_t'(mshr_id_t'(i) - f_head)};
            if ((pos < f_count) && (f_index[i] == i_index) && (f_tag[i] == i_tag))
                wb_conflict = 1'b1;
        end
    end

    // Pick a victim among the ways no fill has claimed: an invalid way first,
    // otherwise the one the recency permutation says is oldest. Taking the
    // maximum rather than testing for ASSOCIATIVITY-1 keeps this well defined
    // even if two updates in one cycle disturb the permutation.
    always_comb
    begin
        automatic logic found = 1'b0;
        automatic logic found_invalid = 1'b0;
        victim_way = '0;

        for (int i = 0; i < ASSOCIATIVITY; i++)
        begin
            if (!way_reserved[i] && !valid_bits[i][i_index] && !found_invalid)
            begin
                found_invalid = 1'b1;
                found = 1'b1;
                victim_way = WAY_W'(i);
            end
        end

        if (!found_invalid)
        begin
            for (int i = 0; i < ASSOCIATIVITY; i++)
            begin
                if (!way_reserved[i]
                    && (!found || (lru_age[i][i_index] > lru_age[victim_way][i_index])))
                begin
                    found = 1'b1;
                    victim_way = WAY_W'(i);
                end
            end
        end

        have_victim = found;
        victim_dirty = valid_bits[victim_way][i_index] & dirty_bits[victim_way][i_index];
    end

    logic mshr_full, wbq_full;
    logic can_allocate;
    logic do_allocate;

    assign mshr_full = (m_count == (MSHR_IDX_W + 1)'(NUM_MSHR));
    assign wbq_full = (f_count == (MSHR_IDX_W + 1)'(NUM_MSHR));
    assign can_allocate = !mshr_full && have_victim && (!victim_dirty || !wbq_full);

    assign do_allocate = miss && !wb_conflict && !mshr_match && can_allocate;
    assign o_miss_pending = miss && !wb_conflict && (mshr_match || can_allocate);
    assign o_mshr_id = mshr_match ? mshr_match_id : m_tail;

    // ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
    // |||| Bank writes
    // ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
    logic [LINE_SIZE - 1 : 0] databank_select;
    logic last_refill_word;
    assign last_refill_word = databank_select[LINE_SIZE - 1] & mem_read_data.RVALID;

    always_comb
    begin
        for (int i = 0; i < ASSOCIATIVITY; i++)
            databank_we[i] = '0;

        if (mem_read_data.RVALID)
            databank_we[m_way[m_head]] = databank_select;
        else if (hit && (in.mem_action == WRITE))
            databank_we[hit_way][i_block_offset] = 1'b1;
    end

    always_comb
    begin
        if (mem_read_data.RVALID)
        begin
            databank_wdata = mem_read_data.RDATA;
            databank_waddr = m_index[m_head];
        end
        else
        begin
            databank_wdata = in.data;
            databank_waddr = i_index;
        end
    end

    always_comb
    begin
        for (int i = 0; i < ASSOCIATIVITY; i++)
            tagbank_we[i] = 1'b0;
        tagbank_we[m_way[m_head]] = last_refill_word;
        tagbank_wdata = m_tag[m_head];
        tagbank_waddr = m_index[m_head];
    end

    assign o_fill_valid = last_refill_word;
    assign o_fill_id = m_head;

    // ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
    // |||| Memory read channel
    // ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
    // Counted rather than derived from the pointers: m_send == m_tail means
    // both "nothing to send" and "everything outstanding" once they wrap.
    logic [MSHR_IDX_W : 0] m_nsend;
    logic ar_pending;
    assign ar_pending = (m_nsend != 0);

    always_comb
    begin
        mem_read_address.ARADDR = {m_tag[m_send], m_index[m_send],
            {BLOCK_OFFSET_WIDTH + 2{1'b0}}};
        mem_read_address.ARLEN = LINE_SIZE;
        mem_read_address.ARVALID = ar_pending;
        mem_read_address.ARID = 4'd1;
        mem_read_data.RREADY = 1'b1;
    end

    // ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
    // |||| Memory write channel
    // ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
    enum logic {
        W_ADDR,
        W_DATA
    } w_state;

    logic [BLOCK_OFFSET_WIDTH - 1 : 0] w_beat;
    logic [MSHR_IDX_W : 0] f_nsend;
    logic wb_pending;
    assign wb_pending = (f_nsend != 0);

    always_comb
    begin
        mem_write_address.AWVALID = wb_pending && (w_state == W_ADDR);
        mem_write_address.AWID = 0;
        mem_write_address.AWLEN = LINE_SIZE;
        mem_write_address.AWADDR = {f_tag[f_send], f_index[f_send],
            {BLOCK_OFFSET_WIDTH + 2{1'b0}}};

        mem_write_data.WVALID = wb_pending && (w_state == W_DATA);
        mem_write_data.WID = 0;
        mem_write_data.WDATA = f_data[f_send][w_beat];
        mem_write_data.WLAST = (w_beat == BLOCK_OFFSET_WIDTH'(LINE_SIZE - 1));

        mem_write_response.BREADY = 1'b1;
    end

    // ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
    // |||| Sequential state
    // ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
    logic m_push, m_pop, f_push, f_pop;

    logic ar_sent, w_sent;

    assign m_push = do_allocate;
    assign m_pop = last_refill_word;
    assign f_push = do_allocate && victim_dirty;
    assign f_pop = mem_write_response.BVALID && (f_count != 0);
    assign ar_sent = mem_read_address.ARVALID && mem_read_address.ARREADY;
    assign w_sent = mem_write_data.WVALID && mem_write_data.WREADY
        && mem_write_data.WLAST;

    always_ff @(posedge clk)
    begin
        if (~rst_n)
        begin
            databank_select <= 1;
            for (int i = 0; i < ASSOCIATIVITY; i++)
                valid_bits[i] <= '0;
            // Blocking: large arrays, and nothing else writes them on this
            // edge. Seeding with the identity gives a valid permutation.
            for (int i = 0; i < ASSOCIATIVITY; i++)
                for (int j = 0; j < DEPTH; j++)
                    lru_age[i][j] = WAY_W'(i);
            m_valid <= '0;
            m_head <= '0;
            m_send <= '0;
            m_tail <= '0;
            m_count <= '0;
            m_nsend <= '0;
            f_head <= '0;
            f_send <= '0;
            f_tail <= '0;
            f_count <= '0;
            f_nsend <= '0;
            w_state <= W_ADDR;
            w_beat <= '0;
        end
        else
        begin
            // ---- taking a miss ----
            if (do_allocate)
            begin
                m_valid[m_tail] <= 1'b1;
                m_tag[m_tail] <= i_tag;
                m_index[m_tail] <= i_index;
                m_way[m_tail] <= victim_way;
                m_tail <= mshr_id_t'(m_tail + 1'b1);

                // The way stops answering lookups now. Its data is still in the
                // banks and stays there until the fill overwrites it, which is
                // what lets the writeback copy below be taken from the read
                // port in this same cycle.
                valid_bits[victim_way][i_index] <= 1'b0;

                if (victim_dirty)
                begin
                    f_tag[f_tail] <= tagbank_rdata[victim_way];
                    f_index[f_tail] <= i_index;
                    for (int j = 0; j < LINE_SIZE; j++)
                        f_data[f_tail][j] <= databank_rdata[victim_way][j];
                    f_tail <= mshr_id_t'(f_tail + 1'b1);
                end
            end

            // ---- store hit dirties its line ----
            if (hit && (in.mem_action == WRITE))
                dirty_bits[hit_way][i_index] <= 1'b1;

            // ---- recency, on a hit ----
            if (hit)
            begin
                for (int i = 0; i < ASSOCIATIVITY; i++)
                begin
                    if (lru_age[i][i_index] < lru_age[hit_way][i_index])
                        lru_age[i][i_index] <= lru_age[i][i_index] + WAY_W'(1);
                end
                lru_age[hit_way][i_index] <= '0;
            end

            // ---- read requests go out in allocation order ----
            if (ar_sent)
                m_send <= mshr_id_t'(m_send + 1'b1);

            // ---- returning line data ----
            if (mem_read_data.RVALID)
                databank_select <= {databank_select[LINE_SIZE - 2 : 0],
                    databank_select[LINE_SIZE - 1]};

            if (last_refill_word)
            begin
                valid_bits[m_way[m_head]][m_index[m_head]] <= 1'b1;
                dirty_bits[m_way[m_head]][m_index[m_head]] <= 1'b0;
                m_valid[m_head] <= 1'b0;
                m_head <= mshr_id_t'(m_head + 1'b1);

                // The line was fetched for a real access, so it goes in as most
                // recently used.
                for (int i = 0; i < ASSOCIATIVITY; i++)
                begin
                    if (lru_age[i][m_index[m_head]] < lru_age[m_way[m_head]][m_index[m_head]])
                        lru_age[i][m_index[m_head]] <= lru_age[i][m_index[m_head]] + WAY_W'(1);
                end
                lru_age[m_way[m_head]][m_index[m_head]] <= '0;
            end

            // ---- writeback queue drain ----
            case (w_state)
                W_ADDR:
                    if (mem_write_address.AWVALID && mem_write_address.AWREADY)
                    begin
                        w_state <= W_DATA;
                        w_beat <= '0;
                    end

                W_DATA:
                    if (mem_write_data.WVALID && mem_write_data.WREADY)
                    begin
                        if (mem_write_data.WLAST)
                        begin
                            w_state <= W_ADDR;
                            f_send <= mshr_id_t'(f_send + 1'b1);
                        end
                        else
                            w_beat <= BLOCK_OFFSET_WIDTH'(w_beat + 1'b1);
                    end
            endcase

            if (f_pop)
                f_head <= mshr_id_t'(f_head + 1'b1);

            // Occupancy is written once, so that a push and a pop landing on
            // the same edge cannot lose each other.
            m_count <= m_count + {{MSHR_IDX_W{1'b0}}, m_push}
                                - {{MSHR_IDX_W{1'b0}}, m_pop};
            f_count <= f_count + {{MSHR_IDX_W{1'b0}}, f_push}
                                - {{MSHR_IDX_W{1'b0}}, f_pop};
            m_nsend <= m_nsend + {{MSHR_IDX_W{1'b0}}, m_push}
                                - {{MSHR_IDX_W{1'b0}}, ar_sent};
            f_nsend <= f_nsend + {{MSHR_IDX_W{1'b0}}, f_push}
                                - {{MSHR_IDX_W{1'b0}}, w_sent};
        end
    end

    `ifdef SIMULATION
        always_ff @(posedge clk)
        begin
            if (rst_n)
            begin
                if (hit) stats_event("D-Cache_hit");
                if (miss) stats_event("D-Cache_miss");
                if (in.valid) stats_event("D-Cache_access");
                if (do_allocate) stats_event("Dmiss_event");
                if (miss && mshr_match) stats_event("Dmiss_merged");
                if (miss && !o_miss_pending) stats_event("Dmiss_refused");
                if (f_push) stats_event("D-Cache_writeback");
                if (m_count != 0) stats_event("Dmiss_inflight");
                if (m_count > 1) stats_event("Dmiss_overlapped");
                if (mshr_full) stats_event("Dmiss_regs_full");
            end
        end
    `endif

endmodule
